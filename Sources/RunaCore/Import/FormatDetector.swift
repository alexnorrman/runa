import Foundation

/// Works out a file's format and locale from its path, the way developers lay files out.
public enum FormatDetector {
    public struct Detection: Sendable, Hashable {
        public var kind: FormatKind
        /// nil for String Catalogs (they contain every locale) or when the path does not say.
        public var locale: LocaleCode?
        /// True for Android `values/` and Apple `Base.lproj`, which hold the default language.
        public var isDefaultLocale: Bool
    }

    public static func detect(path: String, contents: Data? = nil) -> Detection? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "xcstrings":
            return Detection(kind: .xcstrings, locale: nil, isDefaultLocale: false)
        case "strings", "stringsdict":
            if parent == "Base.lproj" { return Detection(kind: .appleStrings, locale: nil, isDefaultLocale: true) }
            if parent.hasSuffix(".lproj") {
                return Detection(kind: .appleStrings, locale: LocaleCode(rawValue: String(parent.dropLast(6))), isDefaultLocale: false)
            }
            return Detection(kind: .appleStrings, locale: nil, isDefaultLocale: false)
        case "xml":
            if parent == "values" { return Detection(kind: .android, locale: nil, isDefaultLocale: true) }
            return Detection(kind: .android, locale: KeyNaming.locale(fromAndroidFolder: parent), isDefaultLocale: false)
        case "json":
            let stem = url.deletingPathExtension().lastPathComponent
            let locale = LocaleCode(rawValue: stem).flatMap { $0.isKnownLanguage ? $0 : nil }
                ?? LocaleCode(rawValue: parent).flatMap { $0.isKnownLanguage ? $0 : nil }
            var kind = FormatKind.i18next
            if let contents, let text = String(data: contents, encoding: .utf8), text.contains(", plural,") { kind = .icu }
            _ = name
            return Detection(kind: kind, locale: locale, isDefaultLocale: false)
        default:
            return nil
        }
    }

    /// Parses any supported file into entries.
    ///
    /// - Parameters:
    ///   - locale: Overrides the detected locale.
    ///   - defaultLocale: Used for Android `values/` and `Base.lproj`, normally the project's source locale.
    public static func parse(path: String, data: Data, locale: LocaleCode? = nil, defaultLocale: LocaleCode) throws
        -> (entries: [ImportedEntry], warnings: [String])
    {
        guard let detection = detect(path: path, contents: data) else {
            throw FormatError.invalidFile(path, reason: "Unsupported file type")
        }
        let file = displayPath(path)
        func resolvedLocale() throws -> LocaleCode {
            if let locale { return locale }
            if detection.isDefaultLocale { return defaultLocale }
            guard let detected = detection.locale else { throw FormatError.unknownLocale(file) }
            return detected
        }
        switch detection.kind {
        case .xcstrings:
            let result = try XCStringsFormat.parse(data, file: file)
            return (result.entries, result.warnings)
        case .appleStrings:
            if path.hasSuffix(".stringsdict") { return try AppleStringsFormat.parseStringsdict(data, locale: resolvedLocale(), file: file) }
            return (try AppleStringsFormat.parseStrings(data, locale: resolvedLocale(), file: file), [])
        case .android:
            return try AndroidXMLFormat.parse(data, locale: resolvedLocale(), file: file)
        case .i18next:
            return (try I18nextFormat.parse(data, locale: resolvedLocale(), file: file), [])
        case .icu:
            return try ICUJSONFormat.parse(data, locale: resolvedLocale(), file: file)
        }
    }

    /// Last two path components, enough to tell `values-sv/strings.xml` from `values-de/strings.xml`.
    static func displayPath(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.suffix(2).joined(separator: "/")
    }
}
