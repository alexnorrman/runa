import Foundation

/// Turns the difference between the sheet as read and the desired snapshot into one batch of
/// requests. Only rows of keys that changed are touched.
enum SheetWriter {
    static func requests(decoded: DecodedSheet, target: Snapshot, touched: Set<UUID>, history: [HistoryEntry]) -> [SheetRequest] {
        var requests: [SheetRequest] = []
        guard let stringsTab = decoded.info.tab(SheetLayout.stringsTab) else { return [] }
        requests += stringsRequests(decoded: decoded, tab: stringsTab, target: target, touched: touched)
        if let tab = decoded.info.tab(SheetLayout.statusTab) {
            requests += keyedRequests(tab: tab, grid: decoded.grids[SheetLayout.statusTab] ?? [], header: SheetLayout.statusHeader,
                                      identity: { row, columns in "\(SheetCodec.cell(row, columns["id"]).lowercased())|\(SheetCodec.cell(row, columns["locale"]))" },
                                      owner: { row, columns in UUID(uuidString: SheetCodec.cell(row, columns["id"])) },
                                      desired: statusRows(target: target, touched: touched), touched: touched)
        }
        if let tab = decoded.info.tab(SheetLayout.contextTab) {
            requests += keyedRequests(tab: tab, grid: decoded.grids[SheetLayout.contextTab] ?? [], header: SheetLayout.contextHeader,
                                      identity: { row, columns in "\(SheetCodec.cell(row, columns["id"]).lowercased())|\(SheetCodec.cell(row, columns["url"]))" },
                                      owner: { row, columns in UUID(uuidString: SheetCodec.cell(row, columns["id"])) },
                                      desired: contextRows(target: target, touched: touched), touched: touched)
        }
        if let tab = decoded.info.tab(SheetLayout.historyTab), !history.isEmpty {
            requests.append(.appendRows(sheetID: tab.sheetID, rows: history.map(historyRow)))
        }
        return requests
    }

    // MARK: strings

    /// Operations anchored to a row. Applying them bottom-up keeps every index valid.
    private enum RowOperation {
        case update(row: Int, column: Int, cells: [String?])
        case insertAfter(row: Int, rows: [[String]])
        case delete(row: Int)

        var row: Int {
            switch self {
            case .update(let row, _, _), .insertAfter(let row, _), .delete(let row): row
            }
        }

        /// Among operations on the same row: insert below it first, then edit it, then delete it.
        var rank: Int {
            switch self {
            case .insertAfter: 0
            case .update: 1
            case .delete: 2
            }
        }
    }

    static func stringsRequests(decoded: DecodedSheet, tab: TabInfo, target: Snapshot, touched: Set<UUID>) -> [SheetRequest] {
        let columns = decoded.columns
        var operations: [RowOperation] = []
        var appended: [[String]] = []
        let existingByID = Dictionary(grouping: decoded.stringsRows, by: \.id)

        for id in touched {
            let existing = existingByID[id] ?? []
            guard let key = target[id: id] else {
                operations += existing.map { .delete(row: $0.index) }
                continue
            }
            let categories: [PluralCategory?] = key.isPlural ? pluralCategories(for: key, locales: target.settings.locales) : [nil]
            var unmatched = existing
            var matched: [(category: PluralCategory, row: Int)] = []
            var missing: [(category: PluralCategory, cells: [String])] = []
            for (position, category) in categories.enumerated() {
                let wanted = category ?? .other
                if let matchIndex = unmatched.firstIndex(where: { ($0.category ?? .other) == wanted }) {
                    let row = unmatched.remove(at: matchIndex)
                    matched.append((wanted, row.index))
                    let rendered = render(key: key, category: category, columns: columns, existing: row.cells, isFirst: position == 0,
                                          target: target)
                    if let update = diff(existing: row.cells, rendered: rendered) {
                        operations.append(.update(row: row.index, column: update.column, cells: update.cells))
                    }
                } else {
                    missing.append((wanted, render(key: key, category: category, columns: columns, existing: nil, isFirst: position == 0,
                                                   target: target)))
                }
            }
            // Rows for forms the key no longer has. Duplicate rows are left alone; the reader warns about them.
            let surplus = unmatched.filter { row in !categories.contains { ($0 ?? .other) == (row.category ?? .other) } }
            operations += surplus.map { .delete(row: $0.index) }
            guard !missing.isEmpty else { continue }
            guard let firstRow = matched.map(\.row).min() else {
                appended += missing.map(\.cells)
                continue
            }
            // Insert each new form after the row of the nearest smaller form, so forms stay in CLDR order.
            var runs: [Int: [[String]]] = [:]
            for item in missing {
                let anchor = matched.filter { $0.category < item.category }.max { $0.category < $1.category }?.row ?? (firstRow - 1)
                runs[anchor, default: []].append(item.cells)
            }
            for (anchor, rows) in runs { operations.append(.insertAfter(row: anchor, rows: rows)) }
        }

        var requests: [SheetRequest] = []
        operations.sort { $0.row != $1.row ? $0.row > $1.row : $0.rank < $1.rank }
        for operation in operations {
            switch operation {
            case .update(let row, let column, let cells):
                requests.append(.updateCells(sheetID: tab.sheetID, row: row, column: column, rows: [cells]))
            case .insertAfter(let row, let rows):
                requests.append(.insertRows(sheetID: tab.sheetID, at: row + 1, count: rows.count))
                requests.append(.updateCells(sheetID: tab.sheetID, row: row + 1, column: 0, rows: rows.map { $0.map { $0 } }))
            case .delete(let row):
                requests.append(.deleteRows(sheetID: tab.sheetID, start: row, end: row + 1))
            }
        }
        if !appended.isEmpty {
            // Keep new keys in a stable order: by key name.
            let keyColumn = columns.key
            appended.sort { SheetCodec.cell($0, keyColumn) < SheetCodec.cell($1, keyColumn) }
            requests.append(.appendRows(sheetID: tab.sheetID, rows: appended))
        }
        return requests
    }

    /// Plural rows a key needs: every form some project locale requires, plus forms that have text.
    static func pluralCategories(for key: StringKey, locales: [LocaleCode]) -> [PluralCategory] {
        var categories = Set<PluralCategory>([.other])
        for locale in locales { categories.formUnion(PluralRules.requiredCategories(for: locale)) }
        for translation in key.translations.values { categories.formUnion(translation.nonEmptyForms.keys) }
        return categories.sorted()
    }

    static func render(key: StringKey, category: PluralCategory?, columns: StringsColumns, existing: [String]?, isFirst: Bool,
                       target: Snapshot) -> [String]
    {
        var cells = existing ?? []
        let width = max(columns.width, cells.count)
        while cells.count < width { cells.append("") }
        func set(_ index: Int?, _ value: String) {
            guard let index else { return }
            cells[index] = value
        }
        set(columns.id, key.id.lowercased)
        set(columns.key, key.key)
        set(columns.description, key.description)
        set(columns.plural, category?.rawValue ?? "")
        for (locale, index) in columns.locales {
            cells[index] = key.translations[locale]?.forms[category ?? .other] ?? ""
        }
        set(columns.figma, key.contexts.map(\.url).joined(separator: "\n"))
        set(columns.tags, key.tags.joined(separator: ", "))
        set(columns.platforms, key.platforms.map(\.rawValue).joined(separator: ", "))
        while let last = cells.last, last.isEmpty, cells.count > columns.width { cells.removeLast() }
        return cells
    }

    /// The smallest contiguous block that differs, or nil when the row is unchanged.
    static func diff(existing: [String], rendered: [String]) -> (column: Int, cells: [String?])? {
        let width = max(existing.count, rendered.count)
        func value(_ row: [String], _ index: Int) -> String { index < row.count ? row[index] : "" }
        let changed = (0..<width).filter { value(existing, $0) != value(rendered, $0) }
        guard let first = changed.first, let last = changed.last else { return nil }
        return (first, (first...last).map { value(rendered, $0) })
    }

    // MARK: keyed tabs (_status, _context)

    static func keyedRequests(tab: TabInfo, grid: [[String]], header: [String], identity: ([String], [String: Int]) -> String,
                              owner: ([String], [String: Int]) -> UUID?, desired: [(identity: String, row: [String])],
                              touched: Set<UUID>) -> [SheetRequest]
    {
        let existingHeader = grid.first ?? header
        let columns = SheetCodec.headerIndexes(existingHeader)
        // Desired rows are in canonical header order; map them onto this sheet's column order.
        func arrange(_ row: [String]) -> [String] {
            var cells = Array(repeating: "", count: max(existingHeader.count, header.count))
            for (index, name) in header.enumerated() {
                cells[columns[name] ?? index] = row[index]
            }
            while let last = cells.last, last.isEmpty { cells.removeLast() }
            return cells
        }
        var wanted: [String: [String]] = [:]
        var wantedOrder: [String] = []
        for item in desired where wanted[item.identity] == nil {
            wanted[item.identity] = arrange(item.row)
            wantedOrder.append(item.identity)
        }
        var operations: [(row: Int, request: SheetRequest)] = []
        var present = Set<String>()
        for (index, row) in grid.enumerated().dropFirst() {
            guard let id = owner(row, columns), touched.contains(id) else { continue }
            let rowIdentity = identity(row, columns)
            if let desiredRow = wanted[rowIdentity], !present.contains(rowIdentity) {
                present.insert(rowIdentity)
                if let update = diff(existing: row, rendered: desiredRow) {
                    operations.append((index, .updateCells(sheetID: tab.sheetID, row: index, column: update.column, rows: [update.cells])))
                }
            } else {
                operations.append((index, .deleteRows(sheetID: tab.sheetID, start: index, end: index + 1)))
            }
        }
        var requests = operations.sorted { $0.row > $1.row }.map(\.request)
        let newRows = wantedOrder.filter { !present.contains($0) }.compactMap { wanted[$0] }
        if !newRows.isEmpty { requests.append(.appendRows(sheetID: tab.sheetID, rows: newRows)) }
        return requests
    }

    static func statusRows(target: Snapshot, touched: Set<UUID>) -> [(identity: String, row: [String])] {
        var rows: [(String, [String])] = []
        for key in target.keys where touched.contains(key.id) {
            for locale in target.settings.locales where locale != target.settings.sourceLocale {
                guard let translation = key.translations[locale], !translation.isEmpty else { continue }
                if translation.status == .approved && translation.sourceHash == nil { continue }
                let row = [key.id.lowercased, locale.rawValue, translation.status.rawValue, translation.hash, translation.sourceHash ?? "",
                           translation.updatedAt?.isoString ?? "", translation.updatedBy ?? ""]
                rows.append(("\(key.id.lowercased)|\(locale)", row))
            }
        }
        return rows
    }

    static func contextRows(target: Snapshot, touched: Set<UUID>) -> [(identity: String, row: [String])] {
        var rows: [(String, [String])] = []
        for key in target.keys where touched.contains(key.id) {
            for context in key.contexts {
                func number(_ value: Double?) -> String {
                    guard let value else { return "" }
                    return value.rounded() == value ? String(Int(value)) : String(value)
                }
                let siblings = JSONValue.array(context.siblingTexts.prefix(10).map { .string(String($0.prefix(200))) })
                    .serialized(style: .standard).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
                let row = [key.id.lowercased, context.url, context.fileKey, context.nodeId, context.pageName ?? "", context.frameName ?? "",
                           context.nodePath ?? "", number(context.width), number(context.height), number(context.fontSize),
                           context.siblingTexts.isEmpty ? "" : siblings, context.linkedAt?.isoString ?? "", context.linkedBy ?? ""]
                rows.append(("\(key.id.lowercased)|\(context.url)", row))
            }
        }
        return rows
    }

    static func historyRow(_ entry: HistoryEntry) -> [String] {
        [entry.date.isoString, entry.actor, entry.action.rawValue, entry.keyID?.lowercased ?? "", entry.key ?? "", entry.locale?.rawValue ?? "",
         entry.category?.rawValue ?? "", entry.before ?? "", entry.after ?? "", entry.note ?? ""]
    }
}
