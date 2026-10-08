import Foundation

/// Writes the visible `guidelines` and `glossary` tabs. Both are small, so a save rewrites the whole tab
/// in place (people's column widths and formatting stay), keeping rows in `guidelines` that Runa does not own.
enum GuidelinesSheet {
    /// Google Sheets refuses longer cell values.
    static let cellLimit = 50_000
    static let knownTopics: Set<String> = ["naming", "keytemplate", "keypattern", "style"]

    static func guidelinesGrid(_ guidelines: ProjectGuidelines, existing: [[String]]) -> [[String]] {
        var rows = [SheetLayout.guidelinesHeader]
        rows.append(["naming", "", guidelines.naming])
        rows.append(["keyTemplate", "", guidelines.keyTemplate])
        rows.append(["keyPattern", "", guidelines.keyPattern])
        for (locale, text) in guidelines.styleGuides.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !text.isEmpty {
            rows.append(["style", locale.rawValue, text])
        }
        let topic = (existing.first ?? []).firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "topic" } ?? 0
        for row in existing.dropFirst() where !row.allSatisfy(\.isEmpty) {
            if !knownTopics.contains(SheetCodec.cell(row, topic).trimmingCharacters(in: .whitespaces).lowercased()) { rows.append(row) }
        }
        return rows
    }

    /// One column per target language of the project, then any other language a term has.
    static func glossaryGrid(_ guidelines: ProjectGuidelines, settings: ProjectSettings) -> [[String]] {
        var locales = settings.targetLocales
        for term in guidelines.glossary {
            for locale in term.translations.keys.sorted(by: { $0.rawValue < $1.rawValue }) where !locales.contains(locale) { locales.append(locale) }
        }
        var rows = [SheetLayout.glossaryHeader + locales.map(\.rawValue)]
        for term in guidelines.glossary {
            rows.append([term.term, term.note] + locales.map { term.translations[$0] ?? "" })
        }
        return rows
    }

    /// Requests that make `tab` hold exactly `grid`, creating the tab when it does not exist.
    static func requests(tab title: String, grid: [[String]], decoded: DecodedSheet, newSheetID: () -> Int) -> [SheetRequest] {
        let existing = decoded.grids[title] ?? []
        let height = max(grid.count, existing.count)
        let width = max(grid.map(\.count).max() ?? 0, existing.map(\.count).max() ?? 0, 1)
        let padded: [[String?]] = (0..<height).map { row in
            (0..<width).map { column in row < grid.count && column < grid[row].count ? grid[row][column] : "" }
        }
        var requests: [SheetRequest] = []
        let sheetID: Int
        if let tab = decoded.info.tab(title) {
            sheetID = tab.sheetID
            if height > tab.rowCount { requests.append(.insertRows(sheetID: sheetID, at: tab.rowCount, count: height - tab.rowCount)) }
            if width > tab.columnCount { requests.append(.insertColumns(sheetID: sheetID, at: tab.columnCount, count: width - tab.columnCount)) }
        } else {
            sheetID = newSheetID()
            requests.append(.addSheet(sheetID: sheetID, title: title, hidden: false, rowCount: max(height, 20), columnCount: max(width, 3)))
        }
        requests.append(.updateCells(sheetID: sheetID, row: 0, column: 0, rows: padded))
        return requests
    }

    static func checkCellSizes(_ guidelines: ProjectGuidelines) throws {
        let texts = [("The naming guide", guidelines.naming), ("The key template", guidelines.keyTemplate), ("The key pattern", guidelines.keyPattern)]
            + guidelines.styleGuides.map { ("The \($0.key.displayName()) style guide", $0.value) }
        for (name, text) in texts where text.count > cellLimit {
            throw BackendError.invalidData("\(name) is \(text.count) characters; a sheet cell holds at most \(cellLimit).")
        }
    }
}
