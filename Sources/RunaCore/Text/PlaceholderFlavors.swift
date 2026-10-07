import Foundation

/// Converts canonical text to and from platform placeholder syntaxes.
public enum PlaceholderFlavor: String, Sendable, Codable {
    /// `%@`, `%lld`, `%f`; positional (`%1$@`) when the key has more than one placeholder.
    case apple
    /// `%1$s`, `%1$d`, `%1$.2f`, always positional.
    case android
    /// `{{name}}`.
    case i18next
    /// `{name}`.
    case icu
}

public struct RenderOptions: Sendable {
    /// The key's placeholders in argument order. Indexes for positional formats come from here,
    /// so every plural form and every locale numbers arguments the same way.
    public var argumentOrder: [Placeholder]
    /// For i18next plurals: the placeholder that selects the plural form, renamed to `count`.
    public var pluralVariable: String?

    public init(argumentOrder: [Placeholder], pluralVariable: String? = nil) {
        self.argumentOrder = argumentOrder
        self.pluralVariable = pluralVariable
    }
}

public enum PlaceholderConverter {
    // MARK: Canonical to platform

    public static func render(_ canonical: String, flavor: PlaceholderFlavor, options: RenderOptions) -> String {
        let segments = CanonicalText.parse(canonical)
        var order = options.argumentOrder
        for case .placeholder(let placeholder) in segments where !order.contains(where: { $0.name == placeholder.name }) {
            order.append(placeholder)
        }
        let hasArguments = !order.isEmpty
        switch flavor {
        case .apple, .android:
            let positional = flavor == .android || order.count > 1
            return segments.map { segment in
                switch segment {
                case .literal(let text):
                    return hasArguments ? text.replacingOccurrences(of: "%", with: "%%") : text
                case .placeholder(let placeholder):
                    let index = (order.firstIndex { $0.name == placeholder.name } ?? 0) + 1
                    let type = order.first { $0.name == placeholder.name }?.type ?? placeholder.type
                    return printfSpecifier(type: type, flavor: flavor, position: positional ? index : nil)
                }
            }.joined()
        case .i18next:
            return segments.map { segment in
                switch segment {
                case .literal(let text): return text
                case .placeholder(let placeholder):
                    let name = placeholder.name == options.pluralVariable ? "count" : placeholder.name
                    return "{{\(name)}}"
                }
            }.joined()
        case .icu:
            return segments.map { segment in
                switch segment {
                case .literal(let text): return ICUEscaping.escape(text)
                case .placeholder(let placeholder):
                    switch placeholder.type {
                    case .string: return "{\(placeholder.name)}"
                    case .int: return "{\(placeholder.name), number, integer}"
                    case .double: return "{\(placeholder.name), number}"
                    }
                }
            }.joined()
        }
    }

    static func printfSpecifier(type: PlaceholderType, flavor: PlaceholderFlavor, position: Int?) -> String {
        let prefix = position.map { "%\($0)$" } ?? "%"
        switch (type, flavor) {
        case (.string, .apple): return prefix + "@"
        case (.string, _): return prefix + "s"
        case (.int, .apple): return prefix + "lld"
        case (.int, _): return prefix + "d"
        case (.double(nil), _): return prefix + "f"
        case (.double(let precision?), _): return prefix + ".\(precision)f"
        }
    }

    // MARK: Platform to canonical

    /// Converts a platform string to canonical text.
    ///
    /// - Parameter names: The existing key's placeholders in argument order. Arguments are named
    ///   after them by position, so importing `Hi %@` into a key that has `{name}` keeps `{name}`.
    ///   Without names, arguments become `{arg1}`, `{arg2}`, or a single `{count:int}` / `{value}`.
    public static func parse(_ text: String, flavor: PlaceholderFlavor, names: [Placeholder] = []) -> String {
        switch flavor {
        case .apple, .android: return parsePrintf(text, names: names)
        case .i18next: return parseI18next(text, names: names)
        case .icu: return parseICU(text)
        }
    }

    /// Specifiers UI strings actually use. The space flag and rare conversions (`%o`, `%e`, `%c`…)
    /// are left out on purpose: "100% off" and "50% each" are copy, not format strings.
    private static let printfPattern = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?([-+0#]*)(\d+)?(?:\.(\d+))?(hh|h|ll|l|q|z|t|j)?([@diufFsS%])"#
    )

    struct PrintfToken {
        var range: Range<String.Index>
        var position: Int?
        var type: PlaceholderType?   // nil for %%
    }

    static func printfTokens(in text: String) -> [PrintfToken] {
        let ns = text as NSString
        return printfPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let conversion = group(6) ?? ""
            let type: PlaceholderType?
            switch conversion {
            case "%": type = nil
            case "@", "s", "S": type = .string
            case "f", "F": type = .double(precision: group(4).flatMap(Int.init))
            default: type = .int
            }
            return PrintfToken(range: range, position: group(1).flatMap(Int.init), type: type)
        }
    }

    static func parsePrintf(_ text: String, names: [Placeholder]) -> String {
        let tokens = printfTokens(in: text)
        let arguments = tokens.filter { $0.type != nil }
        guard !arguments.isEmpty else {
            // A key with arguments in other languages is formatted everywhere, so %% is a literal %.
            return names.isEmpty ? text : text.replacingOccurrences(of: "%%", with: "%")
        }
        var nextSequential = 1
        var resolved: [(range: Range<String.Index>, replacement: String)] = []
        let argumentCount = Set(arguments.map { $0.position ?? 0 }).count
        for token in tokens {
            guard let type = token.type else {
                resolved.append((token.range, "%"))
                continue
            }
            let position: Int
            if let explicit = token.position {
                position = explicit
            } else {
                position = nextSequential
                nextSequential += 1
            }
            let name = argumentName(position: position, type: type, names: names, total: max(argumentCount, arguments.count))
            let typeToUse = names.indices.contains(position - 1) && names[position - 1].type != .string && type == .string ? names[position - 1].type : type
            resolved.append((token.range, Placeholder(name: name, type: typeToUse).canonical))
        }
        var output = ""
        var cursor = text.startIndex
        for item in resolved {
            output += text[cursor..<item.range.lowerBound]
            output += item.replacement
            cursor = item.range.upperBound
        }
        output += text[cursor...]
        return output
    }

    static func argumentName(position: Int, type: PlaceholderType, names: [Placeholder], total: Int) -> String {
        if names.indices.contains(position - 1) { return names[position - 1].name }
        if total == 1 {
            switch type {
            case .int: return "count"
            case .double: return "number"
            case .string: return "value"
            }
        }
        return "arg\(position)"
    }

    private static let i18nextPattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_.]*)\s*(?:,\s*([A-Za-z]+)[^}]*)?\}\}"#)

    static func parseI18next(_ text: String, names: [Placeholder]) -> String {
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in i18nextPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var name = ns.substring(with: match.range(at: 1))
            let format = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            var type: PlaceholderType = format == "number" ? .double(precision: nil) : .string
            if name == "count" {
                if let pluralName = names.first(where: { $0.type == .int })?.name { name = pluralName }
                type = .int
            }
            if let known = names.first(where: { $0.name == name }) { type = known.type }
            output += Placeholder(name: name.replacingOccurrences(of: ".", with: "_"), type: type).canonical
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }

    static func parseICU(_ text: String) -> String {
        // Simple arguments only: {name}, {name, number}, {name, number, integer}. Quotes are unescaped.
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "'" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "'" {
                    output.append("'")
                    index = text.index(after: next)
                    continue
                }
                if next < text.endIndex, "{}#|".contains(text[next]), let close = text[next...].firstIndex(of: "'") {
                    output += text[next..<close]
                    index = text.index(after: close)
                    continue
                }
                output.append(character)
                index = next
            } else if character == "{", let close = text[index...].firstIndex(of: "}") {
                let parts = text[text.index(after: index)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if let name = parts.first, CanonicalText.isIdentifier(name) {
                    var type = PlaceholderType.string
                    if parts.count >= 2, parts[1] == "number" {
                        type = parts.count >= 3 && parts[2] == "integer" ? .int : .double(precision: nil)
                    }
                    output += Placeholder(name: name, type: type).canonical
                } else {
                    output += text[index...close]
                }
                index = text.index(after: close)
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }
}

enum ICUEscaping {
    /// Escapes ICU MessageFormat syntax characters in literal text. Apostrophes are doubled and
    /// braces are quoted. Inside plural branches `#` is quoted too.
    static func escape(_ text: String, inPlural: Bool = false) -> String {
        var output = ""
        for character in text {
            switch character {
            case "'": output += "''"
            case "{", "}": output += "'\(character)'"
            case "#" where inPlural: output += "'#'"
            default: output.append(character)
            }
        }
        return output
    }
}
