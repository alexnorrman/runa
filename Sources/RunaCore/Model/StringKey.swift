import Foundation

public enum Platform: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case ios, android, web

    public static func < (lhs: Platform, rhs: Platform) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .ios: "iOS"
        case .android: "Android"
        case .web: "Web"
        }
    }
}

/// How far a translation has come. `missing` is never stored; it is what an absent value reads as.
public enum TranslationStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case missing
    case machine
    case needsReview = "needs-review"
    case approved

    public var displayName: String {
        switch self {
        case .missing: "Missing"
        case .machine: "Machine draft"
        case .needsReview: "Needs review"
        case .approved: "Approved"
        }
    }
}

/// One locale's value for a key. Non-plural keys keep their value under `.other`.
public struct Translation: Hashable, Codable, Sendable {
    public var forms: [PluralCategory: String]
    /// The stored status. Use `Snapshot.status(of:locale:)` for the effective status, which also
    /// accounts for the source text having changed since this translation was made.
    public var status: TranslationStatus
    /// Hash of the source-locale text this translation was written or approved against.
    public var sourceHash: String?
    public var updatedAt: Date?
    public var updatedBy: String?

    public init(
        forms: [PluralCategory: String],
        status: TranslationStatus = .approved,
        sourceHash: String? = nil,
        updatedAt: Date? = nil,
        updatedBy: String? = nil
    ) {
        self.forms = forms
        self.status = status
        self.sourceHash = sourceHash
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    public init(_ value: String, status: TranslationStatus = .approved) {
        self.init(forms: [.other: value], status: status)
    }

    public var value: String? { forms[.other] }

    /// Forms with non-empty text.
    public var nonEmptyForms: [PluralCategory: String] { forms.filter { !$0.value.isEmpty } }

    public var isEmpty: Bool { nonEmptyForms.isEmpty }

    public var hash: String { TextHash.of(forms: forms) }
}

/// The parts of a key that are not translations.
public struct KeyMetadata: Hashable, Codable, Sendable {
    public var key: String
    public var description: String
    public var tags: [String]
    public var platforms: [Platform]
    public var isPlural: Bool

    public init(key: String, description: String = "", tags: [String] = [], platforms: [Platform] = [], isPlural: Bool = false) {
        self.key = key
        self.description = description
        self.tags = tags
        self.platforms = platforms.sorted()
        self.isPlural = isPlural
    }
}

public struct StringKey: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var key: String
    public var description: String
    public var tags: [String]
    /// Platforms this key ships to. Empty means every platform.
    public var platforms: [Platform]
    public var isPlural: Bool
    public var contexts: [FigmaContext]
    public var translations: [LocaleCode: Translation]

    /// Tag that marks a key as "do not translate": every locale uses the source text.
    public static let doNotTranslateTag = "notranslate"

    public init(
        id: UUID = UUID(),
        key: String,
        description: String = "",
        tags: [String] = [],
        platforms: [Platform] = [],
        isPlural: Bool = false,
        contexts: [FigmaContext] = [],
        translations: [LocaleCode: Translation] = [:]
    ) {
        self.id = id
        self.key = key
        self.description = description
        self.tags = tags
        self.platforms = platforms.sorted()
        self.isPlural = isPlural
        self.contexts = contexts
        self.translations = translations
    }

    public var doNotTranslate: Bool { tags.contains(Self.doNotTranslateTag) }

    public func appliesTo(_ platform: Platform) -> Bool {
        platforms.isEmpty || platforms.contains(platform)
    }

    public func value(for locale: LocaleCode, _ category: PluralCategory = .other) -> String? {
        guard let value = translations[locale]?.forms[category], !value.isEmpty else { return nil }
        return value
    }

    public var metadata: KeyMetadata {
        get { KeyMetadata(key: key, description: description, tags: tags, platforms: platforms, isPlural: isPlural) }
        set {
            key = newValue.key
            description = newValue.description
            tags = newValue.tags
            platforms = newValue.platforms.sorted()
            isPlural = newValue.isPlural
        }
    }

    /// Placeholders used by the key, in order of first appearance in the source text.
    /// Placeholders that only appear in translations are appended after those.
    public func placeholders(sourceLocale: LocaleCode) -> [Placeholder] {
        var result: [Placeholder] = []
        var seen = Set<String>()
        func collect(_ text: String?) {
            guard let text else { return }
            for placeholder in CanonicalText.placeholders(in: text) where !seen.contains(placeholder.name) {
                seen.insert(placeholder.name)
                result.append(placeholder)
            }
        }
        let source = translations[sourceLocale]
        collect(source?.forms[.other])
        for category in PluralCategory.allCases { collect(source?.forms[category]) }
        for locale in translations.keys.sorted() where locale != sourceLocale {
            for category in PluralCategory.allCases { collect(translations[locale]?.forms[category]) }
        }
        return result
    }
}
