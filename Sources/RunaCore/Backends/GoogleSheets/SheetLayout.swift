import Foundation

/// Tab and column names from docs/SHEET_FORMAT.md.
public enum SheetLayout {
    public static let stringsTab = "strings"
    public static let metaTab = "_meta"
    public static let statusTab = "_status"
    public static let contextTab = "_context"
    public static let historyTab = "_history"
    public static let hiddenTabs = [metaTab, statusTab, contextTab, historyTab]

    public static let idColumn = "_id"
    public static let keyColumn = "key"
    public static let descriptionColumn = "description"
    public static let pluralColumn = "plural"
    public static let figmaColumn = "figma"
    public static let tagsColumn = "tags"
    public static let platformsColumn = "platforms"
    static let descriptionAliases = ["description", "comment", "context"]
    static let reserved: Set<String> = ["_id", "key", "description", "comment", "context", "plural", "figma", "tags", "platforms"]

    public static let metaHeader = ["key", "value"]
    public static let statusHeader = ["id", "locale", "status", "hash", "sourceHash", "updatedAt", "updatedBy"]
    public static let contextHeader = ["id", "url", "fileKey", "nodeId", "page", "frame", "path", "width", "height", "fontSize",
                                       "siblings", "linkedAt", "linkedBy", "frameId"]
    public static let historyHeader = ["ts", "actor", "action", "id", "key", "locale", "plural", "before", "after", "note"]

    public static func header(for tab: String) -> [String] {
        switch tab {
        case metaTab: metaHeader
        case statusTab: statusHeader
        case contextTab: contextHeader
        case historyTab: historyHeader
        default: []
        }
    }

    /// Header for a new `strings` tab.
    public static func stringsHeader(locales: [LocaleCode]) -> [String] {
        [idColumn, keyColumn, descriptionColumn, pluralColumn] + locales.map(\.rawValue) + [figmaColumn, tagsColumn, platformsColumn]
    }
}

/// Where each known column sits in the `strings` tab.
struct StringsColumns: Sendable {
    var id: Int?
    var key: Int
    var description: Int?
    var plural: Int?
    var figma: Int?
    var tags: Int?
    var platforms: Int?
    var locales: [(locale: LocaleCode, index: Int)]
    var width: Int

    init(header: [String]) throws {
        var key: Int?
        var locales: [(LocaleCode, Int)] = []
        for (index, raw) in header.enumerated() {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            switch lower {
            case SheetLayout.idColumn: id = id ?? index
            case SheetLayout.keyColumn: key = key ?? index
            case _ where SheetLayout.descriptionAliases.contains(lower): description = description ?? index
            case SheetLayout.pluralColumn: plural = plural ?? index
            case SheetLayout.figmaColumn: figma = figma ?? index
            case SheetLayout.tagsColumn: tags = tags ?? index
            case SheetLayout.platformsColumn: platforms = platforms ?? index
            default:
                if let locale = LocaleCode(rawValue: name), locale.isKnownLanguage, !locales.contains(where: { $0.0 == locale }) {
                    locales.append((locale, index))
                }
            }
        }
        guard let key else {
            throw BackendError.invalidData("The \"\(SheetLayout.stringsTab)\" tab needs a \"key\" column in its first row.")
        }
        self.key = key
        self.locales = locales
        self.width = header.count
    }

    func index(of locale: LocaleCode) -> Int? { locales.first { $0.locale == locale }?.index }
}

/// A row of the `strings` tab as found in the sheet.
struct StringsRow: Sendable {
    var index: Int
    var id: UUID
    var hasStoredID: Bool
    var category: PluralCategory?
    var cells: [String]
}

struct DecodedSheet: Sendable {
    var info: SpreadsheetInfo
    var snapshot: Snapshot
    var columns: StringsColumns
    var stringsRows: [StringsRow]
    /// Raw grids by tab name.
    var grids: [String: [[String]]]
    var missingTabs: [String]
}

enum SheetCodec {
    static func cell(_ row: [String], _ index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index]
    }

    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Reads a spreadsheet into a snapshot. Fails if there is no `strings` tab with a `key` column.
    static func decode(info: SpreadsheetInfo, grids: [String: [[String]]]) throws -> DecodedSheet {
        guard let strings = grids[SheetLayout.stringsTab] else {
            throw BackendError.invalidData("The spreadsheet has no \"\(SheetLayout.stringsTab)\" tab yet. Set it up from Runa first.")
        }
        let header = strings.first ?? []
        let columns = try StringsColumns(header: header)
        var warnings: [SnapshotWarning] = []

        // _meta
        var meta: [String: String] = [:]
        for row in (grids[SheetLayout.metaTab] ?? []).dropFirst() where row.count >= 2 { meta[row[0]] = row[1] }
        let headerLocales = columns.locales.map(\.locale)
        var sourceLocale = meta["sourceLocale"].flatMap(LocaleCode.init(rawValue:)) ?? headerLocales.first
        if let declared = sourceLocale, !headerLocales.contains(declared) {
            warnings.append(SnapshotWarning("The source language \(declared) has no column; using \(headerLocales.first?.rawValue ?? "none")"))
            sourceLocale = headerLocales.first
        }
        guard let sourceLocale else {
            throw BackendError.invalidData("The \"strings\" tab has no language columns. Add a column named with a language code such as \"en\".")
        }
        let settings = ProjectSettings(name: meta["projectName"].flatMap { $0.isEmpty ? nil : $0 } ?? info.title, sourceLocale: sourceLocale,
                                       locales: headerLocales,
                                       schemaVersion: meta["schemaVersion"].flatMap(Int.init) ?? ProjectSettings.currentSchemaVersion)

        // strings rows, grouped by id in sheet order
        var rows: [StringsRow] = []
        var order: [UUID] = []
        var grouped: [UUID: [StringsRow]] = [:]
        for (index, cells) in strings.enumerated().dropFirst() {
            let key = cell(cells, columns.key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            let rawID = cell(cells, columns.id).trimmingCharacters(in: .whitespaces)
            let storedID = UUID(uuidString: rawID)
            let id = storedID ?? TextHash.uuid(forKey: key)
            let pluralText = cell(cells, columns.plural).trimmingCharacters(in: .whitespaces).lowercased()
            var category: PluralCategory?
            if !pluralText.isEmpty {
                category = PluralCategory(rawValue: pluralText)
                if category == nil { warnings.append(SnapshotWarning("Unknown plural form \"\(pluralText)\"", location: "row \(index + 1)")) }
            }
            let row = StringsRow(index: index, id: id, hasStoredID: storedID != nil, category: category, cells: cells)
            rows.append(row)
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(row)
        }

        // _status
        let statusGrid = grids[SheetLayout.statusTab] ?? []
        let statusColumns = headerIndexes(statusGrid.first ?? SheetLayout.statusHeader)
        var statusRows: [String: [String]] = [:]
        for row in statusGrid.dropFirst() {
            let id = cell(row, statusColumns["id"]).lowercased()
            let locale = LocaleCode(rawValue: cell(row, statusColumns["locale"]))
            guard !id.isEmpty, let locale else { continue }
            statusRows["\(id)|\(locale)"] = row
        }

        // _context
        let contextGrid = grids[SheetLayout.contextTab] ?? []
        let contextColumns = headerIndexes(contextGrid.first ?? SheetLayout.contextHeader)
        var contexts: [UUID: [FigmaContext]] = [:]
        for row in contextGrid.dropFirst() {
            guard let id = UUID(uuidString: cell(row, contextColumns["id"])) else { continue }
            let url = cell(row, contextColumns["url"])
            guard !url.isEmpty else { continue }
            let fallback = FigmaContext(url: url)
            var context = FigmaContext(url: url, fileKey: nonEmpty(cell(row, contextColumns["fileKey"])) ?? fallback?.fileKey ?? "",
                                       nodeId: nonEmpty(cell(row, contextColumns["nodeId"])) ?? fallback?.nodeId ?? "")
            context.pageName = nonEmpty(cell(row, contextColumns["page"]))
            context.frameName = nonEmpty(cell(row, contextColumns["frame"]))
            context.nodePath = nonEmpty(cell(row, contextColumns["path"]))
            context.width = Double(cell(row, contextColumns["width"]))
            context.height = Double(cell(row, contextColumns["height"]))
            context.fontSize = Double(cell(row, contextColumns["fontSize"]))
            if let data = nonEmpty(cell(row, contextColumns["siblings"]))?.data(using: .utf8),
                case .array(let items)? = try? JSONValue.parse(data)
            {
                context.siblingTexts = items.compactMap(\.stringValue)
            }
            context.linkedAt = Date(isoString: cell(row, contextColumns["linkedAt"]))
            context.linkedBy = nonEmpty(cell(row, contextColumns["linkedBy"]))
            context.frameId = nonEmpty(cell(row, contextColumns["frameId"]))
            contexts[id, default: []].append(context)
        }

        // Keys
        var keys: [StringKey] = []
        var seenNames: [String: Int] = [:]
        for id in order {
            let group = grouped[id] ?? []
            guard let first = group.first else { continue }
            func firstNonEmpty(_ column: Int?) -> String {
                group.lazy.map { cell($0.cells, column) }.first { !$0.isEmpty } ?? ""
            }
            let name = cell(first.cells, columns.key).trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlural = group.contains { $0.category != nil }
            var key = StringKey(id: id, key: name, description: firstNonEmpty(columns.description), tags: list(firstNonEmpty(columns.tags)),
                                platforms: list(firstNonEmpty(columns.platforms)).compactMap { Platform(rawValue: $0.lowercased()) },
                                isPlural: isPlural)
            for (locale, column) in columns.locales {
                var forms: [PluralCategory: String] = [:]
                var seenCategories = Set<PluralCategory>()
                for row in group {
                    let category = row.category ?? .other
                    guard seenCategories.insert(category).inserted else { continue }
                    let text = cell(row.cells, column)
                    if !text.isEmpty { forms[category] = text }
                }
                guard !forms.isEmpty else { continue }
                var translation = Translation(forms: forms)
                if locale != sourceLocale, let status = statusRows["\(id.lowercased)|\(locale)"] {
                    let recordedHash = cell(status, statusColumns["hash"])
                    if recordedHash == translation.hash {
                        translation.status = TranslationStatus(rawValue: cell(status, statusColumns["status"])) ?? .approved
                        translation.sourceHash = nonEmpty(cell(status, statusColumns["sourceHash"]))
                    }
                    translation.updatedAt = Date(isoString: cell(status, statusColumns["updatedAt"]))
                    translation.updatedBy = nonEmpty(cell(status, statusColumns["updatedBy"]))
                }
                key.translations[locale] = translation
            }
            var keyContexts = contexts[id] ?? []
            for row in group {
                for url in list(cell(row.cells, columns.figma)) where !keyContexts.contains(where: { $0.url == url }) {
                    if let context = FigmaContext(url: url) { keyContexts.append(context) }
                }
            }
            key.contexts = keyContexts
            if let previous = seenNames[name] {
                warnings.append(SnapshotWarning("\"\(name)\" appears more than once (also on row \(previous + 1))", location: "row \(first.index + 1)"))
            } else {
                seenNames[name] = first.index
            }
            let duplicateCategories = Dictionary(grouping: group, by: { $0.category ?? .other }).filter { $0.value.count > 1 }
            for (category, duplicates) in duplicateCategories {
                warnings.append(SnapshotWarning("\"\(name)\" has \(duplicates.count) rows for \(isPlural ? category.rawValue : "its value"); the first is used",
                                                location: "row \(duplicates[1].index + 1)"))
            }
            keys.append(key)
        }

        let missing = SheetLayout.hiddenTabs.filter { grids[$0] == nil }
        let snapshot = Snapshot(settings: settings, keys: keys, fetchedAt: Date(), warnings: warnings)
        return DecodedSheet(info: info, snapshot: snapshot, columns: columns, stringsRows: rows, grids: grids, missingTabs: missing)
    }

    static func headerIndexes(_ header: [String]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for (index, name) in header.enumerated() where indexes[name] == nil { indexes[name] = index }
        return indexes
    }

    static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    static func decodeHistory(_ grid: [[String]]) -> [HistoryEntry] {
        let columns = headerIndexes(grid.first ?? SheetLayout.historyHeader)
        return grid.dropFirst().compactMap { row in
            guard let date = Date(isoString: cell(row, columns["ts"])),
                let action = HistoryAction(rawValue: cell(row, columns["action"]))
            else { return nil }
            return HistoryEntry(date: date, actor: cell(row, columns["actor"]), action: action,
                                keyID: UUID(uuidString: cell(row, columns["id"])), key: nonEmpty(cell(row, columns["key"])),
                                locale: LocaleCode(rawValue: cell(row, columns["locale"])),
                                category: PluralCategory(rawValue: cell(row, columns["plural"])),
                                before: nonEmpty(cell(row, columns["before"])), after: nonEmpty(cell(row, columns["after"])),
                                note: nonEmpty(cell(row, columns["note"])))
        }
    }
}
