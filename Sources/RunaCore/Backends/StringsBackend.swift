import Foundation

public enum BackendKind: String, Codable, Sendable, CaseIterable {
    case googleSheets = "google-sheets"
    case localJSON = "local-json"

    public var displayName: String {
        switch self {
        case .googleSheets: "Google Sheets"
        case .localJSON: "Local file"
        }
    }
}

/// Where a project's strings live. Every provider passes the same contract tests.
public protocol StringsBackend: Sendable {
    var kind: BackendKind { get }

    /// The whole project. Datasets are small (thousands of keys), so there is no paging.
    func pull() async throws -> Snapshot

    /// Applies changes that were made on top of `base`. Conflicting changes are returned, not applied.
    func push(_ changes: [Change], basedOn base: Snapshot, context: PushContext) async throws -> PushResult

    func addLocale(_ locale: LocaleCode, context: PushContext) async throws -> Snapshot

    /// Removes a locale and all its translations. The source locale cannot be removed.
    func removeLocale(_ locale: LocaleCode, context: PushContext) async throws -> Snapshot

    /// History, newest first. `keyID` narrows it to one key.
    func history(keyID: UUID?, limit: Int) async throws -> [HistoryEntry]
}

public enum BackendError: Error, LocalizedError, Sendable, Equatable {
    case notFound(String)
    case accessDenied(String)
    case authenticationFailed(String)
    case invalidData(String)
    case cannotRemoveSourceLocale
    case localeExists(LocaleCode)
    case localeMissing(LocaleCode)
    case rateLimited
    case server(Int, String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let message): message
        case .accessDenied(let message): message
        case .authenticationFailed(let message): "Sign-in failed: \(message)"
        case .invalidData(let message): message
        case .cannotRemoveSourceLocale: "The source language cannot be removed."
        case .localeExists(let locale): "\(locale.displayName()) is already in the project."
        case .localeMissing(let locale): "\(locale.displayName()) is not in the project."
        case .rateLimited: "Google is rate limiting requests. Wait a minute and try again."
        case .server(let status, let message): "The server returned \(status): \(message)"
        case .network(let message): "Network error: \(message)"
        }
    }
}
