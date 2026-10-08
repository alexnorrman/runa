import Foundation

/// Strings stored in a Google Sheet, laid out as described in docs/SHEET_FORMAT.md.
public struct GoogleSheetsBackend: StringsBackend {
    public let kind = BackendKind.googleSheets
    public let spreadsheetID: String
    let api: any SheetsAPI

    public init(spreadsheetID: String, api: any SheetsAPI) {
        self.spreadsheetID = spreadsheetID
        self.api = api
    }

    /// Extracts the id from a link such as `https://docs.google.com/spreadsheets/d/<id>/edit#gid=0`,
    /// or returns the input when it already is an id.
    public static func spreadsheetID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"/spreadsheets/d/([A-Za-z0-9_-]+)"#, options: .regularExpression) {
            return String(trimmed[range].dropFirst("/spreadsheets/d/".count))
        }
        if trimmed.range(of: #"^[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil { return trimmed }
        return nil
    }

    // MARK: Setup

    public enum SheetState: Sendable, Equatable {
        /// No `strings` tab; setup creates everything.
        case empty
        /// A `strings` tab with a `key` column exists, but Runa's columns or tabs are missing.
        case adoptable(locales: [LocaleCode], keyCount: Int, missing: [String])
        /// Ready to use.
        case ready(locales: [LocaleCode], keyCount: Int)
    }

    public struct Inspection: Sendable {
        public var title: String
        public var state: SheetState
    }

    /// Looks at the sheet without changing it. Also proves the credentials can read it.
    public func inspect() async throws -> Inspection {
        let info = try await api.spreadsheet(spreadsheetID)
        guard info.tab(SheetLayout.stringsTab) != nil else { return Inspection(title: info.title, state: .empty) }
        let known = [SheetLayout.stringsTab] + SheetLayout.hiddenTabs
        let grids = try await api.values(spreadsheetID, tabs: info.tabs.map(\.title).filter { known.contains($0) })
        let header = grids[SheetLayout.stringsTab]?.first ?? []
        guard let columns = try? StringsColumns(header: header) else { return Inspection(title: info.title, state: .empty) }
        let keyCount = Set((grids[SheetLayout.stringsTab] ?? []).dropFirst().map { SheetCodec.cell($0, columns.key) }.filter { !$0.isEmpty }).count
        var missing = SheetLayout.hiddenTabs.filter { info.tab($0) == nil }
        for column in [SheetLayout.idColumn, SheetLayout.descriptionColumn, SheetLayout.pluralColumn, SheetLayout.figmaColumn,
                       SheetLayout.tagsColumn, SheetLayout.platformsColumn]
        {
            let present = header.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == column }
                || (column == SheetLayout.descriptionColumn && columns.description != nil)
            if !present { missing.append("column \(column)") }
        }
        let locales = columns.locales.map(\.locale)
        if missing.isEmpty { return Inspection(title: info.title, state: .ready(locales: locales, keyCount: keyCount)) }
        return Inspection(title: info.title, state: .adoptable(locales: locales, keyCount: keyCount, missing: missing))
    }

    /// Creates the layout in an empty sheet, or adds Runa's missing tabs and columns to an existing
    /// `strings` tab without touching its data.
    public func setUp(projectName: String? = nil, sourceLocale: LocaleCode, locales: [LocaleCode] = [], context: PushContext) async throws -> Snapshot {
        let info = try await api.spreadsheet(spreadsheetID)
        var requests: [SheetRequest] = []
        var nextID = (info.tabs.map(\.sheetID).max() ?? 0) + 1
        func newSheetID() -> Int {
            defer { nextID += 1 }
            return nextID
        }
        let allLocales = ProjectSettings(name: "", sourceLocale: sourceLocale, locales: locales).locales

        if let strings = info.tab(SheetLayout.stringsTab) {
            let grids = try await api.values(spreadsheetID, tabs: [SheetLayout.stringsTab])
            let header = grids[SheetLayout.stringsTab]?.first ?? []
            let columns = try StringsColumns(header: header)
            var additions: [String] = []
            let lowered = Set(header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            if columns.id == nil { additions.append(SheetLayout.idColumn) }
            if columns.description == nil { additions.append(SheetLayout.descriptionColumn) }
            for name in [SheetLayout.pluralColumn, SheetLayout.figmaColumn, SheetLayout.tagsColumn, SheetLayout.platformsColumn]
            where !lowered.contains(name) {
                additions.append(name)
            }
            for locale in allLocales where columns.index(of: locale) == nil { additions.append(locale.rawValue) }
            if !additions.isEmpty {
                let start = max(header.count, 0)
                let needed = start + additions.count - strings.columnCount
                if needed > 0 { requests.append(.insertColumns(sheetID: strings.sheetID, at: strings.columnCount, count: needed)) }
                requests.append(.updateCells(sheetID: strings.sheetID, row: 0, column: start, rows: [additions]))
            }
            if columns.id == nil {
                requests.append(.hideColumns(sheetID: strings.sheetID, start: header.count, end: header.count + 1))
            }
        } else {
            let header = SheetLayout.stringsHeader(locales: allLocales)
            let reuse = info.tabs.count == 1 ? info.tabs[0] : nil
            let reusable: Bool
            if let reuse {
                let grid = try await api.values(spreadsheetID, tabs: [reuse.title])[reuse.title] ?? []
                reusable = grid.isEmpty
            } else {
                reusable = false
            }
            let sheetID: Int
            if let reuse, reusable {
                // A blank new spreadsheet: rename its only tab instead of leaving an empty "Sheet1".
                sheetID = reuse.sheetID
                requests.append(.renameSheet(sheetID: sheetID, title: SheetLayout.stringsTab))
                if reuse.columnCount < header.count {
                    requests.append(.insertColumns(sheetID: sheetID, at: reuse.columnCount, count: header.count - reuse.columnCount))
                }
            } else {
                sheetID = newSheetID()
                requests.append(.addSheet(sheetID: sheetID, title: SheetLayout.stringsTab, hidden: false, rowCount: 1000,
                                          columnCount: max(26, header.count)))
            }
            requests.append(.updateCells(sheetID: sheetID, row: 0, column: 0, rows: [header]))
            requests.append(.freezeRows(sheetID: sheetID, count: 1))
            requests.append(.hideColumns(sheetID: sheetID, start: 0, end: 1))
        }

        for tab in SheetLayout.hiddenTabs where info.tab(tab) == nil {
            let header = SheetLayout.header(for: tab)
            let sheetID = newSheetID()
            // Two rows, not one: the header row is frozen, and Google refuses to freeze every row of a grid.
            requests.append(.addSheet(sheetID: sheetID, title: tab, hidden: true, rowCount: 2, columnCount: header.count))
            var rows = [header]
            if tab == SheetLayout.metaTab {
                rows += [["schemaVersion", String(ProjectSettings.currentSchemaVersion)],
                         ["projectName", projectName ?? info.title],
                         ["sourceLocale", sourceLocale.rawValue]]
            }
            requests.append(.appendRows(sheetID: sheetID, rows: rows))
        }

        // Visible tabs for the naming guide and glossary, so people find where they go.
        for tab in SheetLayout.guidelineTabs where info.tab(tab) == nil {
            let rows = tab == SheetLayout.guidelinesTab
                ? GuidelinesSheet.guidelinesGrid(ProjectGuidelines(), existing: [])
                : [SheetLayout.glossaryHeader + allLocales.filter { $0 != sourceLocale }.map(\.rawValue)]
            let sheetID = newSheetID()
            requests.append(.addSheet(sheetID: sheetID, title: tab, hidden: false, rowCount: 20, columnCount: max(3, rows[0].count)))
            requests.append(.updateCells(sheetID: sheetID, row: 0, column: 0, rows: rows))
        }
        try await api.batchUpdate(spreadsheetID, requests: requests)
        return try await pull()
    }

    // MARK: StringsBackend

    func load() async throws -> DecodedSheet {
        let info = try await api.spreadsheet(spreadsheetID)
        let wanted = [SheetLayout.stringsTab] + SheetLayout.hiddenTabs + SheetLayout.guidelineTabs
        let present = wanted.filter { info.tab($0) != nil }
        let grids = try await api.values(spreadsheetID, tabs: present)
        return try SheetCodec.decode(info: info, grids: grids)
    }

    /// Loads the sheet, first creating Runa's hidden tabs if someone set up `strings` by hand.
    func loadForWriting(context: PushContext) async throws -> DecodedSheet {
        var decoded = try await load()
        if !decoded.missingTabs.isEmpty || decoded.columns.id == nil {
            _ = try await setUp(sourceLocale: decoded.snapshot.settings.sourceLocale, locales: decoded.snapshot.settings.locales, context: context)
            decoded = try await load()
        }
        return decoded
    }

    public func pull() async throws -> Snapshot {
        try await load().snapshot
    }

    public func push(_ changes: [Change], basedOn base: Snapshot, context: PushContext) async throws -> PushResult {
        let decoded = try await loadForWriting(context: context)
        let outcome = ChangeApplier.apply(changes, to: decoded.snapshot, base: base, context: context)
        let requests = SheetWriter.requests(decoded: decoded, target: outcome.snapshot, touched: outcome.touchedKeyIDs, history: outcome.history)
        try await api.batchUpdate(spreadsheetID, requests: requests)
        var snapshot = outcome.snapshot
        snapshot.fetchedAt = Date()
        return PushResult(snapshot: snapshot, applied: outcome.applied, conflicts: outcome.conflicts)
    }

    public func addLocale(_ locale: LocaleCode, context: PushContext) async throws -> Snapshot {
        let decoded = try await loadForWriting(context: context)
        guard decoded.columns.index(of: locale) == nil else { throw BackendError.localeExists(locale) }
        guard let strings = decoded.info.tab(SheetLayout.stringsTab) else { throw BackendError.invalidData("No strings tab") }
        let lastLocaleColumn = decoded.columns.locales.map(\.index).max() ?? decoded.columns.key
        let column = lastLocaleColumn + 1
        var requests: [SheetRequest] = [
            .insertColumns(sheetID: strings.sheetID, at: column, count: 1),
            .updateCells(sheetID: strings.sheetID, row: 0, column: column, rows: [[locale.rawValue]]),
        ]
        if let history = decoded.info.tab(SheetLayout.historyTab) {
            let entry = HistoryEntry(date: context.date, actor: context.actor, action: .addLocale, locale: locale, note: context.note)
            requests.append(.appendRows(sheetID: history.sheetID, rows: [SheetWriter.historyRow(entry)]))
        }
        try await api.batchUpdate(spreadsheetID, requests: requests)
        return try await pull()
    }

    public func removeLocale(_ locale: LocaleCode, context: PushContext) async throws -> Snapshot {
        let decoded = try await loadForWriting(context: context)
        guard locale != decoded.snapshot.settings.sourceLocale else { throw BackendError.cannotRemoveSourceLocale }
        guard let column = decoded.columns.index(of: locale), let strings = decoded.info.tab(SheetLayout.stringsTab) else {
            throw BackendError.localeMissing(locale)
        }
        var requests: [SheetRequest] = [.deleteColumns(sheetID: strings.sheetID, start: column, end: column + 1)]
        if let status = decoded.info.tab(SheetLayout.statusTab) {
            let grid = decoded.grids[SheetLayout.statusTab] ?? []
            let localeColumn = SheetCodec.headerIndexes(grid.first ?? SheetLayout.statusHeader)["locale"]
            let rows = grid.enumerated().dropFirst().filter { LocaleCode(rawValue: SheetCodec.cell($0.element, localeColumn)) == locale }.map(\.offset)
            requests += rows.sorted(by: >).map { .deleteRows(sheetID: status.sheetID, start: $0, end: $0 + 1) }
        }
        if let history = decoded.info.tab(SheetLayout.historyTab) {
            let entry = HistoryEntry(date: context.date, actor: context.actor, action: .removeLocale, locale: locale, note: context.note)
            requests.append(.appendRows(sheetID: history.sheetID, rows: [SheetWriter.historyRow(entry)]))
        }
        try await api.batchUpdate(spreadsheetID, requests: requests)
        return try await pull()
    }

    public func setGuidelines(_ guidelines: ProjectGuidelines, basedOn base: ProjectGuidelines, context: PushContext) async throws -> Snapshot {
        let decoded = try await loadForWriting(context: context)
        let current = decoded.snapshot.guidelines
        let merged = try ProjectGuidelines.merge(mine: guidelines.normalized, base: base.normalized, theirs: current)
        let history = merged.historyEntries(from: current, context: context)
        guard !history.isEmpty else { return decoded.snapshot }
        try GuidelinesSheet.checkCellSizes(merged)

        var nextID = (decoded.info.tabs.map(\.sheetID).max() ?? 0) + 1
        func newSheetID() -> Int {
            defer { nextID += 1 }
            return nextID
        }
        var requests: [SheetRequest] = []
        if history.contains(where: { $0.key != "glossary" }) {
            let grid = GuidelinesSheet.guidelinesGrid(merged, existing: decoded.grids[SheetLayout.guidelinesTab] ?? [])
            requests += GuidelinesSheet.requests(tab: SheetLayout.guidelinesTab, grid: grid, decoded: decoded, newSheetID: newSheetID)
        }
        if history.contains(where: { $0.key == "glossary" }) {
            let grid = GuidelinesSheet.glossaryGrid(merged, settings: decoded.snapshot.settings)
            requests += GuidelinesSheet.requests(tab: SheetLayout.glossaryTab, grid: grid, decoded: decoded, newSheetID: newSheetID)
        }
        if let tab = decoded.info.tab(SheetLayout.historyTab) {
            requests.append(.appendRows(sheetID: tab.sheetID, rows: history.map(SheetWriter.historyRow)))
        }
        try await api.batchUpdate(spreadsheetID, requests: requests)
        return try await pull()
    }

    public func history(keyID: UUID?, limit: Int) async throws -> [HistoryEntry] {
        let info = try await api.spreadsheet(spreadsheetID)
        guard info.tab(SheetLayout.historyTab) != nil else { return [] }
        let grid = try await api.values(spreadsheetID, tabs: [SheetLayout.historyTab])[SheetLayout.historyTab] ?? []
        let entries = SheetCodec.decodeHistory(grid).reversed().filter { keyID == nil || $0.keyID == keyID }
        return Array(entries.prefix(limit))
    }
}
