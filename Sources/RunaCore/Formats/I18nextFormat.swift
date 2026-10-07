import Foundation

/// i18next JSON v4: one file per locale, plural forms as `key_one`, `key_other`, interpolation as `{{name}}`.
public enum I18nextFormat {
    static let pluralSuffixes = PluralCategory.allCases.map { "_\($0.rawValue)" }

    public static func export(_ snapshot: Snapshot, options: ExportOptions = ExportOptions()) -> ExportResult {
        let context = ExportContext(snapshot: snapshot, options: options, platform: .web)
        let pattern = options.filePattern ?? "{locale}.json"
        var files: [ExportedFile] = []
        var warnings: [String] = []
        for locale in snapshot.settings.locales {
            var flat: [(String, String)] = []
            for key in context.keys {
                guard let forms = context.forms(for: key, locale: locale) else { continue }
                let render = context.renderOptions(for: key)
                if key.isPlural {
                    for category in PluralCategory.allCases {
                        guard let text = forms[category] else { continue }
                        flat.append(("\(key.key)_\(category.rawValue)", PlaceholderConverter.render(text, flavor: .i18next, options: render)))
                    }
                } else if let text = forms[.other] {
                    flat.append((key.key, PlaceholderConverter.render(text, flavor: .i18next, options: render)))
                }
            }
            let value: JSONValue
            if options.nested {
                let (tree, treeWarnings) = nest(flat)
                value = tree
                if locale == context.source { warnings += treeWarnings }
            } else {
                value = JSONValue.sortedObject(Dictionary(flat, uniquingKeysWith: { first, _ in first }).mapValues { .string($0) })
            }
            let path = pattern.replacingOccurrences(of: "{locale}", with: locale.rawValue)
            files.append(ExportedFile(relativePath: path, contents: Data(value.serialized(style: .standard).utf8)))
        }
        return ExportResult(files: files, warnings: warnings)
    }

    /// Builds a nested object from dotted keys. A key that is both a value and a parent
    /// (`a.b` and `a.b.c`) cannot be nested and is reported.
    static func nest(_ flat: [(String, String)]) -> (JSONValue, [String]) {
        final class Node {
            var value: String?
            var children: [String: Node] = [:]
        }
        let root = Node()
        var warnings: [String] = []
        for (key, text) in flat {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            var node = root
            var blocked = false
            for (index, part) in parts.enumerated() {
                if node.value != nil, node !== root {
                    blocked = true
                    break
                }
                let child = node.children[part] ?? Node()
                node.children[part] = child
                node = child
                if index == parts.count - 1 {
                    if !node.children.isEmpty { blocked = true } else { node.value = text }
                }
            }
            if blocked { warnings.append("\"\(key)\" clashes with another key when nested and was skipped; use flat keys or rename it") }
        }
        func build(_ node: Node) -> JSONValue {
            if let value = node.value { return .string(value) }
            return JSONValue.sortedObject(node.children.mapValues(build))
        }
        return (build(root), warnings)
    }

    public static func parse(_ data: Data, locale: LocaleCode, file: String) throws -> [ImportedEntry] {
        let root = try JSONValue.parse(data)
        var flat: [(String, String)] = []
        func walk(_ value: JSONValue, prefix: String) {
            switch value {
            case .object(let members):
                for (name, child) in members { walk(child, prefix: prefix.isEmpty ? name : "\(prefix).\(name)") }
            case .string(let text):
                flat.append((prefix, text))
            default: break
            }
        }
        walk(root, prefix: "")
        var plain: [String: String] = [:]
        var plural: [String: [PluralCategory: String]] = [:]
        var order: [String] = []
        var seen = Set<String>()
        func remember(_ key: String) {
            if seen.insert(key).inserted { order.append(key) }
        }
        for (key, text) in flat {
            if let suffix = pluralSuffixes.first(where: { key.hasSuffix($0) }),
                let category = PluralCategory(rawValue: String(suffix.dropFirst()))
            {
                let base = String(key.dropLast(suffix.count))
                remember(base)
                plural[base, default: [:]][category] = text
            } else if key.hasSuffix("_plural") {
                // i18next v3: `key` is the singular and `key_plural` the plural.
                let base = String(key.dropLast("_plural".count))
                remember(base)
                plural[base, default: [:]][.other] = text
            } else {
                remember(key)
                plain[key] = text
            }
        }
        return order.compactMap { key in
            if var forms = plural[key] {
                if let singular = plain[key], forms[.one] == nil { forms[.one] = singular }
                return ImportedEntry(key: key, locale: locale, isPlural: true, forms: forms, flavor: .i18next, file: file)
            }
            guard let text = plain[key] else { return nil }
            return ImportedEntry(key: key, locale: locale, forms: [.other: text], flavor: .i18next, file: file)
        }
    }
}

/// Flat JSON of ICU MessageFormat messages, one file per locale:
/// `{"cart.items": "{count, plural, one {# item} other {# items}}"}`.
public enum ICUJSONFormat {
    public static func export(_ snapshot: Snapshot, options: ExportOptions = ExportOptions()) -> ExportResult {
        let context = ExportContext(snapshot: snapshot, options: options, platform: .web)
        let pattern = options.filePattern ?? "{locale}.json"
        var files: [ExportedFile] = []
        for locale in snapshot.settings.locales {
            var messages: [String: JSONValue] = [:]
            for key in context.keys {
                guard let forms = context.forms(for: key, locale: locale) else { continue }
                let render = context.renderOptions(for: key)
                if key.isPlural {
                    messages[key.key] = .string(pluralMessage(forms, variable: render.pluralVariable ?? "count"))
                } else if let text = forms[.other] {
                    messages[key.key] = .string(PlaceholderConverter.render(text, flavor: .icu, options: render))
                }
            }
            let path = pattern.replacingOccurrences(of: "{locale}", with: locale.rawValue)
            files.append(ExportedFile(relativePath: path, contents: Data(JSONValue.sortedObject(messages).serialized(style: .standard).utf8)))
        }
        return ExportResult(files: files, warnings: [])
    }

    static func pluralMessage(_ forms: [PluralCategory: String], variable: String) -> String {
        let branches = PluralCategory.allCases.compactMap { category -> String? in
            guard let text = forms[category] else { return nil }
            let body = CanonicalText.parse(text).map { segment -> String in
                switch segment {
                case .literal(let literal): return ICUEscaping.escape(literal, inPlural: true)
                case .placeholder(let placeholder) where placeholder.name == variable: return "#"
                case .placeholder(let placeholder):
                    switch placeholder.type {
                    case .string: return "{\(placeholder.name)}"
                    case .int: return "{\(placeholder.name), number, integer}"
                    case .double: return "{\(placeholder.name), number}"
                    }
                }
            }.joined()
            return "\(category.rawValue) {\(body)}"
        }
        return "{\(variable), plural, \(branches.joined(separator: " "))}"
    }

    public static func parse(_ data: Data, locale: LocaleCode, file: String) throws -> (entries: [ImportedEntry], warnings: [String]) {
        guard let members = try JSONValue.parse(data).objectMembers else {
            throw FormatError.invalidFile(file, reason: "Expected an object of messages")
        }
        var entries: [ImportedEntry] = []
        var warnings: [String] = []
        for (key, value) in members {
            guard let message = value.stringValue else { continue }
            if let (variable, branches) = parsePlural(message) {
                var forms: [PluralCategory: String] = [:]
                for (selector, body) in branches {
                    let category: PluralCategory? = selector == "=0" ? .zero : selector == "=1" ? .one : PluralCategory(rawValue: selector)
                    guard let category else {
                        warnings.append("\(key): plural selector \(selector) is not supported")
                        continue
                    }
                    let withCount = body.replacingOccurrences(of: "\u{2}", with: "{\(variable), number, integer}")
                    forms[category] = PlaceholderConverter.parse(withCount, flavor: .icu)
                }
                entries.append(ImportedEntry(key: key, locale: locale, isPlural: true, forms: forms, flavor: .icu, file: file))
            } else {
                entries.append(ImportedEntry(key: key, locale: locale, forms: [.other: PlaceholderConverter.parse(message, flavor: .icu)],
                                             flavor: .icu, file: file))
            }
        }
        return (entries, warnings)
    }

    /// Parses a message that is a single `{var, plural, …}` block. Quoted `'#'` stays literal.
    static func parsePlural(_ message: String) -> (String, [(String, String)])? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        let parts = inner.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[1] == "plural", CanonicalText.isIdentifier(parts[0]) else { return nil }
        let rest = Array(parts[2])
        var branches: [(String, String)] = []
        var index = 0
        while index < rest.count {
            while index < rest.count, rest[index].isWhitespace { index += 1 }
            var selector = ""
            while index < rest.count, !rest[index].isWhitespace, rest[index] != "{" { selector.append(rest[index]); index += 1 }
            if selector.hasPrefix("offset:") { continue }
            while index < rest.count, rest[index].isWhitespace { index += 1 }
            guard index < rest.count, rest[index] == "{" else { return selector.isEmpty ? (parts[0], branches) : nil }
            var depth = 0
            var body = ""
            var inQuote = false
            while index < rest.count {
                let character = rest[index]
                if character == "'" { inQuote.toggle() }
                if !inQuote {
                    if character == "{" { depth += 1; if depth == 1 { index += 1; continue } }
                    if character == "}" { depth -= 1; if depth == 0 { index += 1; break } }
                }
                // Unquoted # stands for the plural number; mark it so quoted '#' stays literal.
                if character == "#" && !inQuote && depth == 1 { body += "\u{2}" } else { body.append(character) }
                index += 1
            }
            branches.append((selector, body))
        }
        return (parts[0], branches)
    }
}
