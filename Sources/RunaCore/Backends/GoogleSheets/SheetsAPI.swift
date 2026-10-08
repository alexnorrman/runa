import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TabInfo: Sendable, Hashable {
    public var sheetID: Int
    public var title: String
    public var hidden: Bool
    public var rowCount: Int
    public var columnCount: Int
}

public struct SpreadsheetInfo: Sendable, Hashable {
    public var title: String
    public var tabs: [TabInfo]

    public func tab(_ title: String) -> TabInfo? { tabs.first { $0.title == title } }
}

/// The subset of `spreadsheets.batchUpdate` requests Runa uses. Rows and columns are 0-based.
public enum SheetRequest: Hashable, Sendable {
    case addSheet(sheetID: Int, title: String, hidden: Bool, rowCount: Int, columnCount: Int)
    case renameSheet(sheetID: Int, title: String)
    /// Writes a block of cells starting at (row, column). `nil` clears a cell.
    case updateCells(sheetID: Int, row: Int, column: Int, rows: [[String?]])
    /// Appends rows after the last row with data.
    case appendRows(sheetID: Int, rows: [[String]])
    case insertRows(sheetID: Int, at: Int, count: Int)
    case insertColumns(sheetID: Int, at: Int, count: Int)
    case deleteRows(sheetID: Int, start: Int, end: Int)
    case deleteColumns(sheetID: Int, start: Int, end: Int)
    case hideColumns(sheetID: Int, start: Int, end: Int)
    case freezeRows(sheetID: Int, count: Int)

    var json: JSONValue {
        func range(_ sheetID: Int, _ dimension: String, _ start: Int, _ end: Int) -> JSONValue {
            .object([("sheetId", .number(Double(sheetID))), ("dimension", .string(dimension)),
                     ("startIndex", .number(Double(start))), ("endIndex", .number(Double(end)))])
        }
        func cells(_ rows: [[String?]]) -> JSONValue {
            .array(rows.map { row in
                .object([("values", .array(row.map { cell in
                    guard let cell, !cell.isEmpty else { return .object([]) }
                    return .object([("userEnteredValue", .object([("stringValue", .string(cell))]))])
                }))])
            })
        }
        switch self {
        case .addSheet(let sheetID, let title, let hidden, let rowCount, let columnCount):
            // Google rejects a grid whose rows are all frozen, so a one-row tab gets no frozen header.
            var grid: [(String, JSONValue)] = [("rowCount", .number(Double(rowCount))), ("columnCount", .number(Double(columnCount)))]
            if rowCount > 1 { grid.append(("frozenRowCount", .number(1))) }
            return .object([("addSheet", .object([("properties", .object([
                ("sheetId", .number(Double(sheetID))), ("title", .string(title)), ("hidden", .bool(hidden)),
                ("gridProperties", .object(grid)),
            ]))]))])
        case .renameSheet(let sheetID, let title):
            return .object([("updateSheetProperties", .object([
                ("properties", .object([("sheetId", .number(Double(sheetID))), ("title", .string(title))])),
                ("fields", .string("title")),
            ]))])
        case .updateCells(let sheetID, let row, let column, let rows):
            return .object([("updateCells", .object([
                ("start", .object([("sheetId", .number(Double(sheetID))), ("rowIndex", .number(Double(row))),
                                   ("columnIndex", .number(Double(column)))])),
                ("rows", cells(rows)),
                ("fields", .string("userEnteredValue")),
            ]))])
        case .appendRows(let sheetID, let rows):
            return .object([("appendCells", .object([
                ("sheetId", .number(Double(sheetID))), ("rows", cells(rows.map { $0.map { $0 } })), ("fields", .string("userEnteredValue")),
            ]))])
        case .insertRows(let sheetID, let at, let count):
            return .object([("insertDimension", .object([("range", range(sheetID, "ROWS", at, at + count)), ("inheritFromBefore", .bool(at > 0))]))])
        case .insertColumns(let sheetID, let at, let count):
            return .object([("insertDimension", .object([("range", range(sheetID, "COLUMNS", at, at + count)), ("inheritFromBefore", .bool(at > 0))]))])
        case .deleteRows(let sheetID, let start, let end):
            return .object([("deleteDimension", .object([("range", range(sheetID, "ROWS", start, end))]))])
        case .deleteColumns(let sheetID, let start, let end):
            return .object([("deleteDimension", .object([("range", range(sheetID, "COLUMNS", start, end))]))])
        case .hideColumns(let sheetID, let start, let end):
            return .object([("updateDimensionProperties", .object([
                ("range", range(sheetID, "COLUMNS", start, end)),
                ("properties", .object([("hiddenByUser", .bool(true))])),
                ("fields", .string("hiddenByUser")),
            ]))])
        case .freezeRows(let sheetID, let count):
            return .object([("updateSheetProperties", .object([
                ("properties", .object([("sheetId", .number(Double(sheetID))),
                                        ("gridProperties", .object([("frozenRowCount", .number(Double(count)))]))])),
                ("fields", .string("gridProperties.frozenRowCount")),
            ]))])
        }
    }
}

/// The Google Sheets operations Runa needs. `GoogleSheetsAPI` talks to Google;
/// `InMemorySheetsAPI` behaves the same way in memory for tests and demos.
public protocol SheetsAPI: Sendable {
    func spreadsheet(_ id: String) async throws -> SpreadsheetInfo
    /// Formatted cell values of whole tabs, trailing empty cells omitted like Google does.
    func values(_ id: String, tabs: [String]) async throws -> [String: [[String]]]
    /// Applies requests atomically: all of them or none.
    func batchUpdate(_ id: String, requests: [SheetRequest]) async throws
}

public struct GoogleSheetsAPI: SheetsAPI {
    let http: HTTPClient
    let tokens: AccessTokenProvider
    /// Shown in "share the sheet with …" errors.
    let accountEmail: String?
    static let base = "https://sheets.googleapis.com/v4/spreadsheets/"

    public init(tokens: AccessTokenProvider, accountEmail: String? = nil, http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
        self.tokens = tokens
        self.accountEmail = accountEmail
    }

    /// Convenience for the common case: a service account key.
    public init(credentials: ServiceAccountCredentials, http: HTTPClient = URLSessionHTTPClient()) {
        self.init(tokens: ServiceAccountTokenProvider(credentials: credentials, http: http), accountEmail: credentials.clientEmail, http: http)
    }

    public func spreadsheet(_ id: String) async throws -> SpreadsheetInfo {
        let fields = "properties.title,sheets.properties(sheetId,title,hidden,gridProperties(rowCount,columnCount))"
        let json = try await send(path: "\(id)?fields=\(fields.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)", id: id)
        let title = json["properties"]?["title"]?.stringValue ?? "Untitled"
        var tabs: [TabInfo] = []
        if case .array(let sheets)? = json["sheets"] {
            for sheet in sheets {
                guard let properties = sheet["properties"] else { continue }
                func int(_ value: JSONValue?) -> Int {
                    if case .number(let number)? = value { return Int(number) }
                    return 0
                }
                tabs.append(TabInfo(sheetID: int(properties["sheetId"]), title: properties["title"]?.stringValue ?? "",
                                    hidden: properties["hidden"]?.boolValue ?? false,
                                    rowCount: int(properties["gridProperties"]?["rowCount"]),
                                    columnCount: int(properties["gridProperties"]?["columnCount"])))
            }
        }
        return SpreadsheetInfo(title: title, tabs: tabs)
    }

    public func values(_ id: String, tabs: [String]) async throws -> [String: [[String]]] {
        guard !tabs.isEmpty else { return [:] }
        var query = tabs.map { "ranges=\(quoteRange($0))" }
        query.append("valueRenderOption=FORMATTED_VALUE")
        query.append("majorDimension=ROWS")
        let json = try await send(path: "\(id)/values:batchGet?\(query.joined(separator: "&"))", id: id)
        var result: [String: [[String]]] = [:]
        if case .array(let ranges)? = json["valueRanges"] {
            for (index, range) in ranges.enumerated() where index < tabs.count {
                var rows: [[String]] = []
                if case .array(let rawRows)? = range["values"] {
                    for rawRow in rawRows {
                        guard case .array(let cells) = rawRow else { rows.append([]); continue }
                        rows.append(cells.map { cell in
                            switch cell {
                            case .string(let string): return string
                            case .number(let number): return number.rounded() == number ? String(Int64(number)) : String(number)
                            case .bool(let bool): return bool ? "TRUE" : "FALSE"
                            default: return ""
                            }
                        })
                    }
                }
                result[tabs[index]] = rows
            }
        }
        return result
    }

    public func batchUpdate(_ id: String, requests: [SheetRequest]) async throws {
        guard !requests.isEmpty else { return }
        let body = JSONValue.object([("requests", .array(requests.map(\.json)))]).serialized(style: .standard)
        _ = try await send(path: "\(id):batchUpdate", id: id, method: "POST", body: Data(body.utf8))
    }

    private func quoteRange(_ tab: String) -> String {
        let quoted = "'\(tab.replacingOccurrences(of: "'", with: "''"))'"
        return quoted.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? quoted
    }

    private func send(path: String, id: String, method: String = "GET", body: Data? = nil) async throws -> JSONValue {
        guard let url = URL(string: Self.base + path) else { throw BackendError.invalidData("Invalid spreadsheet id") }
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await http.send(request)
            if (response.statusCode == 429 || response.statusCode >= 500), attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt))) * 500_000_000)
                continue
            }
            let json = (try? JSONValue.parse(data)) ?? .null
            guard (200..<300).contains(response.statusCode) else {
                let message = json["error"]?["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                switch response.statusCode {
                case 401: throw BackendError.authenticationFailed(message)
                case 403:
                    let share = accountEmail.map { " Share the sheet with \($0) as an editor." } ?? ""
                    throw BackendError.accessDenied("No access to the spreadsheet.\(share)")
                case 404: throw BackendError.notFound("Spreadsheet \(id) was not found. Check the link.")
                case 429: throw BackendError.rateLimited
                default: throw BackendError.server(response.statusCode, message)
                }
            }
            return json
        }
    }
}
