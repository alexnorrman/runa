import Crypto
import Foundation

/// Short, stable hashes shared with the Figma plugin (which computes the same values in TypeScript).
public enum TextHash {
    /// 12 hex characters of SHA-256 over the forms in CLDR order, each as `category U+001F value`,
    /// joined by U+001E. Empty forms are skipped.
    public static func of(forms: [PluralCategory: String]) -> String {
        let input = PluralCategory.allCases
            .compactMap { category -> String? in
                guard let value = forms[category], !value.isEmpty else { return nil }
                return "\(category.rawValue)\u{1F}\(value)"
            }
            .joined(separator: "\u{1E}")
        return hex(SHA256.hash(data: Data(input.utf8))).prefix(12).description
    }

    /// A UUID derived from a key name, used for sheet rows that do not have an id yet, so the
    /// same row gets the same id on every pull. SHA-256 of `runa:key:<name>`, first 16 bytes,
    /// with version 5 and RFC 4122 variant bits set.
    public static func uuid(forKey name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("runa:key:\(name)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension UUID {
    /// Lowercase form used in sheets and files.
    public var lowercased: String { uuidString.lowercased() }
}
