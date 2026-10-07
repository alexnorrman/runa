import Foundation

/// A spreadsheet in memory with the same semantics as Google's API, including grid limits and
/// atomic batches. Used by tests and the app's demo mode.
public actor InMemorySheetsAPI: SheetsAPI {
    public struct Tab: Sendable {
        public var info: TabInfo
        public var grid: [[String]]
    }

    public struct Spreadsheet: Sendable {
        public var title: String
        public var tabs: [Tab]
    }

    public private(set) var spreadsheets: [String: Spreadsheet] = [:]
    public private(set) var batchCount = 0

    public init() {}

    /// Creates a spreadsheet like Google's "blank spreadsheet": one empty `Sheet1`.
    public func create(id: String, title: String = "Strings", tabs: [String: [[String]]]? = nil) {
        var spreadsheet = Spreadsheet(title: title, tabs: [])
        let initial = tabs ?? ["Sheet1": []]
        for (index, name) in initial.keys.sorted().enumerated() {
            let grid = initial[name] ?? []
            let width = max(26, grid.map(\.count).max() ?? 0)
            spreadsheet.tabs.append(Tab(info: TabInfo(sheetID: index, title: name, hidden: false, rowCount: max(1000, grid.count),
                                                      columnCount: width), grid: grid))
        }
        spreadsheets[id] = spreadsheet
    }

    /// Simulates someone editing a cell directly in Google Sheets.
    public func setCell(id: String, tab: String, row: Int, column: Int, value: String) throws {
        guard var spreadsheet = spreadsheets[id], let index = spreadsheet.tabs.firstIndex(where: { $0.info.title == tab }) else {
            throw BackendError.notFound("No tab \(tab)")
        }
        Self.write(&spreadsheet.tabs[index].grid, row: row, column: column, value: value)
        spreadsheets[id] = spreadsheet
    }

    /// Simulates someone inserting a row directly in Google Sheets.
    public func insertRow(id: String, tab: String, at row: Int, values: [String]) throws {
        guard var spreadsheet = spreadsheets[id], let index = spreadsheet.tabs.firstIndex(where: { $0.info.title == tab }) else {
            throw BackendError.notFound("No tab \(tab)")
        }
        while spreadsheet.tabs[index].grid.count < row { spreadsheet.tabs[index].grid.append([]) }
        spreadsheet.tabs[index].grid.insert(values, at: row)
        spreadsheet.tabs[index].info.rowCount += 1
        spreadsheets[id] = spreadsheet
    }

    public func grid(id: String, tab: String) -> [[String]] {
        Self.trimmed(spreadsheets[id]?.tabs.first { $0.info.title == tab }?.grid ?? [])
    }

    public func spreadsheet(_ id: String) async throws -> SpreadsheetInfo {
        guard let spreadsheet = spreadsheets[id] else { throw BackendError.notFound("Spreadsheet \(id) was not found. Check the link.") }
        return SpreadsheetInfo(title: spreadsheet.title, tabs: spreadsheet.tabs.map(\.info))
    }

    public func values(_ id: String, tabs: [String]) async throws -> [String: [[String]]] {
        guard let spreadsheet = spreadsheets[id] else { throw BackendError.notFound("Spreadsheet \(id) was not found. Check the link.") }
        var result: [String: [[String]]] = [:]
        for name in tabs {
            guard let tab = spreadsheet.tabs.first(where: { $0.info.title == name }) else {
                throw BackendError.server(400, "Unable to parse range: \(name)")
            }
            result[name] = Self.trimmed(tab.grid)
        }
        return result
    }

    public func batchUpdate(_ id: String, requests: [SheetRequest]) async throws {
        guard var spreadsheet = spreadsheets[id] else { throw BackendError.notFound("Spreadsheet \(id) was not found. Check the link.") }
        for request in requests { try apply(request, to: &spreadsheet) }
        spreadsheets[id] = spreadsheet
        batchCount += 1
    }

    private func apply(_ request: SheetRequest, to spreadsheet: inout Spreadsheet) throws {
        func tabIndex(_ sheetID: Int) throws -> Int {
            guard let index = spreadsheet.tabs.firstIndex(where: { $0.info.sheetID == sheetID }) else {
                throw BackendError.server(400, "No grid with id: \(sheetID)")
            }
            return index
        }
        switch request {
        case .addSheet(let sheetID, let title, let hidden, let rowCount, let columnCount):
            guard !spreadsheet.tabs.contains(where: { $0.info.title == title || $0.info.sheetID == sheetID }) else {
                throw BackendError.server(400, "A sheet with the name \"\(title)\" already exists")
            }
            spreadsheet.tabs.append(Tab(info: TabInfo(sheetID: sheetID, title: title, hidden: hidden, rowCount: rowCount,
                                                      columnCount: columnCount), grid: []))
        case .renameSheet(let sheetID, let title):
            spreadsheet.tabs[try tabIndex(sheetID)].info.title = title
        case .updateCells(let sheetID, let row, let column, let rows):
            let index = try tabIndex(sheetID)
            let info = spreadsheet.tabs[index].info
            for (offset, cells) in rows.enumerated() {
                guard row + offset < info.rowCount, column + cells.count <= info.columnCount else {
                    throw BackendError.server(400, "Range (\(info.title)!R\(row + offset + 1)C\(column + cells.count)) exceeds grid limits.")
                }
                for (columnOffset, cell) in cells.enumerated() {
                    Self.write(&spreadsheet.tabs[index].grid, row: row + offset, column: column + columnOffset, value: cell ?? "")
                }
            }
        case .appendRows(let sheetID, let rows):
            let index = try tabIndex(sheetID)
            let trimmedCount = Self.trimmed(spreadsheet.tabs[index].grid).count
            spreadsheet.tabs[index].grid = Array(spreadsheet.tabs[index].grid.prefix(trimmedCount))
            for cells in rows {
                guard cells.count <= spreadsheet.tabs[index].info.columnCount else {
                    throw BackendError.server(400, "Appended row is wider than the grid")
                }
                spreadsheet.tabs[index].grid.append(cells)
            }
            spreadsheet.tabs[index].info.rowCount = max(spreadsheet.tabs[index].info.rowCount, spreadsheet.tabs[index].grid.count)
        case .insertRows(let sheetID, let at, let count):
            let index = try tabIndex(sheetID)
            guard at <= spreadsheet.tabs[index].info.rowCount else { throw BackendError.server(400, "Row index out of range") }
            while spreadsheet.tabs[index].grid.count < at { spreadsheet.tabs[index].grid.append([]) }
            spreadsheet.tabs[index].grid.insert(contentsOf: Array(repeating: [], count: count), at: at)
            spreadsheet.tabs[index].info.rowCount += count
        case .insertColumns(let sheetID, let at, let count):
            let index = try tabIndex(sheetID)
            guard at <= spreadsheet.tabs[index].info.columnCount else { throw BackendError.server(400, "Column index out of range") }
            for row in spreadsheet.tabs[index].grid.indices where spreadsheet.tabs[index].grid[row].count > at {
                spreadsheet.tabs[index].grid[row].insert(contentsOf: Array(repeating: "", count: count), at: at)
            }
            spreadsheet.tabs[index].info.columnCount += count
        case .deleteRows(let sheetID, let start, let end):
            let index = try tabIndex(sheetID)
            guard start < end, end <= spreadsheet.tabs[index].info.rowCount else { throw BackendError.server(400, "Row range out of bounds") }
            let upper = min(end, spreadsheet.tabs[index].grid.count)
            if start < upper { spreadsheet.tabs[index].grid.removeSubrange(start..<upper) }
            spreadsheet.tabs[index].info.rowCount -= end - start
        case .deleteColumns(let sheetID, let start, let end):
            let index = try tabIndex(sheetID)
            guard start < end, end <= spreadsheet.tabs[index].info.columnCount else { throw BackendError.server(400, "Column range out of bounds") }
            for row in spreadsheet.tabs[index].grid.indices {
                let upper = min(end, spreadsheet.tabs[index].grid[row].count)
                if start < upper { spreadsheet.tabs[index].grid[row].removeSubrange(start..<upper) }
            }
            spreadsheet.tabs[index].info.columnCount -= end - start
        case .hideColumns(let sheetID, _, _), .freezeRows(let sheetID, _):
            _ = try tabIndex(sheetID)
        }
    }

    static func write(_ grid: inout [[String]], row: Int, column: Int, value: String) {
        while grid.count <= row { grid.append([]) }
        while grid[row].count <= column { grid[row].append("") }
        grid[row][column] = value
    }

    static func trimmed(_ grid: [[String]]) -> [[String]] {
        var rows = grid.map { row -> [String] in
            var row = row
            while let last = row.last, last.isEmpty { row.removeLast() }
            return row
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows
    }
}
