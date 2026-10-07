import Foundation

/// A normalised BCP 47 language tag such as `en`, `sv`, `pt-BR` or `zh-Hans`.
///
/// Normalisation lowercases the language, title-cases a script and uppercases a region,
/// and accepts `_` as a separator, so `pt_br` and `PT-BR` both become `pt-BR`.
public struct LocaleCode: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    CodingKeyRepresentable, ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard let normalized = Self.normalize(rawValue) else { return nil }
        self.rawValue = normalized
    }

    public init(stringLiteral value: String) {
        self.rawValue = Self.normalize(value) ?? value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let code = LocaleCode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid locale code '\(raw)'")
        }
        self = code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: CodingKey { StringCodingKey(rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: LocaleCode, rhs: LocaleCode) -> Bool { lhs.rawValue < rhs.rawValue }

    private var parts: [Substring] { rawValue.split(separator: "-") }

    /// The language subtag, for example `pt` for `pt-BR`.
    public var language: String { String(parts.first ?? "") }

    /// The script subtag, for example `Hans` for `zh-Hans`.
    public var script: String? {
        parts.dropFirst().first(where: { $0.count == 4 && $0.allSatisfy(\.isLetter) }).map(String.init)
    }

    /// The region subtag, for example `BR` for `pt-BR`.
    public var region: String? {
        parts.dropFirst().first(where: {
            ($0.count == 2 && $0.allSatisfy(\.isLetter)) || ($0.count == 3 && $0.allSatisfy(\.isNumber))
        }).map(String.init)
    }

    /// Whether the language subtag is a real ISO 639 language. Used to tell locale columns
    /// apart from other columns in a sheet.
    public var isKnownLanguage: Bool {
        Locale.LanguageCode(language).isISOLanguage
    }

    /// A human readable name such as "Swedish" or "Portuguese (Brazil)".
    public func displayName(in displayLocale: Locale = Locale(identifier: "en")) -> String {
        displayLocale.localizedString(forIdentifier: rawValue) ?? rawValue
    }

    /// Whether the language is written right to left.
    public var isRightToLeft: Bool {
        Locale.Language(identifier: rawValue).characterDirection == .rightToLeft
    }

    static func normalize(_ string: String) -> String? {
        let parts = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = parts.first, (2...3).contains(first.count),
            first.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return nil }
        var output = [first.lowercased()]
        for part in parts.dropFirst() {
            guard (1...8).contains(part.count), part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { return nil }
            if part.count == 4, part.allSatisfy(\.isLetter) {
                output.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())
            } else if (part.count == 2 && part.allSatisfy(\.isLetter)) || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                output.append(part.uppercased())
            } else {
                output.append(part.lowercased())
            }
        }
        return output.joined(separator: "-")
    }
}

struct StringCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
