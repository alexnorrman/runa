import Foundation

public enum KeyNaming {
    /// Android resource names allow letters, digits and underscores, and cannot start with a digit.
    /// `checkout.summary-title` becomes `checkout_summary_title`.
    public static func androidName(_ key: String) -> String {
        var name = String(key.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "_" { return Character(scalar) }
            return "_"
        })
        if let first = name.first, first.isNumber { name = "_" + name }
        return name.isEmpty ? "_" : name
    }

    /// Android resource folder for a locale: `values`, `values-sv`, `values-pt-rBR`, `values-b+zh+Hans`.
    public static func androidValuesFolder(_ locale: LocaleCode, isDefault: Bool, legacyCodes: Bool) -> String {
        if isDefault { return "values" }
        var language = locale.language
        if legacyCodes {
            language = ["he": "iw", "id": "in", "yi": "ji"][language] ?? language
        }
        if let script = locale.script {
            var parts = ["b", language, script]
            if let region = locale.region { parts.append(region) }
            return "values-" + parts.joined(separator: "+")
        }
        if let region = locale.region { return "values-\(language)-r\(region)" }
        return "values-\(language)"
    }

    /// Parses an Android values folder name back to a locale. `values` returns nil.
    public static func locale(fromAndroidFolder folder: String) -> LocaleCode? {
        guard folder.hasPrefix("values-") else { return nil }
        let qualifiers = folder.dropFirst("values-".count)
        if qualifiers.hasPrefix("b+") {
            let parts = qualifiers.dropFirst(2).split(separator: "+").map(String.init)
            return LocaleCode(rawValue: modernLanguage(parts.joined(separator: "-")))
        }
        let parts = qualifiers.split(separator: "-").map(String.init)
        guard let language = parts.first, (2...3).contains(language.count), language.allSatisfy(\.isLetter) else { return nil }
        var code = modernLanguage(language)
        if parts.count > 1, parts[1].hasPrefix("r"), parts[1].count == 3 { code += "-" + parts[1].dropFirst() }
        return LocaleCode(rawValue: code)
    }

    private static func modernLanguage(_ code: String) -> String {
        let parts = code.split(separator: "-", maxSplits: 1).map(String.init)
        let language = ["iw": "he", "in": "id", "ji": "yi"][parts[0]] ?? parts[0]
        return ([language] + parts.dropFirst()).joined(separator: "-")
    }
}

extension KeyNaming {
    /// Why a key name is not acceptable, or nil when it is. Keys use letters, digits, `_` and `-`
    /// in dot-separated segments: `checkout.summary.title`.
    public static func problem(with key: String) -> String? {
        if key.isEmpty { return "The key is empty." }
        if key.count > 200 { return "Keys are limited to 200 characters." }
        if key.hasPrefix(".") || key.hasSuffix(".") || key.contains("..") { return "Dots separate segments; a segment cannot be empty." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        if key.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use letters, digits, \"_\", \"-\" and \".\" only."
        }
        return nil
    }
}
