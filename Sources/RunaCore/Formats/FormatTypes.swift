import Foundation

public enum FormatKind: String, Codable, Sendable, CaseIterable {
    /// Xcode String Catalog, every locale in one file.
    case xcstrings
    /// Legacy `<locale>.lproj/Localizable.strings` and `.stringsdict`.
    case appleStrings = "apple-strings"
    /// `res/values-<locale>/strings.xml`.
    case android
    /// i18next JSON, one file per locale.
    case i18next
    /// ICU MessageFormat JSON, one file per locale.
    case icu

    public var displayName: String {
        switch self {
        case .xcstrings: "String Catalog (.xcstrings)"
        case .appleStrings: "Strings files (.strings, .stringsdict)"
        case .android: "Android (strings.xml)"
        case .i18next: "i18next JSON"
        case .icu: "ICU MessageFormat JSON"
        }
    }

    public var platform: Platform {
        switch self {
        case .xcstrings, .appleStrings: .ios
        case .android: .android
        case .i18next, .icu: .web
        }
    }

    public var placeholderFlavor: PlaceholderFlavor {
        switch self {
        case .xcstrings, .appleStrings: .apple
        case .android: .android
        case .i18next: .i18next
        case .icu: .icu
        }
    }
}

public struct ExportOptions: Sendable, Hashable {
    /// When false, only approved translations are written. Machine drafts and translations that
    /// need review are left out, so the app falls back to the source language.
    public var includeUnapproved: Bool
    /// Write key descriptions as comments where the format supports them.
    public var includeComments: Bool
    /// i18next: nest keys on dots (`{"checkout": {"title": …}}`) instead of flat keys.
    public var nested: Bool
    /// Path pattern for formats with one file per locale, relative to the target directory.
    /// `{locale}` is replaced. Defaults: `{locale}.json`.
    public var filePattern: String?
    /// Apple strings: table name. Defaults to `Localizable`.
    public var tableName: String
    /// Android: write `values-iw`, `values-in` and `values-ji` for Hebrew, Indonesian and Yiddish,
    /// which older Android versions require.
    public var androidLegacyLanguageCodes: Bool

    public init(includeUnapproved: Bool = true, includeComments: Bool = true, nested: Bool = false, filePattern: String? = nil,
                tableName: String = "Localizable", androidLegacyLanguageCodes: Bool = true)
    {
        self.includeUnapproved = includeUnapproved
        self.includeComments = includeComments
        self.nested = nested
        self.filePattern = filePattern
        self.tableName = tableName
        self.androidLegacyLanguageCodes = androidLegacyLanguageCodes
    }
}

public struct ExportedFile: Hashable, Sendable {
    /// Path relative to the target's directory.
    public var relativePath: String
    public var contents: Data

    public init(relativePath: String, contents: Data) {
        self.relativePath = relativePath
        self.contents = contents
    }

    public var text: String { String(decoding: contents, as: UTF8.self) }
}

public struct ExportResult: Sendable {
    public var files: [ExportedFile]
    public var warnings: [String]
}

/// One key in one locale as read from a platform file, still in platform syntax.
public struct ImportedEntry: Hashable, Sendable {
    /// Key as written in the file, such as `checkout_title` in Android.
    public var key: String
    public var locale: LocaleCode
    public var isPlural: Bool
    public var forms: [PluralCategory: String]
    public var comment: String?
    public var translatable: Bool
    public var flavor: PlaceholderFlavor
    /// Status the file recorded, if any (String Catalogs record `needs_review`).
    public var status: TranslationStatus?
    /// File the entry came from, for display.
    public var file: String

    public init(key: String, locale: LocaleCode, isPlural: Bool = false, forms: [PluralCategory: String], comment: String? = nil,
                translatable: Bool = true, flavor: PlaceholderFlavor, status: TranslationStatus? = nil, file: String)
    {
        self.key = key
        self.locale = locale
        self.isPlural = isPlural
        self.forms = forms
        self.comment = comment
        self.translatable = translatable
        self.flavor = flavor
        self.status = status
        self.file = file
    }
}

public enum FormatError: Error, LocalizedError, Sendable {
    case invalidFile(String, reason: String)
    case unknownLocale(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let file, let reason): "\(file) could not be read: \(reason)"
        case .unknownLocale(let file): "Could not tell which language \(file) is. Pass the locale explicitly."
        }
    }
}

/// Shared helpers for exporters.
struct ExportContext {
    let snapshot: Snapshot
    let options: ExportOptions
    let platform: Platform

    var source: LocaleCode { snapshot.settings.sourceLocale }

    var keys: [StringKey] {
        snapshot.keys.filter { $0.appliesTo(platform) }.sorted { $0.key < $1.key }
    }

    /// The forms to export for a key in a locale, or nil when nothing should be written.
    func forms(for key: StringKey, locale: LocaleCode) -> [PluralCategory: String]? {
        if key.doNotTranslate && locale != source { return nil }
        guard let translation = key.translations[locale] else { return nil }
        let forms = translation.nonEmptyForms
        if forms.isEmpty { return nil }
        if locale != source && !options.includeUnapproved && snapshot.status(of: key, locale: locale) != .approved { return nil }
        if key.isPlural { return forms }
        guard let other = forms[.other] else { return nil }
        return [.other: other]
    }

    func renderOptions(for key: StringKey) -> RenderOptions {
        let order = key.placeholders(sourceLocale: source)
        let pluralVariable = key.isPlural ? order.first(where: { $0.type == .int })?.name : nil
        return RenderOptions(argumentOrder: order, pluralVariable: pluralVariable)
    }

    func status(_ key: StringKey, _ locale: LocaleCode) -> TranslationStatus {
        locale == source ? .approved : snapshot.status(of: key, locale: locale)
    }
}
