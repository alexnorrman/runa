import Foundation

/// Project-wide guidance that every client and agent shares: how keys are named, and the glossary and
/// style guides that steer translation. Stored in the backend, so each project has its own.
public struct ProjectGuidelines: Hashable, Codable, Sendable {
    /// Markdown for people and agents: the naming convention and anything else worth knowing.
    public var naming: String
    /// Shape of a key name, for example `{platform?}_{feature}_{description}_{type:title|text|action}`.
    /// Empty: no rule. See `KeyTemplate` for the syntax.
    public var keyTemplate: String
    /// A regular expression every key name must match in full. Overrides the template's derived pattern
    /// for validation. Empty: use the template, if any.
    public var keyPattern: String
    public var glossary: [GlossaryTerm]
    public var styleGuides: [LocaleCode: String]

    public init(naming: String = "", keyTemplate: String = "", keyPattern: String = "", glossary: [GlossaryTerm] = [],
                styleGuides: [LocaleCode: String] = [:])
    {
        self.naming = naming
        self.keyTemplate = keyTemplate
        self.keyPattern = keyPattern
        self.glossary = glossary
        self.styleGuides = styleGuides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        naming = try container.decodeIfPresent(String.self, forKey: .naming) ?? ""
        keyTemplate = try container.decodeIfPresent(String.self, forKey: .keyTemplate) ?? ""
        keyPattern = try container.decodeIfPresent(String.self, forKey: .keyPattern) ?? ""
        glossary = try container.decodeIfPresent([GlossaryTerm].self, forKey: .glossary) ?? []
        styleGuides = try container.decodeIfPresent([LocaleCode: String].self, forKey: .styleGuides) ?? [:]
    }

    public var isEmpty: Bool {
        naming.isEmpty && keyTemplate.isEmpty && keyPattern.isEmpty && glossary.isEmpty && styleGuides.values.allSatisfy(\.isEmpty)
    }

    /// The same guidelines with whitespace trimmed, empty glossary terms and style guides dropped.
    public var normalized: ProjectGuidelines {
        var copy = self
        copy.naming = naming.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.keyTemplate = keyTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.keyPattern = keyPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.glossary = glossary.compactMap { term in
            var term = term
            term.term = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
            term.note = term.note.trimmingCharacters(in: .whitespacesAndNewlines)
            term.translations = term.translations.compactMapValues {
                let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            return term.term.isEmpty ? nil : term
        }
        copy.styleGuides = styleGuides.compactMapValues {
            let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return copy
    }
}

// MARK: Merge

extension ProjectGuidelines {
    /// One field that differs between two versions, for conflicts and history.
    public struct FieldChange: Hashable, Sendable {
        /// `naming`, `keyTemplate`, `keyPattern`, `style` or `glossary`.
        public var topic: String
        public var locale: LocaleCode?
        public var before: String?
        public var after: String?

        public var label: String { locale.map { "\(topic) \($0.rawValue)" } ?? topic }
    }

    enum Field: Hashable {
        case naming, keyTemplate, keyPattern, glossary
        case style(LocaleCode)
    }

    func value(_ field: Field) -> String {
        switch field {
        case .naming: naming
        case .keyTemplate: keyTemplate
        case .keyPattern: keyPattern
        case .style(let locale): styleGuides[locale] ?? ""
        case .glossary: Self.glossaryFingerprint(glossary)
        }
    }

    mutating func copy(_ field: Field, from other: ProjectGuidelines) {
        switch field {
        case .naming: naming = other.naming
        case .keyTemplate: keyTemplate = other.keyTemplate
        case .keyPattern: keyPattern = other.keyPattern
        case .style(let locale): styleGuides[locale] = other.styleGuides[locale]
        case .glossary: glossary = other.glossary
        }
    }

    static func fields(in versions: ProjectGuidelines...) -> [Field] {
        let locales = Set(versions.flatMap(\.styleGuides.keys)).sorted { $0.rawValue < $1.rawValue }
        return [.naming, .keyTemplate, .keyPattern] + locales.map(Field.style) + [.glossary]
    }

    /// Glossary content without ids, so terms read back from a sheet compare equal to the same terms typed in the app.
    static func glossaryFingerprint(_ terms: [GlossaryTerm]) -> String {
        terms.map { term in
            let translations = term.translations.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
            return ([term.term, term.note] + translations).joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
    }

    /// Fields that differ from `old`, in a fixed order.
    public func changes(from old: ProjectGuidelines) -> [FieldChange] {
        Self.fields(in: self, old).compactMap { field in
            let before = old.value(field), after = value(field)
            guard before != after else { return nil }
            switch field {
            case .glossary:
                return FieldChange(topic: "glossary", locale: nil, before: Self.glossarySummary(old.glossary),
                                   after: Self.glossarySummary(glossary))
            case .style(let locale):
                return FieldChange(topic: "style", locale: locale, before: before.isEmpty ? nil : before, after: after.isEmpty ? nil : after)
            default:
                return FieldChange(topic: Self.topic(field), locale: nil, before: before.isEmpty ? nil : before, after: after.isEmpty ? nil : after)
            }
        }
    }

    static func topic(_ field: Field) -> String {
        switch field {
        case .naming: "naming"
        case .keyTemplate: "keyTemplate"
        case .keyPattern: "keyPattern"
        case .style: "style"
        case .glossary: "glossary"
        }
    }

    static func glossarySummary(_ terms: [GlossaryTerm]) -> String? {
        terms.isEmpty ? nil : terms.count == 1 ? "1 term" : "\(terms.count) terms"
    }

    /// Three-way merge: fields you changed since `base` replace `theirs`, everything else stays as they have it.
    /// A field that both you and someone else changed, to different values, is a conflict.
    public static func merge(mine: ProjectGuidelines, base: ProjectGuidelines, theirs: ProjectGuidelines) throws -> ProjectGuidelines {
        var merged = theirs
        var conflicts: [String] = []
        for field in fields(in: mine, base, theirs) {
            let mineValue = mine.value(field), baseValue = base.value(field), theirValue = theirs.value(field)
            guard mineValue != baseValue else { continue }
            if theirValue != baseValue, theirValue != mineValue {
                conflicts.append(field == .glossary ? "the glossary" : {
                    if case .style(let locale) = field { return "the \(locale.displayName()) style guide" }
                    return topic(field) == "naming" ? "the naming guide" : topic(field) == "keyTemplate" ? "the key template" : "the key pattern"
                }())
                continue
            }
            merged.copy(field, from: mine)
        }
        guard conflicts.isEmpty else {
            throw BackendError.conflict("Someone else changed \(conflicts.joined(separator: ", ")) since you opened it. "
                + "Close and reopen the settings to see their version, then make your change again.")
        }
        return merged
    }

    /// History rows for going from `old` to `self`.
    public func historyEntries(from old: ProjectGuidelines, context: PushContext) -> [HistoryEntry] {
        changes(from: old).map { change in
            HistoryEntry(date: context.date, actor: context.actor, action: .updateGuidelines, key: change.topic, locale: change.locale,
                         before: change.before, after: change.after, note: context.note)
        }
    }
}
