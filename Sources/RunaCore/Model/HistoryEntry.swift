import Foundation

public enum HistoryAction: String, Codable, Sendable, Hashable, CaseIterable {
    case addKey = "add-key"
    case updateKey = "update-key"
    case deleteKey = "delete-key"
    case setValue = "set-value"
    case setStatus = "set-status"
    case linkFigma = "link-figma"
    case addLocale = "add-locale"
    case removeLocale = "remove-locale"
}

/// One row of history. Values are stored as text so every backend can keep them the same way.
public struct HistoryEntry: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var date: Date
    public var actor: String
    public var action: HistoryAction
    public var keyID: UUID?
    public var key: String?
    public var locale: LocaleCode?
    public var category: PluralCategory?
    public var before: String?
    public var after: String?
    public var note: String?

    public init(date: Date, actor: String, action: HistoryAction, keyID: UUID? = nil, key: String? = nil, locale: LocaleCode? = nil,
                category: PluralCategory? = nil, before: String? = nil, after: String? = nil, note: String? = nil)
    {
        self.date = date
        self.actor = actor
        self.action = action
        self.keyID = keyID
        self.key = key
        self.locale = locale
        self.category = category
        self.before = before
        self.after = after
        self.note = note
    }
}
