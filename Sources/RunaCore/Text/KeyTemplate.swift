import Foundation

/// The shape of a project's key names, written as a template:
///
///     {platform?}_{feature}_{description}_{type:title|text|action}
///
/// - `{name}` is one lowerCamelCase word: a letter, then letters and digits (`home`, `welcomeCard`).
/// - `{name:a|b|c}` is one of the listed values.
/// - `{platform}` is `ios`, `android` or `web` unless values are listed.
/// - `?` makes a part optional together with the text right after it (`{platform?}_`), or right before it
///   when it is the last part.
/// - Everything outside braces is literal.
///
/// The Figma plugin implements the same rules in `figma-plugin/src/core/keys.ts`; docs/SHEET_FORMAT.md has
/// shared test vectors.
public struct KeyTemplate: Hashable, Sendable {
    public enum Part: Hashable, Sendable {
        case literal(String)
        case token(name: String, optional: Bool, choices: [String])
    }

    public let source: String
    public let parts: [Part]

    public struct ParseError: Error, LocalizedError, Hashable {
        public var message: String
        public var errorDescription: String? { message }
    }

    static let platformChoices = Platform.allCases.map(\.rawValue)

    public init(_ source: String) throws {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [Part] = []
        var literal = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "}" { throw ParseError(message: "The key template has a \"}\" without a matching \"{\".") }
            guard character == "{" else {
                literal.append(character)
                index = source.index(after: index)
                continue
            }
            guard let close = source[index...].firstIndex(of: "}") else {
                throw ParseError(message: "The key template has a \"{\" without a matching \"}\".")
            }
            if !literal.isEmpty {
                parts.append(.literal(literal))
                literal = ""
            }
            parts.append(try Self.token(String(source[source.index(after: index)..<close])))
            index = source.index(after: close)
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        guard parts.contains(where: { if case .token = $0 { true } else { false } }) else {
            throw ParseError(message: "The key template needs at least one part in braces, such as {feature}.")
        }
        let platformParts = parts.filter { if case .token(let name, _, _) = $0 { name.lowercased() == "platform" } else { false } }
        guard platformParts.count <= 1 else { throw ParseError(message: "The key template can name the platform only once.") }
        self.source = source
        self.parts = parts
    }

    static func token(_ body: String) throws -> Part {
        var spec = body.trimmingCharacters(in: .whitespaces)
        var choices: [String] = []
        if let colon = spec.firstIndex(of: ":") {
            choices = spec[spec.index(after: colon)...].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            spec = String(spec[..<colon])
            guard !choices.isEmpty, choices.allSatisfy({ !$0.isEmpty && $0.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil }) else {
                throw ParseError(message: "List values in {\(body)} as letters, digits, \"_\" or \"-\", separated by \"|\".")
            }
        }
        let optional = spec.hasSuffix("?")
        if optional { spec.removeLast() }
        guard spec.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil else {
            throw ParseError(message: "{\(body)} is not a valid part name. Use a word such as {feature}.")
        }
        return .token(name: spec, optional: optional, choices: choices)
    }

    /// Values a token accepts, or nil for a free lowerCamelCase word.
    static func choices(name: String, listed: [String]) -> [String]? {
        if !listed.isEmpty { return listed }
        return name.lowercased() == "platform" ? platformChoices : nil
    }

    static let wordPattern = "[a-z][a-zA-Z0-9]*"

    /// A regular expression that matches a whole key name. The platform part is captured as `platform`.
    public var pattern: String {
        var groups: [[Part]] = []
        var index = 0
        // Group each optional token with the literal that follows it (or, when it is last, the one before it).
        while index < parts.count {
            if case .token(_, true, _) = parts[index] {
                if index + 1 < parts.count, case .literal = parts[index + 1] {
                    groups.append([parts[index], parts[index + 1]])
                    index += 2
                    continue
                }
                if index == parts.count - 1, let last = groups.last, last.count == 1, case .literal = last[0] {
                    groups[groups.count - 1] = [last[0], parts[index]]
                    index += 1
                    continue
                }
            }
            groups.append([parts[index]])
            index += 1
        }
        var regex = "^"
        for group in groups {
            let body = group.map(Self.regex).joined()
            let optional = group.contains { if case .token(_, true, _) = $0 { true } else { false } }
            regex += optional ? "(?:\(body))?" : body
        }
        return regex + "$"
    }

    static func regex(_ part: Part) -> String {
        switch part {
        case .literal(let text):
            return NSRegularExpression.escapedPattern(for: text)
        case .token(let name, _, let listed):
            guard let values = choices(name: name, listed: listed) else { return wordPattern }
            let alternatives = values.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            return name.lowercased() == "platform" ? "(?<platform>\(alternatives))" : "(?:\(alternatives))"
        }
    }

    /// Platforms the template's platform part may name, or empty when it has none.
    public var platformOptions: [Platform] {
        for case .token(let name, _, let listed) in parts where name.lowercased() == "platform" {
            return (Self.choices(name: name, listed: listed) ?? []).compactMap { Platform(rawValue: $0.lowercased()) }
        }
        return []
    }
}

/// A project's naming rules, from its guidelines. Without a template or pattern, only the basic syntax applies.
public struct KeyNamingRules {
    public let template: KeyTemplate?
    /// The custom pattern from the guidelines, when there is one.
    public let customPattern: String?
    /// Template or pattern errors; when not empty, the broken rule is ignored.
    public let configurationProblems: [String]
    private let regex: NSRegularExpression?
    private let customRegex: NSRegularExpression?

    public init(_ guidelines: ProjectGuidelines) {
        var problems: [String] = []
        var template: KeyTemplate?
        let templateText = guidelines.keyTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !templateText.isEmpty {
            do { template = try KeyTemplate(templateText) } catch { problems.append((error as? LocalizedError)?.errorDescription ?? "\(error)") }
        }
        let custom = guidelines.keyPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        var regex: NSRegularExpression?
        if !custom.isEmpty {
            do {
                regex = try NSRegularExpression(pattern: custom)
            } catch {
                problems.append("The key pattern is not a valid regular expression.")
            }
        }
        self.customRegex = regex
        if regex == nil, let template { regex = try? NSRegularExpression(pattern: template.pattern) }
        self.template = template
        self.customPattern = custom.isEmpty ? nil : custom
        self.configurationProblems = problems
        self.regex = regex
    }

    /// True when names are checked against more than the basic syntax.
    public var isActive: Bool { regex != nil }

    /// What a key should look like, for hints and error messages.
    public var formatDescription: String? {
        if let customPattern, usesCustomPattern { return "a name matching \(customPattern)" }
        return template?.source
    }

    /// True when names are checked against the custom pattern rather than the template.
    var usesCustomPattern: Bool { customRegex != nil }

    func matches(_ name: String) -> Bool {
        guard let regex else { return true }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range) else { return false }
        return match.range == range
    }

    /// Nil when the name is fine, otherwise one sentence saying what is wrong.
    public func problem(with name: String) -> String? {
        if let problem = KeyNaming.problem(with: name) { return problem }
        guard regex != nil, !matches(name) else { return nil }
        if let dot = name.lastIndex(of: "."), PluralCategory(rawValue: String(name[name.index(after: dot)...])) != nil,
            matches(String(name[..<dot]))
        {
            return "Plural forms are not part of the key name. Create one plural key named \(name[..<dot]) and give it one and other forms."
        }
        if let customPattern, usesCustomPattern { return "\(name) does not follow the key pattern \(customPattern)." }
        return "\(name) does not follow the key format \(template?.source ?? "")."
    }

    /// The platform a name starts with, such as `ios` in `ios_checkout_pay_action`. Only templates with a platform part name one.
    public func platform(in name: String) -> Platform? {
        guard let template, !template.platformOptions.isEmpty,
            let regex = try? NSRegularExpression(pattern: template.pattern)
        else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range), match.range == range else { return nil }
        let group = match.range(withName: "platform")
        guard group.location != NSNotFound, let swiftRange = Range(group, in: name) else { return nil }
        return Platform(rawValue: name[swiftRange].lowercased())
    }

    /// Platforms a new key should ship to, from its name: `[.ios]` for `ios_…`. Nil when the name does not say.
    public func impliedPlatforms(for name: String) -> [Platform]? {
        platform(in: name).map { [$0] }
    }

    /// Nil when a key's name and its platforms agree.
    public func platformProblem(for key: StringKey) -> String? {
        guard let template, !template.platformOptions.isEmpty else { return nil }
        if let platform = platform(in: key.key) {
            guard Set(key.platforms) != [platform] else { return nil }
            let shipped = key.platforms.isEmpty ? "every platform" : key.platforms.map(\.displayName).joined(separator: " and ")
            return "\(key.key) starts with \(platform.rawValue) but ships to \(shipped). Limit it to \(platform.displayName), or rename it."
        }
        if key.platforms.count == 1, let only = key.platforms.first, template.platformOptions.contains(only) {
            return "\(key.key) only ships to \(only.displayName), so its name should start with \(only.rawValue)."
        }
        return nil
    }
}
