import Foundation

/// One intended edit. Pushes are lists of intents rather than whole tables, which is what makes
/// cell-level conflict detection and history possible.
public enum Change: Hashable, Codable, Sendable {
    case addKey(StringKey)
    case updateKey(id: UUID, metadata: KeyMetadata)
    case deleteKey(id: UUID)
    /// Sets one plural form (or `.other` for plain keys). `nil` clears it.
    case setValue(id: UUID, locale: LocaleCode, category: PluralCategory, value: String?, status: TranslationStatus)
    /// Changes the status without changing the value, for example approving a machine draft.
    case setStatus(id: UUID, locale: LocaleCode, status: TranslationStatus)
    case setContexts(id: UUID, contexts: [FigmaContext])

    public var keyID: UUID {
        switch self {
        case .addKey(let key): key.id
        case .updateKey(let id, _), .deleteKey(let id), .setContexts(let id, _): id
        case .setValue(let id, _, _, _, _), .setStatus(let id, _, _): id
        }
    }

    public static func setValue(id: UUID, locale: LocaleCode, value: String?, status: TranslationStatus = .approved) -> Change {
        .setValue(id: id, locale: locale, category: .other, value: value, status: status)
    }
}

public enum ConflictKind: String, Codable, Sendable, Hashable {
    /// Someone else changed the same cell since you last pulled.
    case valueChanged
    /// Someone else changed the key's name, description, tags, platforms or plural flag.
    case metadataChanged
    /// Someone else changed the key's Figma links.
    case contextsChanged
    /// The key was deleted remotely.
    case keyDeleted
    /// A different key with the same name already exists.
    case duplicateKey
    /// You deleted a key that someone else edited since you last pulled.
    case keyModified
}

public struct Conflict: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var kind: ConflictKind
    public var change: Change
    public var keyName: String
    public var locale: LocaleCode?
    public var category: PluralCategory?
    /// Value when you last pulled.
    public var base: String?
    /// Value in the backend now.
    public var remote: String?
    /// Value you tried to write.
    public var local: String?

    public init(kind: ConflictKind, change: Change, keyName: String, locale: LocaleCode? = nil, category: PluralCategory? = nil,
                base: String? = nil, remote: String? = nil, local: String? = nil)
    {
        self.kind = kind
        self.change = change
        self.keyName = keyName
        self.locale = locale
        self.category = category
        self.base = base
        self.remote = remote
        self.local = local
    }
}

public struct PushContext: Sendable, Hashable {
    /// Display name of the person (or tool) pushing.
    public var actor: String
    /// Where the change came from, recorded in history: "import values-sv/strings.xml", "ai claude-opus-5-5", "figma".
    public var note: String?
    public var date: Date

    public init(actor: String, note: String? = nil, date: Date = Date()) {
        self.actor = actor
        self.note = note
        self.date = date
    }
}

public struct PushResult: Sendable {
    /// The project after the push.
    public var snapshot: Snapshot
    public var applied: [Change]
    public var conflicts: [Conflict]

    public init(snapshot: Snapshot, applied: [Change], conflicts: [Conflict]) {
        self.snapshot = snapshot
        self.applied = applied
        self.conflicts = conflicts
    }
}
