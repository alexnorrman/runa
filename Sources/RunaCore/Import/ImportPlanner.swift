import Foundation

public enum ImportItemKind: String, Sendable, Hashable, CaseIterable {
    /// The key does not exist in the backend yet.
    case newKey
    /// The key exists but has no value in this locale.
    case newTranslation
    /// The file and the backend agree.
    case same
    /// The file and the backend have different text.
    case conflict
    /// Different placeholders or plural shape. Needs a person; never applied automatically.
    case mismatch
}

public enum ImportResolution: Sendable, Hashable {
    case useFile
    case keepBackend
    /// Hand-merged text, canonical syntax, per plural form.
    case custom([PluralCategory: String])
}

public struct ImportItem: Identifiable, Sendable, Hashable {
    public var id = UUID()
    public var kind: ImportItemKind
    /// Key name as it will be stored (canonical).
    public var keyName: String
    /// Key name as written in the file.
    public var fileKey: String
    public var existingKeyID: UUID?
    public var locale: LocaleCode
    public var isPlural: Bool
    /// Imported text in canonical syntax.
    public var imported: [PluralCategory: String]
    /// Current backend text, if any.
    public var current: [PluralCategory: String]?
    public var comment: String?
    public var translatable: Bool
    public var status: TranslationStatus?
    public var file: String
    /// Why a mismatch cannot be applied automatically.
    public var reason: String?
    public var resolution: ImportResolution
}

public struct ImportPlan: Sendable {
    public var items: [ImportItem]
    /// Locales in the files that the project does not have yet.
    public var newLocales: [LocaleCode]
    public var warnings: [String]

    public func items(_ kind: ImportItemKind) -> [ImportItem] { items.filter { $0.kind == kind } }

    public var summary: [ImportItemKind: Int] {
        Dictionary(grouping: items, by: \.kind).mapValues(\.count)
    }

    /// Sets the resolution of every conflict, optionally only for one locale.
    public mutating func resolveConflicts(_ resolution: ImportResolution, locale: LocaleCode? = nil) {
        for index in items.indices where items[index].kind == .conflict && (locale == nil || items[index].locale == locale) {
            items[index].resolution = resolution
        }
    }

    /// The changes to push. Items for locales that are not in `projectLocales` are left out, so add
    /// those locales first.
    public func changes(projectLocales: [LocaleCode]) -> [Change] {
        var changes: [Change] = []
        var newKeys: [String: StringKey] = [:]
        var newKeyOrder: [String] = []
        for item in items where projectLocales.contains(item.locale) {
            let forms: [PluralCategory: String]
            switch (item.kind, item.resolution) {
            case (.same, _), (.mismatch, .useFile), (_, .keepBackend): continue
            case (_, .custom(let custom)): forms = custom
            case (_, .useFile): forms = item.imported
            }
            if item.kind == .newKey {
                var key = newKeys[item.keyName] ?? StringKey(
                    id: TextHash.uuid(forKey: item.keyName), key: item.keyName, description: item.comment ?? "",
                    tags: item.translatable ? [] : [StringKey.doNotTranslateTag], isPlural: item.isPlural)
                if key.description.isEmpty, let comment = item.comment { key.description = comment }
                key.isPlural = key.isPlural || item.isPlural
                key.translations[item.locale] = Translation(forms: forms, status: item.status ?? .approved)
                if newKeys[item.keyName] == nil { newKeyOrder.append(item.keyName) }
                newKeys[item.keyName] = key
                continue
            }
            guard let id = item.existingKeyID else { continue }
            let status = item.status ?? .approved
            for category in PluralCategory.allCases {
                let newValue = forms[category]
                let oldValue = item.current?[category]
                if newValue != oldValue, newValue != nil || oldValue != nil {
                    changes.append(.setValue(id: id, locale: item.locale, category: category, value: newValue, status: status))
                }
            }
        }
        return newKeyOrder.compactMap { newKeys[$0] }.map(Change.addKey) + changes
    }
}

/// Compares imported entries with the current project and sorts each value into a bucket.
public enum ImportPlanner {
    public static func plan(_ entries: [ImportedEntry], against snapshot: Snapshot) -> ImportPlan {
        let source = snapshot.settings.sourceLocale
        var warnings: [String] = []

        // Match file keys to existing keys: exact name first, then the Android form of the name.
        var byName: [String: StringKey] = [:]
        var byAndroidName: [String: StringKey] = [:]
        for key in snapshot.keys {
            byName[key.key] = key
            byAndroidName[KeyNaming.androidName(key.key)] = byAndroidName[KeyNaming.androidName(key.key)] ?? key
        }
        func existing(for entry: ImportedEntry) -> StringKey? {
            if let key = byName[entry.key] { return key }
            if entry.flavor == .android { return byAndroidName[entry.key] }
            return nil
        }

        // Placeholder names come from the existing key, or from the source-locale entry in the same import.
        var sourceNames: [String: [Placeholder]] = [:]
        for entry in entries where entry.locale == source && existing(for: entry) == nil {
            let canonical = toCanonical(entry, names: [])
            let combined = PluralCategory.allCases.compactMap { canonical[$0] }.joined(separator: " ")
            sourceNames[entry.key] = CanonicalText.placeholders(in: combined)
        }

        var items: [ImportItem] = []
        var newLocales: [LocaleCode] = []
        var seen = Set<String>()
        for entry in entries {
            let identity = "\(entry.key)\u{1F}\(entry.locale)"
            if !seen.insert(identity).inserted {
                warnings.append("\(entry.file): \(entry.key) [\(entry.locale)] appears more than once; the first one was used")
                continue
            }
            if !snapshot.settings.locales.contains(entry.locale), !newLocales.contains(entry.locale) {
                newLocales.append(entry.locale)
            }
            let key = existing(for: entry)
            let names = key?.placeholders(sourceLocale: source) ?? sourceNames[entry.key] ?? []
            let imported = toCanonical(entry, names: names)
            guard !imported.isEmpty else { continue }
            var item = ImportItem(
                kind: .newKey, keyName: key?.key ?? entry.key, fileKey: entry.key, existingKeyID: key?.id, locale: entry.locale,
                isPlural: entry.isPlural, imported: imported, current: nil, comment: entry.comment, translatable: entry.translatable,
                status: entry.status, file: entry.file, reason: nil, resolution: .useFile)
            guard let key else {
                items.append(item)
                continue
            }
            let current = key.translations[entry.locale]?.nonEmptyForms
            item.current = current
            if let current, !current.isEmpty {
                if key.isPlural != entry.isPlural {
                    item.kind = .mismatch
                    item.reason = key.isPlural ? "The backend has plural forms; the file has a single value" : "The file has plural forms; the backend has a single value"
                    item.resolution = .keepBackend
                } else if normalized(current, plural: key.isPlural) == normalized(imported, plural: key.isPlural) {
                    item.kind = .same
                    item.resolution = .keepBackend
                } else if placeholderSignature(current) != placeholderSignature(imported) {
                    item.kind = .mismatch
                    item.reason = "Placeholders differ: backend has \(describe(current)), file has \(describe(imported))"
                    item.resolution = .keepBackend
                } else {
                    item.kind = .conflict
                    item.resolution = .keepBackend
                }
            } else {
                if key.isPlural != entry.isPlural {
                    item.kind = .mismatch
                    item.reason = key.isPlural ? "The key is plural; the file has a single value" : "The file has plural forms; the key is not plural"
                    item.resolution = .keepBackend
                } else {
                    item.kind = .newTranslation
                }
            }
            items.append(item)
        }
        return ImportPlan(items: items, newLocales: newLocales, warnings: warnings)
    }

    static func toCanonical(_ entry: ImportedEntry, names: [Placeholder]) -> [PluralCategory: String] {
        var forms: [PluralCategory: String] = [:]
        for (category, text) in entry.forms where !text.isEmpty {
            forms[category] = PlaceholderConverter.parse(text, flavor: entry.flavor, names: names)
        }
        return forms
    }

    static func normalized(_ forms: [PluralCategory: String], plural: Bool) -> [PluralCategory: String] {
        plural ? forms.filter { !$0.value.isEmpty } : forms.filter { $0.key == .other }
    }

    static func placeholderSignature(_ forms: [PluralCategory: String]) -> Set<String> {
        Set(forms.values.flatMap { CanonicalText.placeholders(in: $0).map(\.canonical) })
    }

    static func describe(_ forms: [PluralCategory: String]) -> String {
        let signature = placeholderSignature(forms).sorted()
        return signature.isEmpty ? "none" : signature.joined(separator: ", ")
    }
}
