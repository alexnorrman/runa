import Foundation

/// Applies changes to a snapshot with per-cell conflict detection. Every backend uses this, so
/// conflict and status rules are identical whether strings live in a sheet or a file.
public enum ChangeApplier {
    public struct Outcome: Sendable {
        public var snapshot: Snapshot
        public var applied: [Change]
        public var conflicts: [Conflict]
        public var history: [HistoryEntry]
        /// Keys that were added, edited or deleted. Backends only rewrite these.
        public var touchedKeyIDs: Set<UUID>
    }

    /// - Parameters:
    ///   - current: The backend's state right now.
    ///   - base: The state the client last pulled. A change conflicts when the backend moved away
    ///     from `base` in the same cell and does not already hold the new value.
    public static func apply(_ changes: [Change], to current: Snapshot, base: Snapshot, context: PushContext) -> Outcome {
        var snapshot = current
        var applied: [Change] = []
        var conflicts: [Conflict] = []
        var history: [HistoryEntry] = []
        var touched = Set<UUID>()
        let source = snapshot.settings.sourceLocale

        func entry(_ action: HistoryAction, _ key: StringKey?, locale: LocaleCode? = nil, category: PluralCategory? = nil,
                   before: String? = nil, after: String? = nil) -> HistoryEntry
        {
            HistoryEntry(date: context.date, actor: context.actor, action: action, keyID: key?.id, key: key?.key, locale: locale,
                         category: category, before: before, after: after, note: context.note)
        }

        /// Before the first edit to a key, record which source text its existing translations
        /// belong to, so a source edit in this push marks them for review instead of approving them.
        func baseline(_ index: Int) {
            let id = snapshot.keys[index].id
            guard !touched.contains(id) else { return }
            touched.insert(id)
            let hash = snapshot.sourceHash(of: snapshot.keys[index])
            for locale in snapshot.keys[index].translations.keys where locale != source {
                if snapshot.keys[index].translations[locale]?.sourceHash == nil {
                    snapshot.keys[index].translations[locale]?.sourceHash = hash
                }
            }
        }

        for change in changes {
            switch change {
            case .addKey(var key):
                if let existing = snapshot[id: key.id] {
                    if existing.key != key.key {
                        conflicts.append(Conflict(kind: .duplicateKey, change: change, keyName: key.key, remote: existing.key, local: key.key))
                    }
                    continue
                }
                if snapshot.key(named: key.key) != nil {
                    conflicts.append(Conflict(kind: .duplicateKey, change: change, keyName: key.key))
                    continue
                }
                key.translations = key.translations.filter { snapshot.settings.locales.contains($0.key) && !$0.value.isEmpty }
                let sourceHash = key.translations[source].map(\.hash)
                for locale in key.translations.keys {
                    key.translations[locale]?.updatedAt = context.date
                    key.translations[locale]?.updatedBy = context.actor
                    if locale == source {
                        key.translations[locale]?.status = .approved
                        key.translations[locale]?.sourceHash = nil
                    } else {
                        key.translations[locale]?.sourceHash = sourceHash
                    }
                }
                snapshot.keys.append(key)
                touched.insert(key.id)
                applied.append(change)
                history.append(entry(.addKey, key, locale: source, after: key.translations[source]?.value ?? key.translations[source].map(describe)))

            case .updateKey(let id, let metadata):
                guard let index = snapshot.index(of: id) else {
                    conflicts.append(Conflict(kind: .keyDeleted, change: change, keyName: metadata.key))
                    continue
                }
                let remote = snapshot.keys[index].metadata
                if remote == metadata {
                    applied.append(change)
                    continue
                }
                if let baseKey = base[id: id], baseKey.metadata != remote {
                    conflicts.append(Conflict(kind: .metadataChanged, change: change, keyName: remote.key,
                                              base: describe(baseKey.metadata), remote: describe(remote), local: describe(metadata)))
                    continue
                }
                if metadata.key != remote.key, snapshot.key(named: metadata.key) != nil {
                    conflicts.append(Conflict(kind: .duplicateKey, change: change, keyName: metadata.key))
                    continue
                }
                baseline(index)
                snapshot.keys[index].metadata = metadata
                applied.append(change)
                history.append(entry(.updateKey, snapshot.keys[index], before: describe(remote), after: describe(metadata)))

            case .deleteKey(let id):
                guard let index = snapshot.index(of: id) else { continue }
                let remote = snapshot.keys[index]
                if let baseKey = base[id: id], !sameContent(baseKey, remote) {
                    conflicts.append(Conflict(kind: .keyModified, change: change, keyName: remote.key))
                    continue
                }
                snapshot.keys.remove(at: index)
                touched.insert(id)
                applied.append(change)
                history.append(entry(.deleteKey, remote, locale: source, before: remote.translations[source].map(describe)))

            case .setValue(let id, let locale, let category, let rawValue, let status):
                guard let index = snapshot.index(of: id) else {
                    conflicts.append(Conflict(kind: .keyDeleted, change: change, keyName: base[id: id]?.key ?? id.lowercased, locale: locale,
                                              category: category))
                    continue
                }
                guard snapshot.settings.locales.contains(locale) else {
                    conflicts.append(Conflict(kind: .unknownLocale, change: change, keyName: snapshot.keys[index].key, locale: locale))
                    continue
                }
                let value = rawValue?.isEmpty == true ? nil : rawValue
                let remote = snapshot.keys[index].value(for: locale, category)
                if let baseKey = base[id: id] {
                    let baseValue = baseKey.value(for: locale, category)
                    if remote != baseValue, remote != value {
                        conflicts.append(Conflict(kind: .valueChanged, change: change, keyName: snapshot.keys[index].key, locale: locale,
                                                  category: category, base: baseValue, remote: remote, local: value))
                        continue
                    }
                }
                let existingStatus = snapshot.keys[index].translations[locale]?.status
                let effectiveStatus = locale == source ? TranslationStatus.approved : status
                if remote == value, existingStatus == effectiveStatus || value == nil {
                    applied.append(change)
                    continue
                }
                baseline(index)
                var translation = snapshot.keys[index].translations[locale] ?? Translation(forms: [:])
                translation.forms[category] = value
                translation.forms = translation.nonEmptyForms
                if translation.forms.isEmpty {
                    snapshot.keys[index].translations[locale] = nil
                } else {
                    translation.status = effectiveStatus
                    translation.updatedAt = context.date
                    translation.updatedBy = context.actor
                    snapshot.keys[index].translations[locale] = translation
                    if locale != source {
                        let hash = snapshot.sourceHash(of: snapshot.keys[index])
                        snapshot.keys[index].translations[locale]?.sourceHash = hash
                    }
                }
                applied.append(change)
                history.append(entry(.setValue, snapshot.keys[index], locale: locale, category: snapshot.keys[index].isPlural ? category : nil,
                                     before: remote, after: value))

            case .setStatus(let id, let locale, let status):
                guard let index = snapshot.index(of: id) else {
                    conflicts.append(Conflict(kind: .keyDeleted, change: change, keyName: base[id: id]?.key ?? id.lowercased, locale: locale))
                    continue
                }
                guard locale != source, snapshot.keys[index].translations[locale] != nil else {
                    applied.append(change)
                    continue
                }
                baseline(index)
                let before = snapshot.status(of: snapshot.keys[index], locale: locale)
                let hash = snapshot.sourceHash(of: snapshot.keys[index])
                snapshot.keys[index].translations[locale]?.status = status
                snapshot.keys[index].translations[locale]?.sourceHash = hash
                snapshot.keys[index].translations[locale]?.updatedAt = context.date
                snapshot.keys[index].translations[locale]?.updatedBy = context.actor
                applied.append(change)
                if before != status {
                    history.append(entry(.setStatus, snapshot.keys[index], locale: locale, before: before.rawValue, after: status.rawValue))
                }

            case .setContexts(let id, let contexts):
                guard let index = snapshot.index(of: id) else {
                    conflicts.append(Conflict(kind: .keyDeleted, change: change, keyName: base[id: id]?.key ?? id.lowercased))
                    continue
                }
                let remote = snapshot.keys[index].contexts
                if remote.map(\.url) == contexts.map(\.url) && remote == contexts {
                    applied.append(change)
                    continue
                }
                if let baseKey = base[id: id], Set(baseKey.contexts.map(\.url)) != Set(remote.map(\.url)),
                    Set(remote.map(\.url)) != Set(contexts.map(\.url))
                {
                    conflicts.append(Conflict(kind: .contextsChanged, change: change, keyName: snapshot.keys[index].key,
                                              base: baseKey.contexts.map(\.url).joined(separator: "\n"),
                                              remote: remote.map(\.url).joined(separator: "\n"),
                                              local: contexts.map(\.url).joined(separator: "\n")))
                    continue
                }
                baseline(index)
                snapshot.keys[index].contexts = contexts
                applied.append(change)
                history.append(entry(.linkFigma, snapshot.keys[index], before: remote.map(\.url).joined(separator: "\n"),
                                     after: contexts.map(\.url).joined(separator: "\n")))
            }
        }
        return Outcome(snapshot: snapshot, applied: applied, conflicts: conflicts, history: history, touchedKeyIDs: touched)
    }

    static func sameContent(_ a: StringKey, _ b: StringKey) -> Bool {
        a.metadata == b.metadata && a.translations.mapValues(\.nonEmptyForms) == b.translations.mapValues(\.nonEmptyForms)
    }

    static func describe(_ metadata: KeyMetadata) -> String {
        var parts = ["key: \(metadata.key)"]
        if !metadata.description.isEmpty { parts.append("description: \(metadata.description)") }
        if !metadata.tags.isEmpty { parts.append("tags: \(metadata.tags.joined(separator: ", "))") }
        if !metadata.platforms.isEmpty { parts.append("platforms: \(metadata.platforms.map(\.rawValue).joined(separator: ", "))") }
        if metadata.isPlural { parts.append("plural") }
        return parts.joined(separator: "; ")
    }

    static func describe(_ translation: Translation) -> String {
        if translation.forms.keys.count == 1, let other = translation.forms[.other] { return other }
        return PluralCategory.allCases.compactMap { category in translation.forms[category].map { "\(category.rawValue): \($0)" } }
            .joined(separator: "\n")
    }
}
