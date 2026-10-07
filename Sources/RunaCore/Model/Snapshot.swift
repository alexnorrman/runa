import Foundation

public struct ProjectSettings: Hashable, Codable, Sendable {
    public var name: String
    public var sourceLocale: LocaleCode
    /// Every locale in the project, source first.
    public var locales: [LocaleCode]
    public var schemaVersion: Int

    public static let currentSchemaVersion = 1

    public init(name: String, sourceLocale: LocaleCode, locales: [LocaleCode] = [], schemaVersion: Int = currentSchemaVersion) {
        self.name = name
        self.sourceLocale = sourceLocale
        var ordered = [sourceLocale]
        for locale in locales where !ordered.contains(locale) { ordered.append(locale) }
        self.locales = ordered
        self.schemaVersion = schemaVersion
    }

    /// Locales other than the source locale.
    public var targetLocales: [LocaleCode] { locales.filter { $0 != sourceLocale } }
}

public struct SnapshotWarning: Hashable, Codable, Sendable, CustomStringConvertible {
    public var message: String
    public var location: String?

    public init(_ message: String, location: String? = nil) {
        self.message = message
        self.location = location
    }

    public var description: String {
        if let location { return "\(location): \(message)" }
        return message
    }
}

/// Everything in a project at one point in time.
public struct Snapshot: Hashable, Codable, Sendable {
    public var settings: ProjectSettings
    public var keys: [StringKey]
    public var fetchedAt: Date
    public var warnings: [SnapshotWarning]

    public init(settings: ProjectSettings, keys: [StringKey] = [], fetchedAt: Date = Date(), warnings: [SnapshotWarning] = []) {
        self.settings = settings
        self.keys = keys
        self.fetchedAt = fetchedAt
        self.warnings = warnings
    }

    public subscript(id id: UUID) -> StringKey? {
        keys.first { $0.id == id }
    }

    public func key(named name: String) -> StringKey? {
        keys.first { $0.key == name }
    }

    public func index(of id: UUID) -> Int? {
        keys.firstIndex { $0.id == id }
    }

    /// Hash of a key's source-locale text, used to detect stale translations.
    public func sourceHash(of key: StringKey) -> String? {
        guard let source = key.translations[settings.sourceLocale], !source.isEmpty else { return nil }
        return source.hash
    }

    /// Plural categories a locale must fill for a key.
    public func requiredCategories(for key: StringKey, locale: LocaleCode) -> [PluralCategory] {
        key.isPlural ? PluralRules.requiredCategories(for: locale) : [.other]
    }

    /// The effective status of a key in a locale.
    ///
    /// - A missing value (or a missing required plural form) is `.missing`.
    /// - The source locale is `.approved` when present.
    /// - A translation whose recorded source hash differs from the current source text is
    ///   `.needsReview`, unless it is already a machine draft.
    public func status(of key: StringKey, locale: LocaleCode) -> TranslationStatus {
        if key.doNotTranslate && locale != settings.sourceLocale {
            return status(of: key, locale: settings.sourceLocale)
        }
        guard let translation = key.translations[locale] else { return .missing }
        for category in requiredCategories(for: key, locale: locale) {
            if (translation.forms[category] ?? "").isEmpty { return .missing }
        }
        if locale == settings.sourceLocale { return .approved }
        if translation.status == .approved || translation.status == .needsReview,
            let recorded = translation.sourceHash, let current = sourceHash(of: key), recorded != current
        {
            return .needsReview
        }
        return translation.status == .missing ? .approved : translation.status
    }

    public func coverage(for locale: LocaleCode) -> Coverage {
        var coverage = Coverage(locale: locale)
        for key in keys {
            coverage.total += 1
            switch status(of: key, locale: locale) {
            case .missing: coverage.missing += 1
            case .machine: coverage.machine += 1
            case .needsReview: coverage.needsReview += 1
            case .approved: coverage.approved += 1
            }
        }
        return coverage
    }

    /// Keys that are missing in at least one locale, with the locales they are missing in.
    public func missingTranslations() -> [(key: StringKey, locales: [LocaleCode])] {
        keys.compactMap { key in
            let missing = settings.locales.filter { status(of: key, locale: $0) == .missing }
            return missing.isEmpty ? nil : (key, missing)
        }
    }
}

public struct Coverage: Hashable, Sendable {
    public var locale: LocaleCode
    public var total = 0
    public var approved = 0
    public var machine = 0
    public var needsReview = 0
    public var missing = 0

    public init(locale: LocaleCode) { self.locale = locale }

    /// Share of keys with any value, 0...1.
    public var translatedFraction: Double { total == 0 ? 1 : Double(total - missing) / Double(total) }
    /// Share of keys approved, 0...1.
    public var approvedFraction: Double { total == 0 ? 1 : Double(approved) / Double(total) }
    public var isComplete: Bool { missing == 0 }
}
