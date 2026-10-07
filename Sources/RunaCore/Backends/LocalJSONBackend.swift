import Foundation

/// A project stored as one JSON file, `*.runa.json`. Zero setup; good for demos, tests and
/// teams that keep strings in a repository.
public actor LocalJSONBackend: StringsBackend {
    public nonisolated let kind = BackendKind.localJSON
    public nonisolated let url: URL

    struct FileContents: Codable {
        var format = "runa"
        var schemaVersion = ProjectSettings.currentSchemaVersion
        var settings: ProjectSettings
        var keys: [StringKey]
        var history: [HistoryEntry]
    }

    public init(url: URL) {
        self.url = url
    }

    /// Creates a new project file. Fails if the file exists.
    public static func create(at url: URL, settings: ProjectSettings, keys: [StringKey] = []) throws -> LocalJSONBackend {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw BackendError.invalidData("\(url.lastPathComponent) already exists")
        }
        let backend = LocalJSONBackend(url: url)
        try write(FileContents(settings: settings, keys: keys, history: []), to: url)
        return backend
    }

    public func pull() async throws -> Snapshot {
        let contents = try read()
        return Snapshot(settings: contents.settings, keys: contents.keys, fetchedAt: Date())
    }

    public func push(_ changes: [Change], basedOn base: Snapshot, context: PushContext) async throws -> PushResult {
        var contents = try read()
        let current = Snapshot(settings: contents.settings, keys: contents.keys, fetchedAt: Date())
        let outcome = ChangeApplier.apply(changes, to: current, base: base, context: context)
        if !outcome.history.isEmpty {
            contents.keys = outcome.snapshot.keys
            contents.history.append(contentsOf: outcome.history)
            try Self.write(contents, to: url)
        }
        return PushResult(snapshot: outcome.snapshot, applied: outcome.applied, conflicts: outcome.conflicts)
    }

    public func addLocale(_ locale: LocaleCode, context: PushContext) async throws -> Snapshot {
        var contents = try read()
        guard !contents.settings.locales.contains(locale) else { throw BackendError.localeExists(locale) }
        contents.settings.locales.append(locale)
        contents.history.append(HistoryEntry(date: context.date, actor: context.actor, action: .addLocale, locale: locale, note: context.note))
        try Self.write(contents, to: url)
        return Snapshot(settings: contents.settings, keys: contents.keys)
    }

    public func removeLocale(_ locale: LocaleCode, context: PushContext) async throws -> Snapshot {
        var contents = try read()
        guard locale != contents.settings.sourceLocale else { throw BackendError.cannotRemoveSourceLocale }
        guard contents.settings.locales.contains(locale) else { throw BackendError.localeMissing(locale) }
        contents.settings.locales.removeAll { $0 == locale }
        for index in contents.keys.indices { contents.keys[index].translations[locale] = nil }
        contents.history.append(HistoryEntry(date: context.date, actor: context.actor, action: .removeLocale, locale: locale, note: context.note))
        try Self.write(contents, to: url)
        return Snapshot(settings: contents.settings, keys: contents.keys)
    }

    public func history(keyID: UUID?, limit: Int) async throws -> [HistoryEntry] {
        let history = try read().history.reversed().filter { keyID == nil || $0.keyID == keyID }
        return Array(history.prefix(limit))
    }

    private func read() throws -> FileContents {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackendError.notFound("Could not open \(url.path): \(error.localizedDescription)")
        }
        do {
            return try Self.decoder.decode(FileContents.self, from: data)
        } catch {
            throw BackendError.invalidData("\(url.lastPathComponent) is not a valid Runa file: \(error)")
        }
    }

    private static func write(_ contents: FileContents, to url: URL) throws {
        var sorted = contents
        sorted.keys.sort { $0.key < $1.key }
        let data = try encoder.encode(sorted)
        try data.write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
