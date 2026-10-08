import _CryptoExtras
import Crypto
import Foundation
import Testing
@testable import RunaCore

@Suite struct GoogleSheetsTests {
    func makeBackend() async throws -> (GoogleSheetsBackend, InMemorySheetsAPI) {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet")
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        _ = try await backend.setUp(projectName: "Shop", sourceLocale: "en", locales: ["sv"], context: alice)
        return (backend, api)
    }

    @Test func setUpLaysOutABlankSpreadsheet() async throws {
        let (backend, api) = try await makeBackend()
        let info = try await api.spreadsheet("sheet")
        #expect(info.tabs.map(\.title) == ["strings", "_meta", "_status", "_context", "_history", "guidelines", "glossary"])
        #expect(info.tabs.filter(\.hidden).count == 4)
        #expect(await api.grid(id: "sheet", tab: "guidelines") == [["topic", "language", "value"], ["naming"], ["keyTemplate"], ["keyPattern"]])
        #expect(await api.grid(id: "sheet", tab: "glossary") == [["term", "note", "sv"]])
        #expect(await api.grid(id: "sheet", tab: "strings") == [["_id", "key", "description", "plural", "en", "sv", "figma", "tags", "platforms"]])
        #expect(await api.grid(id: "sheet", tab: "_meta") == [["key", "value"], ["schemaVersion", "1"], ["projectName", "Shop"], ["sourceLocale", "en"]])
        let inspection = try await backend.inspect()
        #expect(inspection.state == .ready(locales: ["en", "sv"], keyCount: 0))
        #expect(try await backend.pull().settings.name == "Shop")
    }

    @Test func adoptsAHandMadeSheet() async throws {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet", tabs: ["strings": [["key", "en", "sv", "notes"], ["hello", "Hello", "Hej", "keep me"], ["bye", "Bye"]]])
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        let inspection = try await backend.inspect()
        guard case .adoptable(let locales, let keyCount, let missing) = inspection.state else {
            Issue.record("Expected an adoptable sheet, got \(inspection.state)")
            return
        }
        #expect(locales == ["en", "sv"])
        #expect(keyCount == 2)
        #expect(missing.contains("_status"))

        // Reading works before setup, with ids derived from key names.
        let before = try await backend.pull()
        #expect(before[id: TextHash.uuid(forKey: "hello")]?.value(for: "sv") == "Hej")

        let snapshot = try await backend.setUp(sourceLocale: "en", context: alice)
        #expect(snapshot.keys.count == 2)
        let grid = await api.grid(id: "sheet", tab: "strings")
        #expect(grid[0] == ["key", "en", "sv", "notes", "_id", "description", "plural", "figma", "tags", "platforms"])
        #expect(grid[1][3] == "keep me")

        // The first edit writes the derived id into the row and keeps the extra column.
        let id = TextHash.uuid(forKey: "bye")
        _ = try await backend.push([.setValue(id: id, locale: "sv", value: "Hejdå")], basedOn: snapshot, context: alice)
        let after = await api.grid(id: "sheet", tab: "strings")
        #expect(after[2][2] == "Hejdå")
        #expect(after[2][4] == id.lowercased)
        #expect(after[1][3] == "keep me")
    }

    @Test func handEditsInTheSheetReadAsApproved() async throws {
        let (backend, api) = try await makeBackend()
        let key = StringKey(key: "k", translations: ["en": Translation("Hello")])
        var snapshot = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice).snapshot
        snapshot = try await backend.push([.setValue(id: key.id, locale: "sv", value: "Hallå", status: .machine)], basedOn: snapshot,
                                          context: alice).snapshot
        #expect(try await backend.pull().status(of: snapshot[id: key.id]!, locale: "sv") == .machine)

        // A translator fixes the machine draft directly in Google Sheets.
        try await api.setCell(id: "sheet", tab: "strings", row: 1, column: 5, value: "Hej")
        let pulled = try await backend.pull()
        #expect(pulled[id: key.id]?.value(for: "sv") == "Hej")
        #expect(pulled.status(of: pulled[id: key.id]!, locale: "sv") == .approved)
    }

    @Test func survivesRowsInsertedByPeople() async throws {
        let (backend, api) = try await makeBackend()
        let first = StringKey(key: "first", translations: ["en": Translation("First")])
        let second = StringKey(key: "second", translations: ["en": Translation("Second")])
        let snapshot = try await backend.push([.addKey(first), .addKey(second)], basedOn: try await backend.pull(), context: alice).snapshot

        // Someone inserts a row at the top between our pull and our push.
        try await api.insertRow(id: "sheet", tab: "strings", at: 1, values: ["", "manual.key", "", "", "Manual"])
        _ = try await backend.push([.setValue(id: second.id, locale: "sv", value: "Andra")], basedOn: snapshot, context: alice)
        let pulled = try await backend.pull()
        #expect(pulled[id: second.id]?.value(for: "sv") == "Andra")
        #expect(pulled[id: first.id]?.value(for: "sv") == nil)
        #expect(pulled.key(named: "manual.key")?.value(for: "en") == "Manual")
    }

    @Test func newPluralRowsStayNextToTheirKey() async throws {
        let (backend, api) = try await makeBackend()
        let plural = StringKey(key: "a.files", isPlural: true, translations: ["en": Translation(forms: [.one: "1 file", .other: "{n:int} files"])])
        let later = StringKey(key: "b.later", translations: ["en": Translation("Later")])
        var snapshot = try await backend.push([.addKey(plural), .addKey(later)], basedOn: try await backend.pull(), context: alice).snapshot
        snapshot = try await backend.addLocale("pl", context: alice)
        _ = try await backend.push([.setValue(id: plural.id, locale: "pl", category: .few, value: "{n:int} pliki", status: .approved)],
                                   basedOn: snapshot, context: alice)
        let grid = await api.grid(id: "sheet", tab: "strings")
        let keyColumn = 1
        let pluralColumn = 3
        #expect(grid.dropFirst().map { $0[keyColumn] } == ["a.files", "a.files", "a.files", "a.files", "b.later"])
        #expect(grid.dropFirst().map { $0.count > pluralColumn ? $0[pluralColumn] : "" } == ["one", "few", "many", "other", ""])
        #expect(grid[2][6] == "{n:int} pliki")
    }

    @Test func oneBatchPerPush() async throws {
        let (backend, api) = try await makeBackend()
        let before = await api.batchCount
        let keys = (0..<20).map { StringKey(key: "key.\($0)", translations: ["en": Translation("Value \($0)")]) }
        _ = try await backend.push(keys.map(Change.addKey), basedOn: try await backend.pull(), context: alice)
        #expect(await api.batchCount == before + 1)
    }

    @Test func readsFigmaLinksTypedByPeople() async throws {
        let (backend, api) = try await makeBackend()
        let key = StringKey(key: "k", translations: ["en": Translation("Pay")])
        _ = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice)
        try await api.setCell(id: "sheet", tab: "strings", row: 1, column: 6, value: "https://www.figma.com/design/XyZ/App?node-id=1-2")
        let context = try #require(try await backend.pull()[id: key.id]?.contexts.first)
        #expect(context.fileKey == "XyZ")
        #expect(context.nodeId == "1:2")
    }

    @Test func formulasAreWrittenAsText() {
        let json = SheetRequest.updateCells(sheetID: 1, row: 0, column: 0, rows: [["=SUM(A1)", nil]]).json.serialized(style: .standard)
        #expect(json.contains("\"stringValue\": \"=SUM(A1)\""))
        #expect(json.contains("\"fields\": \"userEnteredValue\""))
    }

    @Test func parsesSpreadsheetLinks() {
        #expect(GoogleSheetsBackend.spreadsheetID(from: "https://docs.google.com/spreadsheets/d/1AbC_def-GHIjklMNOpqrSTUvwxYZ0123456789/edit#gid=0")
                == "1AbC_def-GHIjklMNOpqrSTUvwxYZ0123456789")
        #expect(GoogleSheetsBackend.spreadsheetID(from: "1AbC_def-GHIjklMNOpqrSTUvwxYZ0123456789") == "1AbC_def-GHIjklMNOpqrSTUvwxYZ0123456789")
        #expect(GoogleSheetsBackend.spreadsheetID(from: "not a link") == nil)
    }

    @Test func signsServiceAccountAssertions() throws {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let credentials = ServiceAccountCredentials(privateKeyID: "kid-1", privateKey: key.pkcs8PEMRepresentation,
                                                    clientEmail: "runa@project.iam.gserviceaccount.com")
        // Round-trips through the JSON a user would drop on the app.
        let parsed = try ServiceAccountCredentials(json: try credentials.jsonData())
        #expect(parsed.clientEmail == credentials.clientEmail)

        let jwt = try ServiceAccountTokenProvider.assertion(credentials: parsed, scopes: [ServiceAccountTokenProvider.spreadsheetsScope],
                                                             now: Date(timeIntervalSince1970: 1_800_000_000))
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ part: String) throws -> JSONValue {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return try JSONValue.parse(Data(base64Encoded: base64)!)
        }
        let header = try decode(parts[0])
        let claims = try decode(parts[1])
        #expect(header["alg"]?.stringValue == "RS256")
        #expect(header["kid"]?.stringValue == "kid-1")
        #expect(claims["iss"]?.stringValue == "runa@project.iam.gserviceaccount.com")
        #expect(claims["aud"]?.stringValue == "https://oauth2.googleapis.com/token")
        #expect(claims["exp"] == .number(1_800_003_600))

        var signature = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while signature.count % 4 != 0 { signature += "=" }
        let valid = key.publicKey.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: Data(base64Encoded: signature)!),
                                                   for: Data("\(parts[0]).\(parts[1])".utf8), padding: .insecurePKCS1v1_5)
        #expect(valid)
    }

    @Test func rejectsFilesThatAreNotServiceAccounts() {
        #expect(throws: BackendError.self) { try ServiceAccountCredentials(json: Data(#"{"type": "authorized_user"}"#.utf8)) }
        #expect(throws: BackendError.self) { try ServiceAccountCredentials(json: Data("hello".utf8)) }
    }

    @Test func readsGuidelinesTypedInTheSheetAndKeepsPeoplesRows() async throws {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet")
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        _ = try await backend.setUp(sourceLocale: "en", locales: ["sv", "de"], context: alice)
        try await api.setCell(id: "sheet", tab: "guidelines", row: 1, column: 2, value: "  Use feature_description_type.\n")
        try await api.setCell(id: "sheet", tab: "guidelines", row: 2, column: 2, value: "{feature}_{description}_{type:title|text|action}")
        try await api.insertRow(id: "sheet", tab: "guidelines", at: 4, values: ["Style", "SV", "Informellt"])
        try await api.insertRow(id: "sheet", tab: "guidelines", at: 5, values: ["owner", "", "Design team"])
        try await api.insertRow(id: "sheet", tab: "glossary", at: 1, values: ["League", "", "Liga", "Liga"])
        try await api.insertRow(id: "sheet", tab: "glossary", at: 2, values: ["", "", "ignored"])

        var snapshot = try await backend.pull()
        #expect(snapshot.guidelines.naming == "Use feature_description_type.")
        #expect(snapshot.guidelines.keyTemplate == "{feature}_{description}_{type:title|text|action}")
        #expect(snapshot.guidelines.styleGuides == ["sv": "Informellt"])
        #expect(snapshot.guidelines.glossary.map(\.term) == ["League"])
        #expect(snapshot.guidelines.glossary[0].translations == ["sv": "Liga", "de": "Liga"])
        #expect(snapshot.warnings.isEmpty)

        var edited = snapshot.guidelines
        edited.styleGuides["de"] = "Du-Form"
        snapshot = try await backend.setGuidelines(edited, basedOn: snapshot.guidelines, context: alice)
        let grid = await api.grid(id: "sheet", tab: "guidelines")
        #expect(grid.contains(["owner", "", "Design team"]), "rows Runa does not own survive a save")
        #expect(grid.contains(["style", "de", "Du-Form"]))
        #expect(snapshot.guidelines.styleGuides == ["sv": "Informellt", "de": "Du-Form"])
        // The glossary did not change, so its tab was not rewritten.
        #expect(await api.grid(id: "sheet", tab: "glossary")[1] == ["League", "", "Liga", "Liga"])
    }

    @Test func createsGuidelineTabsInOlderSheetsOnFirstSave() async throws {
        // A sheet set up before guidelines existed: every Runa tab except the two visible guideline tabs.
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet", tabs: [
            "strings": [SheetLayout.stringsHeader(locales: ["en", "sv"])],
            "_meta": [SheetLayout.metaHeader, ["schemaVersion", "1"], ["sourceLocale", "en"]],
            "_status": [SheetLayout.statusHeader], "_context": [SheetLayout.contextHeader], "_history": [SheetLayout.historyHeader],
        ])
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        let before = try await backend.pull()
        #expect(before.guidelines.isEmpty)
        let terms = (1...30).map { GlossaryTerm(term: "Term \($0)", translations: ["sv": "Term \($0)"]) }
        let after = try await backend.setGuidelines(ProjectGuidelines(naming: "Name keys by feature.", glossary: terms), basedOn: before.guidelines,
                                                    context: alice)
        #expect(after.guidelines.naming == "Name keys by feature.")
        #expect(after.guidelines.glossary.count == 30)
        let tabs = try await api.spreadsheet("sheet").tabs
        #expect(tabs.contains { $0.title == "glossary" && !$0.hidden })
        #expect(tabs.contains { $0.title == "guidelines" && !$0.hidden })
    }

    @Test func growsTheGuidelinesTabWhenNeeded() async throws {
        let (backend, api) = try await makeBackend()
        let base = try await backend.pull().guidelines
        let codes = ["sv", "de", "fr", "es", "it", "nl", "da", "fi", "nb", "pl", "pt", "cs", "sk", "hu", "ro", "bg", "el", "tr", "ru", "uk",
                     "ja", "ko", "zh", "ar", "he"]
        var guides: [LocaleCode: String] = [:]
        for code in codes { guides[LocaleCode(rawValue: code)!] = "Guide \(code)" }
        let saved = try await backend.setGuidelines(ProjectGuidelines(styleGuides: guides), basedOn: base, context: alice)
        #expect(saved.guidelines.styleGuides.count == 25)
        #expect(await api.grid(id: "sheet", tab: "guidelines").count == 29)
    }

    @Test func refusesTextLongerThanACell() async throws {
        let (backend, _) = try await makeBackend()
        let base = try await backend.pull().guidelines
        let tooLong = ProjectGuidelines(naming: String(repeating: "x", count: 50_001))
        await #expect(throws: BackendError.self) { try await backend.setGuidelines(tooLong, basedOn: base, context: alice) }
    }

    @Test func warnsAboutBrokenRulesInTheSheet() async throws {
        let (backend, api) = try await makeBackend()
        try await api.setCell(id: "sheet", tab: "guidelines", row: 2, column: 2, value: "{feature")
        let snapshot = try await backend.pull()
        #expect(snapshot.warnings.map(\.location) == ["guidelines tab"])
    }
}

@Suite struct SheetWriterAlignmentTests {
    @Test func addsColumnsMissingFromOlderSheets() async throws {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet")
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        _ = try await backend.setUp(sourceLocale: "en", context: alice)
        // Simulate a sheet created before frameId existed: drop the last header cell.
        let header = await api.grid(id: "sheet", tab: "_context")[0]
        #expect(header.last == "frameId")
        try await api.setCell(id: "sheet", tab: "_context", row: 0, column: header.count - 1, value: "")

        let key = StringKey(key: "k", translations: ["en": Translation("Pay")])
        let snapshot = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice).snapshot
        let context = FigmaContext(url: "https://www.figma.com/design/F/App?node-id=1-2", fileKey: "F", nodeId: "1:2", frameId: "1:1")
        _ = try await backend.push([.setContexts(id: key.id, contexts: [context])], basedOn: snapshot, context: alice)

        let grid = await api.grid(id: "sheet", tab: "_context")
        #expect(grid[0].last == "frameId")
        #expect(grid[1][grid[0].count - 1] == "1:1")
        #expect(try await backend.pull()[id: key.id]?.contexts.first?.frameId == "1:1")
    }

    @Test func figmaLinksGoOnTheFirstRowOfAPluralKey() async throws {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet")
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        var snapshot = try await backend.setUp(sourceLocale: "en", context: alice)
        let key = StringKey(key: "files", isPlural: true, translations: ["en": Translation(forms: [.one: "1 file", .other: "{n:int} files"])])
        snapshot = try await backend.push([.addKey(key)], basedOn: snapshot, context: alice).snapshot
        let context = FigmaContext(url: "https://www.figma.com/design/F/App?node-id=3-4", fileKey: "F", nodeId: "3:4")
        _ = try await backend.push([.setContexts(id: key.id, contexts: [context])], basedOn: snapshot, context: alice)
        let grid = await api.grid(id: "sheet", tab: "strings")
        let figmaColumn = grid[0].firstIndex(of: "figma")!
        let cells = grid.dropFirst().map { $0.count > figmaColumn ? $0[figmaColumn] : "" }
        #expect(cells == [context.url, ""])
        #expect(try await backend.pull()[id: key.id]?.contexts.map(\.url) == [context.url])
    }

    @Test func neverFreezesEveryRowOfANewTab() {
        func frozenRows(_ rowCount: Int) -> JSONValue? {
            SheetRequest.addSheet(sheetID: 7, title: "_meta", hidden: true, rowCount: rowCount, columnCount: 2)
                .json["addSheet"]?["properties"]?["gridProperties"]?["frozenRowCount"]
        }
        // Google rejects a grid whose rows are all frozen; this is what broke setUp on a live sheet.
        #expect(frozenRows(1) == nil)
        #expect(frozenRows(2) == .number(1))
    }

    @Test func hiddenTabsKeepAFrozenHeader() async throws {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet")
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        _ = try await backend.setUp(sourceLocale: "en", context: alice)
        let info = try await api.spreadsheet("sheet")
        for tab in info.tabs where tab.hidden {
            #expect(tab.rowCount > 1, Comment(rawValue: "\(tab.title) needs room for a frozen header row"))
        }
    }

    @Test func configWithNoTargetsYetIsValid() throws {
        // `runa init` writes `targets:` with every entry commented out, which YAML reads as null.
        let commentedOut = #"{"backend": {"type": "google-sheets", "spreadsheet": "abc"}, "targets": null}"#
        let missing = #"{"backend": {"type": "google-sheets", "spreadsheet": "abc"}}"#
        for json in [commentedOut, missing] {
            let config = try JSONDecoder().decode(RunaConfig.self, from: Data(json.utf8))
            #expect(config.targets.isEmpty)
            #expect(config.backend.spreadsheet == "abc")
        }
    }

    @Test func twinTreatsTabNamesCaseInsensitivelyLikeGoogle() async throws {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet", tabs: ["Strings": [["key"]]])
        await #expect(throws: BackendError.self) {
            try await api.batchUpdate("sheet", requests: [.addSheet(sheetID: 9, title: "strings", hidden: false, rowCount: 10, columnCount: 5)])
        }
    }
}
