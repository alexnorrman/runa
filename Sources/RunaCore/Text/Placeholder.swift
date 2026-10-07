import Foundation

public enum PlaceholderType: Hashable, Sendable, Codable {
    case string
    case int
    /// A floating point number, optionally with a fixed number of decimals.
    case double(precision: Int?)

    public var canonicalSuffix: String? {
        switch self {
        case .string: nil
        case .int: "int"
        case .double(nil): "double"
        case .double(let precision?): "double.\(precision)"
        }
    }
}

/// A named, typed placeholder: `{name}`, `{count:int}`, `{price:double.2}`.
public struct Placeholder: Hashable, Sendable, Codable {
    public var name: String
    public var type: PlaceholderType

    public init(name: String, type: PlaceholderType = .string) {
        self.name = name
        self.type = type
    }

    public var canonical: String {
        if let suffix = type.canonicalSuffix { return "{\(name):\(suffix)}" }
        return "{\(name)}"
    }
}

public enum TextSegment: Hashable, Sendable {
    case literal(String)
    case placeholder(Placeholder)
}

/// Runa's canonical text: plain text with `{name}` or `{name:type}` placeholders.
///
/// A brace that does not open a well-formed placeholder is literal text, so ordinary copy with
/// braces survives untouched. Types: `string` (default), `int`, `double`, `double.N`.
public enum CanonicalText {
    public static func parse(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        var literal = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "{", let (placeholder, end) = placeholder(in: text, at: index) {
                if !literal.isEmpty {
                    segments.append(.literal(literal))
                    literal = ""
                }
                segments.append(.placeholder(placeholder))
                index = end
            } else {
                literal.append(text[index])
                index = text.index(after: index)
            }
        }
        if !literal.isEmpty { segments.append(.literal(literal)) }
        return segments
    }

    public static func render(_ segments: [TextSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .literal(let text): text
            case .placeholder(let placeholder): placeholder.canonical
            }
        }.joined()
    }

    /// Unique placeholders in order of first appearance. A later typed use refines an untyped one.
    public static func placeholders(in text: String) -> [Placeholder] {
        var result: [Placeholder] = []
        for case .placeholder(let placeholder) in parse(text) {
            if let existing = result.firstIndex(where: { $0.name == placeholder.name }) {
                if result[existing].type == .string, placeholder.type != .string { result[existing] = placeholder }
            } else {
                result.append(placeholder)
            }
        }
        return result
    }

    private static func placeholder(in text: String, at start: String.Index) -> (Placeholder, String.Index)? {
        guard let close = text[start...].firstIndex(of: "}") else { return nil }
        let body = text[text.index(after: start)..<close]
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        guard isIdentifier(name) else { return nil }
        var type = PlaceholderType.string
        if parts.count == 2 {
            guard let parsed = parseType(String(parts[1])) else { return nil }
            type = parsed
        }
        return (Placeholder(name: name, type: type), text.index(after: close))
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    static func parseType(_ raw: String) -> PlaceholderType? {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch lowered {
        case "string", "str", "text": return .string
        case "int", "integer": return .int
        case "double", "float", "number", "decimal": return .double(precision: nil)
        default:
            for prefix in ["double.", "float.", "number.", "decimal."] where lowered.hasPrefix(prefix) {
                if let precision = Int(lowered.dropFirst(prefix.count)), (0...10).contains(precision) {
                    return .double(precision: precision)
                }
            }
            return nil
        }
    }
}
