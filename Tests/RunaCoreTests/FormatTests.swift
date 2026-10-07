import Foundation
import Testing
@testable import RunaCore

/// Exports the sample project, reads the files back, and checks the import planner sees
/// nothing to change. This proves placeholders, plurals and escaping survive each format.
func assertRoundTrip(_ files: [ExportedFile], directory: String = "", flavor: String, sourceLocale: LocaleCode = "en",
                     snapshot: Snapshot = Sample.snapshot, sourceLocation: SourceLocation = #_sourceLocation) throws
{
    var entries: [ImportedEntry] = []
    for file in files {
        let path = "/project/\(directory)\(file.relativePath)"
        entries += try FormatDetector.parse(path: path, data: file.contents, defaultLocale: sourceLocale).entries
    }
    let plan = ImportPlanner.plan(entries, against: snapshot)
    let changed = plan.items.filter { $0.kind != .same }
    #expect(changed.isEmpty, "\(flavor): \(changed.map { "\($0.kind) \($0.keyName) [\($0.locale)] \($0.imported) vs \($0.current ?? [:])" })",
            sourceLocation: sourceLocation)
    #expect(!plan.items.isEmpty, sourceLocation: sourceLocation)
}

@Suite struct XCStringsTests {
    @Test func exportsCatalog() throws {
        let result = XCStringsFormat.export(Sample.snapshot)
        let text = result.files[0].text
        #expect(text.hasPrefix("{\n  \"sourceLanguage\" : \"en\","))
        #expect(text.contains("\"value\" : \"%1$@, välkommen till %2$@!\"") == false)
        #expect(text.contains("\"value\" : \"Hej %1$@, välkommen till %2$@!\""))
        #expect(text.contains("\"state\" : \"needs_review\""))
        #expect(text.contains("\"shouldTranslate\" : false"))
        #expect(text.contains("\"few\" : {"))
        #expect(!text.contains("android.only"))
        #expect(!text.hasSuffix("\n"))
    }

    @Test func roundTrips() throws {
        try assertRoundTrip(XCStringsFormat.export(Sample.snapshot).files, flavor: "xcstrings")
    }

    @Test func approvedOnlyLeavesOutDrafts() {
        let text = XCStringsFormat.export(Sample.snapshot, options: ExportOptions(includeUnapproved: false)).files[0].text
        #expect(!text.contains("Hej %1$@"))
    }

    /// Xcode's own tool rewrites a catalog in its canonical layout. If our output is already in
    /// that layout, opening the file in Xcode will not create a diff.
    @Test func matchesXcodeLayout() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runa-xcstrings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = directory.appendingPathComponent("Localizable.xcstrings")
        let exported = XCStringsFormat.export(Sample.snapshot).files[0].contents
        try exported.write(to: catalog)

        // An empty .stringsdata from an empty Swift file, so sync rewrites without adding keys.
        let swiftFile = directory.appendingPathComponent("Empty.swift")
        try Data("import Foundation\n".utf8).write(to: swiftFile)
        let out = directory.appendingPathComponent("out")
        try run("/usr/bin/xcrun", ["xcstringstool", "extract", "--modern-localizable-strings", swiftFile.path, "-o", out.path])
        let stringsdata = try FileManager.default.contentsOfDirectory(atPath: out.path).map { out.appendingPathComponent($0).path }
        try run("/usr/bin/xcrun", ["xcstringstool", "sync", catalog.path, "--skip-marking-strings-stale", "--stringsdata"] + stringsdata)
        let rewritten = try Data(contentsOf: catalog)
        #expect(String(decoding: rewritten, as: UTF8.self) == String(decoding: exported, as: UTF8.self))
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(arguments.joined(separator: " "))")
    }
}

@Suite struct AndroidTests {
    @Test func exportsResources() throws {
        let result = AndroidXMLFormat.export(Sample.snapshot)
        let paths = result.files.map(\.relativePath)
        #expect(paths == ["values/strings.xml", "values-sv/strings.xml", "values-pl/strings.xml"])
        let base = result.files[0].text
        #expect(base.contains("<string name=\"checkout_title\">Checkout</string>"))
        #expect(base.contains("<!-- Title on the checkout screen -->"))
        #expect(base.contains("<string name=\"app_name\" translatable=\"false\">Runa</string>"))
        #expect(base.contains("<item quantity=\"one\">%1$d item</item>"))
        #expect(base.contains("<string name=\"greeting\">Hello %1$s, welcome to %2$s!</string>"))
        #expect(base.contains("It\\'s \\\"quoted\\\" &amp; <b>bold</b>\\nsecond line"))
        #expect(base.contains("<string name=\"android_only\">"))
        #expect(base.contains("100% secure"))
        #expect(base.contains("%1$d%% done"))
        let swedish = result.files[1].text
        #expect(swedish.contains("%1$d %% klart"))
        #expect(!swedish.contains("app_name"))
    }

    @Test func roundTrips() throws {
        try assertRoundTrip(AndroidXMLFormat.export(Sample.snapshot).files, directory: "app/src/main/res/", flavor: "android")
    }

    @Test func escapingRoundTrips() throws {
        for text in ["  two  spaces ", "@not a reference", "?attr", "tab\there", "back\\slash", "a < b > c & d", "It's", "Tom & <b>Jerry</b>"] {
            let xml = "<resources><string name=\"k\">\(AndroidXMLFormat.escape(text))</string></resources>"
            let (entries, _) = try AndroidXMLFormat.parse(Data(xml.utf8), locale: "en", file: "strings.xml")
            #expect(entries.first?.forms[.other] == text, "\(text)")
        }
    }

    @Test func parsesRealWorldFile() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">
            <!-- Shown on the welcome screen -->
            <string name="welcome">Welcome, <xliff:g id="name">%1$s</xliff:g>!</string>
            <string name="quoted">"  keep   spaces  "</string>
            <string name="collapsed">  many
                lines  </string>
            <string name="styled">Tap <b>here</b></string>
            <string name="raw" formatted="false">100%s</string>
            <string-array name="planets"><item>Mercury</item></string-array>
            <plurals name="songs">
                <item quantity="one">%d song</item>
                <item quantity="other">%d songs</item>
            </plurals>
        </resources>
        """
        let (entries, warnings) = try AndroidXMLFormat.parse(Data(xml.utf8), locale: "en", file: "values/strings.xml")
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        #expect(byKey["welcome"]?.forms[.other] == "Welcome, %1$s!")
        #expect(byKey["welcome"]?.comment == "Shown on the welcome screen")
        #expect(byKey["quoted"]?.forms[.other] == "  keep   spaces  ")
        #expect(byKey["collapsed"]?.forms[.other] == "many lines")
        #expect(byKey["styled"]?.forms[.other] == "Tap <b>here</b>")
        #expect(byKey["raw"]?.forms[.other] == "100%%s")
        #expect(byKey["songs"]?.forms == [.one: "%d song", .other: "%d songs"])
        #expect(warnings.count == 1)
    }
}

@Suite struct AppleStringsTests {
    @Test func exportsStringsAndStringsdict() {
        let result = AppleStringsFormat.export(Sample.snapshot)
        let paths = result.files.map(\.relativePath)
        #expect(paths.contains("en.lproj/Localizable.strings"))
        #expect(paths.contains("en.lproj/Localizable.stringsdict"))
        let strings = result.files.first { $0.relativePath == "en.lproj/Localizable.strings" }!.text
        #expect(strings.contains("/* Title on the checkout screen */\n\"checkout.title\" = \"Checkout\";"))
        #expect(strings.contains("\"quote.text\" = \"It's \\\"quoted\\\" & <b>bold</b>\\nsecond line\";"))
        let dict = result.files.first { $0.relativePath == "pl.lproj/Localizable.stringsdict" }!.text
        #expect(dict.contains("<string>%#@count@</string>"))
        #expect(dict.contains("<key>few</key>"))
    }

    @Test func roundTrips() throws {
        try assertRoundTrip(AppleStringsFormat.export(Sample.snapshot).files, flavor: "apple-strings")
    }

    @Test func parsesLegacySyntax() throws {
        let text = """
        // line comment
        /* Greeting */
        "hello" = "Hello \\"%@\\"\\n";
        unquoted_key = "value";
        "only key";
        """
        let entries = try AppleStringsFormat.parseStrings(Data(text.utf8), locale: "en", file: "en.lproj/Localizable.strings")
        #expect(entries.map(\.key) == ["hello", "unquoted_key", "only key"])
        #expect(entries[0].forms[.other] == "Hello \"%@\"\n")
        #expect(entries[0].comment == "Greeting")
    }
}

@Suite struct WebTests {
    @Test func exportsFlatI18next() throws {
        let files = I18nextFormat.export(Sample.snapshot).files
        #expect(files.map(\.relativePath) == ["en.json", "sv.json", "pl.json"])
        let english = files[0].text
        #expect(english.contains("\"cart.items_one\": \"{{count}} item\""))
        #expect(english.contains("\"greeting\": \"Hello {{name}}, welcome to {{place}}!\""))
        #expect(english.hasSuffix("}\n"))
        #expect(files[2].text.contains("\"cart.items_many\""))
    }

    @Test func exportsNestedI18next() throws {
        let options = ExportOptions(nested: true, filePattern: "{locale}/translation.json")
        let files = I18nextFormat.export(Sample.snapshot, options: options).files
        #expect(files[0].relativePath == "en/translation.json")
        let english = try JSONValue.parse(files[0].contents)
        #expect(english["checkout"]?["title"]?.stringValue == "Checkout")
        #expect(english["cart"]?["items_other"]?.stringValue == "{{count}} items")
    }

    @Test func nestedReportsClashes() {
        let (_, warnings) = I18nextFormat.nest([("a.b", "1"), ("a.b.c", "2")])
        #expect(warnings.count == 1)
    }

    @Test func i18nextRoundTrips() throws {
        try assertRoundTrip(I18nextFormat.export(Sample.snapshot).files, directory: "locales/", flavor: "i18next")
        let nested = I18nextFormat.export(Sample.snapshot, options: ExportOptions(nested: true, filePattern: "{locale}/translation.json"))
        try assertRoundTrip(nested.files, directory: "locales/", flavor: "i18next nested")
    }

    @Test func exportsICU() throws {
        let files = ICUJSONFormat.export(Sample.snapshot).files
        let polish = files[2].text
        #expect(polish.contains("{count, plural, one {# produkt} few {# produkty} many {# produktów} other {# produktu}}"))
        let english = files[0].text
        #expect(english.contains("\"quote.text\": \"It''s \\\"quoted\\\" & <b>bold</b>\\nsecond line\""))
    }

    @Test func icuRoundTrips() throws {
        // ICU has no fixed decimal precision and names every argument, so compare on a sample
        // that only uses what ICU can express.
        try assertRoundTrip(ICUJSONFormat.export(Sample.snapshot).files, directory: "messages/", flavor: "icu")
    }

    @Test func icuQuotedHashStaysLiteral() throws {
        let json = #"{"k": "{n, plural, one {'#'1 is # item} other {# items}}"}"#
        let (entries, _) = try ICUJSONFormat.parse(Data(json.utf8), locale: "en", file: "en.json")
        #expect(entries[0].forms[.one] == "#1 is {n:int} item")
    }
}

@Suite struct ImportPlannerTests {
    @Test func bucketsChanges() throws {
        let xml = """
        <resources>
            <string name="checkout_title">Kassan</string>
            <string name="greeting">Hej %1$s, välkommen till %2$s!</string>
            <string name="progress">%1$d och %2$s klart</string>
            <string name="new_key">Ny</string>
            <string name="quote_text">Citat</string>
            <string name="cart_items">Inte plural</string>
        </resources>
        """
        let (entries, _) = try AndroidXMLFormat.parse(Data(xml.utf8), locale: "sv", file: "values-sv/strings.xml")
        let plan = ImportPlanner.plan(entries, against: Sample.snapshot)
        func kind(_ key: String) -> ImportItemKind? { plan.items.first { $0.keyName == key }?.kind }
        #expect(kind("checkout.title") == .conflict)
        #expect(kind("greeting") == .same)
        #expect(kind("progress") == .mismatch)
        #expect(kind("new_key") == .newKey)
        #expect(kind("quote.text") == .newTranslation)
        #expect(kind("cart.items") == .mismatch)
        #expect(plan.newLocales.isEmpty)

        var resolved = plan
        resolved.resolveConflicts(.useFile)
        let changes = resolved.changes(projectLocales: ["en", "sv", "pl"])
        #expect(changes.count == 3)
        #expect(changes.contains(.setValue(id: Sample.checkoutID, locale: "sv", category: .other, value: "Kassan", status: .approved)))
        #expect(changes.contains(.setValue(id: Sample.quoteID, locale: "sv", category: .other, value: "Citat", status: .approved)))
    }

    @Test func reportsNewLocales() throws {
        let json = #"{"checkout": {"title": "Kasse"}}"#
        let entries = try I18nextFormat.parse(Data(json.utf8), locale: "de", file: "de.json")
        let plan = ImportPlanner.plan(entries, against: Sample.snapshot)
        #expect(plan.newLocales == ["de"])
        #expect(plan.changes(projectLocales: ["en", "sv", "pl"]).isEmpty)
        #expect(plan.changes(projectLocales: ["en", "sv", "pl", "de"]).count == 1)
    }

    @Test func newKeysUseSourceLocalePlaceholderNames() throws {
        let english = #"{"invite": "{{who}} invited you"}"#
        let swedish = #"{"invite": "{{who}} bjöd in dig"}"#
        var entries = try I18nextFormat.parse(Data(english.utf8), locale: "en", file: "en.json")
        entries += try I18nextFormat.parse(Data(swedish.utf8), locale: "sv", file: "sv.json")
        let plan = ImportPlanner.plan(entries, against: Sample.snapshot)
        let changes = plan.changes(projectLocales: ["en", "sv", "pl"])
        guard case .addKey(let key) = changes.first else {
            Issue.record("Expected a new key")
            return
        }
        #expect(key.translations["en"]?.value == "{who} invited you")
        #expect(key.translations["sv"]?.value == "{who} bjöd in dig")
    }

    @Test func detectsFormats() {
        #expect(FormatDetector.detect(path: "/a/res/values-sv/strings.xml")?.locale == "sv")
        #expect(FormatDetector.detect(path: "/a/res/values/strings.xml")?.isDefaultLocale == true)
        #expect(FormatDetector.detect(path: "/a/sv.lproj/Localizable.strings")?.locale == "sv")
        #expect(FormatDetector.detect(path: "/a/locales/de/translation.json")?.locale == "de")
        #expect(FormatDetector.detect(path: "/a/locales/fr.json")?.locale == "fr")
        #expect(FormatDetector.detect(path: "/a/App/Localizable.xcstrings")?.kind == .xcstrings)
    }
}
