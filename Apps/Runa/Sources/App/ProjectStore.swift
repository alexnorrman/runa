import Foundation
import Observation
import RunaCore

enum KeyFilter: Hashable {
    case all
    case missing(LocaleCode?)
    case needsReview
    case machine
    case tag(String)

    var title: String {
        switch self {
        case .all: "All keys"
        case .missing(nil): "Missing"
        case .missing(let locale?): "Missing in \(locale.displayName())"
        case .needsReview: "Needs review"
        case .machine: "Machine drafts"
        case .tag(let tag): "#\(tag)"
        }
    }
}

enum SidebarItem: Hashable {
    case keys(KeyFilter)
    case review
    case languages
    case activity
    case importStrings
}

enum SyncState: Equatable {
    case idle
    case pulling
    case pushing
    case failed(String)
}

/// One open project: the last pulled snapshot, local edits waiting to be pushed, and sync.
///
/// Edits apply to the visible snapshot immediately and are pushed shortly after, so the app feels
/// instant and keeps working offline. Pushes send intents, and the backend reports any cell that
/// someone else changed in the meantime as a conflict instead of overwriting it.
@MainActor @Observable
final class ProjectStore {
    private(set) var record: ProjectRecord
    private unowned let app: AppModel

    /// State in the backend as of the last pull or push.
    private(set) var base: Snapshot?
    /// What the UI shows: `base` plus pending changes.
    private(set) var snapshot: Snapshot?
    private(set) var pending: [Change] = []
    private(set) var syncState = SyncState.idle
    private(set) var lastSynced: Date?
    var conflicts: [Conflict] = []
    private(set) var history: [HistoryEntry] = []

    var sidebar = SidebarItem.keys(.all)
    var searchText = ""
    var showInspector = true
    var selection = Set<UUID>()
    var isCreatingKey = false
    var translateScope: TranslateScope?
    var isExporting = false
    var isEditingProject = false
    var isConfirmingRemoval = false
    var lastError: String?

    private var pushTask: Task<Void, Never>?
    private var autoSyncTask: Task<Void, Never>?

    struct TranslateScope: Identifiable, Hashable {
        let id = UUID()
        var keyIDs: [UUID]?
        var locales: [LocaleCode]
    }

    private struct Cache: Codable {
        var base: Snapshot
        var pending: [Change]
        var lastSynced: Date?
    }

    init(record: ProjectRecord, app: AppModel) {
        self.record = record
        self.app = app
        if let cache = Storage.load(Cache.self, from: Storage.cacheFile(record.id)) {
            base = cache.base
            pending = cache.pending
            lastSynced = cache.lastSynced
            snapshot = Self.applyLocally(cache.pending, to: cache.base, actor: app.settings.displayName)
        }
        Task { await refresh() }
        startAutoSync()
    }

    var settings: ProjectSettings? { snapshot?.settings }
    var displayName: String { app.settings.displayName }

    func updateRecord(_ change: (inout ProjectRecord) -> Void) {
        change(&record)
        app.update(record)
    }

    // MARK: Sync

    func refresh() async {
        guard syncState != .pulling else { return }
        if !pending.isEmpty { await push() }
        syncState = .pulling
        do {
            let backend = try app.backend(for: record)
            let fresh = try await backend.pull()
            base = fresh
            snapshot = Self.applyLocally(pending, to: fresh, actor: displayName)
            lastSynced = Date()
            syncState = .idle
            if record.name != fresh.settings.name { updateRecord { $0.name = fresh.settings.name } }
            saveCache()
            selection = selection.filter { id in snapshot?[id: id] != nil }
        } catch {
            syncState = .failed(message(error))
        }
    }

    func loadHistory(keyID: UUID? = nil) async -> [HistoryEntry] {
        do {
            let entries = try await app.backend(for: record).history(keyID: keyID, limit: 300)
            if keyID == nil { history = entries }
            return entries
        } catch {
            lastError = message(error)
            return []
        }
    }

    /// Applies changes now and pushes them shortly.
    func perform(_ changes: [Change]) {
        guard let current = snapshot, !changes.isEmpty else { return }
        let context = PushContext(actor: displayName)
        snapshot = ChangeApplier.apply(changes, to: current, base: current, context: context).snapshot
        pending += changes
        saveCache()
        schedulePush()
    }

    func schedulePush(after delay: Duration = .milliseconds(700)) {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    func push(note: String? = nil) async {
        guard !pending.isEmpty, let base else { return }
        guard syncState != .pushing else {
            schedulePush(after: .seconds(1))
            return
        }
        let sending = pending
        syncState = .pushing
        do {
            let backend = try app.backend(for: record)
            let result = try await backend.push(sending, basedOn: base, context: PushContext(actor: displayName, note: note))
            pending.removeFirst(min(sending.count, pending.count))
            self.base = result.snapshot
            snapshot = Self.applyLocally(pending, to: result.snapshot, actor: displayName)
            conflicts += result.conflicts
            lastSynced = Date()
            syncState = .idle
            saveCache()
            if !pending.isEmpty { schedulePush() }
        } catch {
            syncState = .failed(message(error))
            saveCache()
        }
    }

    /// Runs a backend operation that is not a change list (languages), then refreshes.
    func run(_ operation: @escaping (any StringsBackend, PushContext) async throws -> Snapshot) async -> Bool {
        do {
            if !pending.isEmpty { await push() }
            let backend = try app.backend(for: record)
            let fresh = try await operation(backend, PushContext(actor: displayName))
            base = fresh
            snapshot = Self.applyLocally(pending, to: fresh, actor: displayName)
            lastSynced = Date()
            saveCache()
            return true
        } catch {
            lastError = message(error)
            return false
        }
    }

    /// Keep mine: re-send my value on top of the latest remote state. Keep theirs: drop it.
    func resolve(_ conflict: Conflict, keepMine: Bool) {
        conflicts.removeAll { $0.id == conflict.id }
        guard keepMine else { return }
        Task {
            await refresh()
            perform([conflict.change])
        }
    }

    private func startAutoSync() {
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = await MainActor.run { self?.app.settings.autoSyncMinutes ?? 2 }
                try? await Task.sleep(for: .seconds(max(30, minutes * 60)))
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    private func saveCache() {
        guard let base else { return }
        Storage.save(Cache(base: base, pending: pending, lastSynced: lastSynced), to: Storage.cacheFile(record.id))
    }

    private static func applyLocally(_ changes: [Change], to snapshot: Snapshot, actor: String) -> Snapshot {
        guard !changes.isEmpty else { return snapshot }
        return ChangeApplier.apply(changes, to: snapshot, base: snapshot, context: PushContext(actor: actor)).snapshot
    }

    func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Queries

    var filter: KeyFilter {
        if case .keys(let filter) = sidebar { return filter }
        return .all
    }

    var visibleKeys: [StringKey] { keys(matching: filter, search: searchText) }

    func keys(matching filter: KeyFilter, search searchText: String = "") -> [StringKey] {
        guard let snapshot else { return [] }
        var keys: [StringKey]
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            keys = snapshot.keys.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        } else {
            keys = KeySearch.search(searchText, in: snapshot, limit: 500)
        }
        let locales = snapshot.settings.locales
        switch filter {
        case .all: break
        case .missing(let locale):
            keys = keys.filter { key in
                (locale.map { [$0] } ?? locales).contains { snapshot.status(of: key, locale: $0) == .missing }
            }
        case .needsReview:
            keys = keys.filter { key in locales.contains { snapshot.status(of: key, locale: $0) == .needsReview } }
        case .machine:
            keys = keys.filter { key in locales.contains { snapshot.status(of: key, locale: $0) == .machine } }
        case .tag(let tag):
            keys = keys.filter { $0.tags.contains(tag) }
        }
        return keys
    }

    func count(_ filter: KeyFilter) -> Int {
        keys(matching: filter).count
    }

    var selectedKey: StringKey? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return snapshot?[id: id]
    }

    var allTags: [String] {
        Array(Set(snapshot?.keys.flatMap(\.tags) ?? [])).filter { $0 != StringKey.doNotTranslateTag }.sorted()
    }

    /// Locales with missing translations, most missing first.
    var missingByLocale: [(locale: LocaleCode, count: Int)] {
        guard let snapshot else { return [] }
        return snapshot.settings.locales.map { ($0, snapshot.coverage(for: $0).missing) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    var reviewCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.settings.targetLocales.reduce(0) { total, locale in
            let coverage = snapshot.coverage(for: locale)
            return total + coverage.machine + coverage.needsReview
        }
    }
}
