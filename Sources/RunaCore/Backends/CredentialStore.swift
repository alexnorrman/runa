import Foundation

/// Finds a Google service account key for the CLI and MCP server.
///
/// Order: an explicit path, the config's `credentials`, `$RUNA_GOOGLE_CREDENTIALS` (a path or the
/// JSON itself), then `~/.config/runa/google-service-account.json`, which the Mac app writes when you
/// press Use for CLI in Settings → Command Line. Installing the command line tool does not write it.
public enum CredentialStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/runa/google-service-account.json")
    }

    public static func load(explicitPath: String? = nil, configPath: String? = nil, relativeTo root: URL? = nil,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ServiceAccountCredentials
    {
        func read(_ path: String) throws -> ServiceAccountCredentials {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: root)
            guard let data = try? Data(contentsOf: url) else {
                throw BackendError.notFound("No service account key at \(url.path)")
            }
            return try ServiceAccountCredentials(json: data)
        }
        if let explicitPath { return try read(explicitPath) }
        if let configPath { return try read(configPath) }
        if let value = environment["RUNA_GOOGLE_CREDENTIALS"], !value.isEmpty {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") { return try ServiceAccountCredentials(json: Data(trimmed.utf8)) }
            return try read(trimmed)
        }
        if FileManager.default.fileExists(atPath: defaultURL.path) { return try read(defaultURL.path) }
        throw BackendError.authenticationFailed(
            "No Google credentials. In the Runa app, open Settings → Command Line and press Use for CLI next to the service account. "
                + "Or set RUNA_GOOGLE_CREDENTIALS, or add `credentials:` to runa.yml.")
    }

    /// Saves a key where the CLI looks by default, readable only by the current user.
    public static func saveDefault(_ credentials: ServiceAccountCredentials) throws {
        let url = defaultURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try credentials.jsonData().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Creates the backend a config describes.
    public static func backend(for config: RunaConfig, root: URL, credentialsPath: String? = nil) throws -> any StringsBackend {
        switch config.backend.type {
        case .localJSON:
            guard let path = config.backend.path else { throw BackendError.invalidData("runa.yml: backend.path is required for local-json") }
            return LocalJSONBackend(url: URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL)
        case .googleSheets:
            guard let link = config.backend.spreadsheet, let id = GoogleSheetsBackend.spreadsheetID(from: link) else {
                throw BackendError.invalidData("runa.yml: backend.spreadsheet must be a Google Sheets link or id")
            }
            let credentials = try load(explicitPath: credentialsPath, configPath: config.backend.credentials, relativeTo: root)
            return GoogleSheetsBackend(spreadsheetID: id, api: GoogleSheetsAPI(credentials: credentials))
        }
    }
}
