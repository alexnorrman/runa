import Foundation

/// The `runa.yml` file a repository commits. It says where strings live and which platform files to write.
public struct RunaConfig: Codable, Sendable, Hashable {
    public struct Backend: Codable, Sendable, Hashable {
        public var type: BackendKind
        /// Google Sheets: link or id.
        public var spreadsheet: String?
        /// Google Sheets: path to a service account key. `~` is expanded. Never commit the key itself.
        public var credentials: String?
        /// Local JSON: path to the `.runa.json` file, relative to the config file.
        public var path: String?

        public init(type: BackendKind, spreadsheet: String? = nil, credentials: String? = nil, path: String? = nil) {
            self.type = type
            self.spreadsheet = spreadsheet
            self.credentials = credentials
            self.path = path
        }
    }

    public struct Target: Codable, Sendable, Hashable {
        public var format: FormatKind
        /// Relative to the config file. A file for `xcstrings`, a directory for everything else
        /// (`res/` for Android, the folder holding `*.lproj` for Apple strings, the locales folder for web).
        public var path: String
        /// i18next: nest keys on dots.
        public var nested: Bool?
        /// i18next/ICU: file pattern inside `path`, `{locale}` is replaced. Default `{locale}.json`.
        public var file: String?
        /// Apple strings: table name. Default `Localizable`.
        public var table: String?
        /// Write only approved translations to this target.
        public var approvedOnly: Bool?

        public init(format: FormatKind, path: String, nested: Bool? = nil, file: String? = nil, table: String? = nil, approvedOnly: Bool? = nil) {
            self.format = format
            self.path = path
            self.nested = nested
            self.file = file
            self.table = table
            self.approvedOnly = approvedOnly
        }
    }

    public var backend: Backend
    public var targets: [Target]
    /// Write only approved translations to every target.
    public var approvedOnly: Bool?
    /// Name recorded in history for writes from the CLI and MCP server.
    public var actor: String?

    public init(backend: Backend, targets: [Target] = [], approvedOnly: Bool? = nil, actor: String? = nil) {
        self.backend = backend
        self.targets = targets
        self.approvedOnly = approvedOnly
        self.actor = actor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decode(Backend.self, forKey: .backend)
        // `targets:` with every entry commented out, as `runa init` writes it, reads as null: no targets yet.
        targets = try container.decodeIfPresent([Target].self, forKey: .targets) ?? []
        approvedOnly = try container.decodeIfPresent(Bool.self, forKey: .approvedOnly)
        actor = try container.decodeIfPresent(String.self, forKey: .actor)
    }

    public static let fileName = "runa.yml"

    /// Finds `runa.yml` in `directory` or the nearest parent, like git finds `.git`.
    public static func locate(from directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        while true {
            let candidate = current.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    public func exportOptions(for target: Target) -> ExportOptions {
        ExportOptions(includeUnapproved: !((target.approvedOnly ?? approvedOnly) ?? false), nested: target.nested ?? false,
                      filePattern: target.file, tableName: target.table ?? "Localizable")
    }

    /// A commented starter file.
    public static func template(spreadsheet: String?, localPath: String?) -> String {
        let backend: String
        if let localPath {
            backend = """
            backend:
              type: local-json
              path: \(localPath)
            """
        } else {
            backend = """
            backend:
              type: google-sheets
              spreadsheet: \(spreadsheet ?? "https://docs.google.com/spreadsheets/d/YOUR_SHEET_ID/edit")
              # Service account key. Defaults to $RUNA_GOOGLE_CREDENTIALS, then ~/.config/runa/google-service-account.json.
              # Never commit the key file.
              # credentials: ~/.config/runa/google-service-account.json
            """
        }
        return """
        # Runa configuration. `runa pull` writes the targets below; commit the results as usual.
        \(backend)

        # Uncomment the platforms this repository ships.
        targets:
          # - format: xcstrings          # iOS/macOS String Catalog
          #   path: App/Localizable.xcstrings
          # - format: apple-strings      # Legacy .strings + .stringsdict, path is the folder holding *.lproj
          #   path: App/Resources
          # - format: android            # path is the res/ folder
          #   path: app/src/main/res
          # - format: i18next            # path is the locales folder
          #   path: public/locales
          #   file: "{locale}/translation.json"
          #   nested: true
          # - format: icu
          #   path: src/messages

        # Leave out machine drafts and translations that need review.
        approvedOnly: false

        """
    }
}

/// Writes export results to disk, skipping files whose contents did not change.
public enum Exporter {
    public struct Report: Sendable {
        public var written: [String] = []
        public var unchanged: [String] = []
        public var warnings: [String] = []
    }

    public static func export(_ snapshot: Snapshot, target: RunaConfig.Target, options: ExportOptions) -> ExportResult {
        switch target.format {
        case .xcstrings:
            let fileName = URL(fileURLWithPath: target.path).lastPathComponent
            return XCStringsFormat.export(snapshot, options: options, fileName: fileName)
        case .appleStrings: return AppleStringsFormat.export(snapshot, options: options)
        case .android: return AndroidXMLFormat.export(snapshot, options: options)
        case .i18next: return I18nextFormat.export(snapshot, options: options)
        case .icu: return ICUJSONFormat.export(snapshot, options: options)
        }
    }

    /// The directory files are written into for a target.
    public static func baseDirectory(for target: RunaConfig.Target, root: URL) -> URL {
        let url = URL(fileURLWithPath: target.path, relativeTo: root).standardizedFileURL
        return target.format == .xcstrings ? url.deletingLastPathComponent() : url
    }

    public static func write(_ snapshot: Snapshot, config: RunaConfig, root: URL, dryRun: Bool = false) throws -> Report {
        var report = Report()
        for target in config.targets {
            let result = export(snapshot, target: target, options: config.exportOptions(for: target))
            report.warnings += result.warnings.map { "\(target.format.rawValue): \($0)" }
            let base = baseDirectory(for: target, root: root)
            for file in result.files {
                let url = base.appendingPathComponent(file.relativePath)
                let display = url.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
                if let existing = try? Data(contentsOf: url), existing == file.contents {
                    report.unchanged.append(display)
                    continue
                }
                report.written.append(display)
                if dryRun { continue }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.contents.write(to: url, options: .atomic)
            }
        }
        return report
    }
}
