import Foundation
import Testing
@testable import RunaCore

/// Builds a fresh, empty project (source en, plus sv) on a backend.
protocol BackendFixture: Sendable {
    var name: String { get }
    func make() async throws -> any StringsBackend
}

struct LocalJSONFixture: BackendFixture {
    let name = "local-json"
    func make() async throws -> any StringsBackend {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runa-\(UUID().uuidString).runa.json")
        return try LocalJSONBackend.create(at: url, settings: ProjectSettings(name: "Test", sourceLocale: "en", locales: ["sv"]))
    }
}

struct SheetsFixture: BackendFixture {
    let name = "google-sheets"
    func make() async throws -> any StringsBackend {
        let api = InMemorySheetsAPI()
        await api.create(id: "sheet")
        let backend = GoogleSheetsBackend(spreadsheetID: "sheet", api: api)
        _ = try await backend.setUp(projectName: "Test", sourceLocale: "en", locales: ["sv"], context: PushContext(actor: "setup"))
        return backend
    }
}

let fixtures: [any BackendFixture] = [LocalJSONFixture(), SheetsFixture()]
let alice = PushContext(actor: "Alice", date: Date(timeIntervalSince1970: 1_790_000_000))
let bob = PushContext(actor: "Bob", date: Date(timeIntervalSince1970: 1_790_000_100))

@Suite struct BackendContractTests {
    @Test(arguments: fixtures.map(\.name)) func startsEmpty(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let snapshot = try await backend.pull()
        #expect(snapshot.settings.sourceLocale == "en")
        #expect(snapshot.settings.locales == ["en", "sv"])
        #expect(snapshot.keys.isEmpty)
        #expect(snapshot.warnings.isEmpty)
    }

    @Test(arguments: fixtures.map(\.name)) func addsAndReadsKeys(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let base = try await backend.pull()
        let plain = StringKey(key: "checkout.title", description: "Screen title", tags: ["checkout"], platforms: [.ios, .web],
                              translations: ["en": Translation("Checkout"), "sv": Translation("Kassa")])
        let plural = StringKey(key: "cart.items", isPlural: true, translations: [
            "en": Translation(forms: [.one: "{count:int} item", .other: "{count:int} items"]),
        ])
        let result = try await backend.push([.addKey(plain), .addKey(plural)], basedOn: base, context: alice)
        #expect(result.conflicts.isEmpty)
        #expect(result.applied.count == 2)

        let pulled = try await backend.pull()
        #expect(pulled.keys.count == 2)
        let readPlain = try #require(pulled[id: plain.id])
        #expect(readPlain.key == "checkout.title")
        #expect(readPlain.description == "Screen title")
        #expect(readPlain.tags == ["checkout"])
        #expect(readPlain.platforms == [.ios, .web])
        #expect(readPlain.value(for: "sv") == "Kassa")
        #expect(pulled.status(of: readPlain, locale: "sv") == .approved)
        let readPlural = try #require(pulled[id: plural.id])
        #expect(readPlural.isPlural)
        #expect(readPlural.translations["en"]?.forms == [.one: "{count:int} item", .other: "{count:int} items"])
        #expect(pulled.status(of: readPlural, locale: "sv") == .missing)
    }

    @Test(arguments: fixtures.map(\.name)) func tracksReviewStatus(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let key = StringKey(key: "greeting", translations: ["en": Translation("Hello")])
        var snapshot = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice).snapshot

        snapshot = try await backend.push([.setValue(id: key.id, locale: "sv", value: "Hej", status: .machine)], basedOn: snapshot,
                                          context: alice).snapshot
        var pulled = try await backend.pull()
        #expect(pulled.status(of: pulled[id: key.id]!, locale: "sv") == .machine)

        snapshot = try await backend.push([.setStatus(id: key.id, locale: "sv", status: .approved)], basedOn: pulled, context: bob).snapshot
        pulled = try await backend.pull()
        #expect(pulled.status(of: pulled[id: key.id]!, locale: "sv") == .approved)

        // Changing the source text makes the Swedish translation need review.
        _ = try await backend.push([.setValue(id: key.id, locale: "en", value: "Hello there")], basedOn: pulled, context: alice)
        pulled = try await backend.pull()
        #expect(pulled.status(of: pulled[id: key.id]!, locale: "sv") == .needsReview)
        #expect(pulled.coverage(for: "sv").needsReview == 1)
        _ = snapshot
    }

    @Test(arguments: fixtures.map(\.name)) func detectsConflictsPerCell(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let key = StringKey(key: "title", translations: ["en": Translation("Title"), "sv": Translation("Titel")])
        let base = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice).snapshot

        // Bob changes Swedish.
        _ = try await backend.push([.setValue(id: key.id, locale: "sv", value: "Rubrik")], basedOn: base, context: bob)

        // Alice, still on the old snapshot, edits Swedish (conflict) and English (fine).
        let result = try await backend.push([
            .setValue(id: key.id, locale: "sv", value: "Titeln"),
            .setValue(id: key.id, locale: "en", value: "The title"),
        ], basedOn: base, context: alice)
        #expect(result.conflicts.count == 1)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.kind == .valueChanged)
        #expect(conflict.base == "Titel")
        #expect(conflict.remote == "Rubrik")
        #expect(conflict.local == "Titeln")
        let pulled = try await backend.pull()
        #expect(pulled[id: key.id]?.value(for: "sv") == "Rubrik")
        #expect(pulled[id: key.id]?.value(for: "en") == "The title")

        // Writing the same value someone else already wrote is not a conflict.
        let same = try await backend.push([.setValue(id: key.id, locale: "sv", value: "Rubrik")], basedOn: base, context: alice)
        #expect(same.conflicts.isEmpty)
    }

    @Test(arguments: fixtures.map(\.name)) func renamesAndDeletes(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let first = StringKey(key: "a", translations: ["en": Translation("A")])
        let second = StringKey(key: "b", translations: ["en": Translation("B")])
        var snapshot = try await backend.push([.addKey(first), .addKey(second)], basedOn: try await backend.pull(), context: alice).snapshot

        var metadata = first.metadata
        metadata.key = "a.renamed"
        metadata.description = "Now with a description"
        snapshot = try await backend.push([.updateKey(id: first.id, metadata: metadata)], basedOn: snapshot, context: alice).snapshot
        var pulled = try await backend.pull()
        #expect(pulled[id: first.id]?.key == "a.renamed")
        #expect(pulled[id: first.id]?.description == "Now with a description")

        // Renaming onto an existing name is refused.
        metadata.key = "b"
        let clash = try await backend.push([.updateKey(id: first.id, metadata: metadata)], basedOn: pulled, context: alice)
        #expect(clash.conflicts.first?.kind == .duplicateKey)

        _ = try await backend.push([.deleteKey(id: second.id)], basedOn: pulled, context: alice)
        pulled = try await backend.pull()
        #expect(pulled.keys.map(\.key) == ["a.renamed"])
        _ = snapshot
    }

    @Test(arguments: fixtures.map(\.name)) func deletingAKeySomeoneEditedConflicts(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let key = StringKey(key: "k", translations: ["en": Translation("K")])
        let base = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice).snapshot
        _ = try await backend.push([.setValue(id: key.id, locale: "sv", value: "K på svenska")], basedOn: base, context: bob)
        let result = try await backend.push([.deleteKey(id: key.id)], basedOn: base, context: alice)
        #expect(result.conflicts.first?.kind == .keyModified)
        #expect(try await backend.pull().keys.count == 1)
    }

    @Test(arguments: fixtures.map(\.name)) func managesLocales(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let key = StringKey(key: "k", translations: ["en": Translation("Hi"), "sv": Translation("Hej")])
        _ = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice)

        var snapshot = try await backend.addLocale("pl", context: alice)
        #expect(snapshot.settings.locales == ["en", "sv", "pl"])
        await #expect(throws: BackendError.localeExists("pl")) { try await backend.addLocale("pl", context: alice) }

        snapshot = try await backend.push([.setValue(id: key.id, locale: "pl", value: "Cześć")], basedOn: snapshot, context: alice).snapshot
        #expect(try await backend.pull()[id: key.id]?.value(for: "pl") == "Cześć")

        snapshot = try await backend.removeLocale("sv", context: alice)
        #expect(snapshot.settings.locales == ["en", "pl"])
        #expect(snapshot[id: key.id]?.translations["sv"] == nil)
        #expect(snapshot[id: key.id]?.value(for: "pl") == "Cześć")
        await #expect(throws: BackendError.cannotRemoveSourceLocale) { try await backend.removeLocale("en", context: alice) }

        // Values for a locale that is not in the project are refused, not lost silently.
        let refused = try await backend.push([.setValue(id: key.id, locale: "de", value: "Hallo")], basedOn: snapshot, context: alice)
        #expect(refused.conflicts.first?.kind == .unknownLocale)
    }

    @Test(arguments: fixtures.map(\.name)) func pluralFormsFollowLocales(_ name: String) async throws {
        let backend = try await fixture(name).make()
        var snapshot = try await backend.addLocale("pl", context: alice)
        let key = StringKey(key: "files", isPlural: true, translations: [
            "en": Translation(forms: [.one: "{count:int} file", .other: "{count:int} files"]),
        ])
        snapshot = try await backend.push([.addKey(key)], basedOn: snapshot, context: alice).snapshot
        let changes: [Change] = [
            .setValue(id: key.id, locale: "pl", category: .one, value: "{count:int} plik", status: .approved),
            .setValue(id: key.id, locale: "pl", category: .few, value: "{count:int} pliki", status: .approved),
            .setValue(id: key.id, locale: "pl", category: .many, value: "{count:int} plików", status: .approved),
        ]
        snapshot = try await backend.push(changes, basedOn: snapshot, context: alice).snapshot
        var pulled = try await backend.pull()
        #expect(pulled.status(of: pulled[id: key.id]!, locale: "pl") == .missing, "the other form is still missing")
        _ = try await backend.push([.setValue(id: key.id, locale: "pl", category: .other, value: "{count:int} pliku", status: .approved)],
                                   basedOn: pulled, context: alice)
        pulled = try await backend.pull()
        #expect(pulled.status(of: pulled[id: key.id]!, locale: "pl") == .approved)
        #expect(pulled[id: key.id]?.translations["pl"]?.forms.count == 4)
        _ = snapshot
    }

    @Test(arguments: fixtures.map(\.name)) func storesFigmaContext(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let key = StringKey(key: "k", translations: ["en": Translation("Pay now")])
        let snapshot = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice).snapshot
        let context = FigmaContext(url: "https://www.figma.com/design/AbC123/Shop?node-id=12-34", fileKey: "AbC123", nodeId: "12:34",
                                   frameId: "10:1", pageName: "Checkout", frameName: "Summary", nodePath: "Summary/Footer/Button", width: 120, height: 44,
                                   fontSize: 15, siblingTexts: ["Total", "Back"], linkedAt: alice.date, linkedBy: "Alice")
        _ = try await backend.push([.setContexts(id: key.id, contexts: [context])], basedOn: snapshot, context: alice)
        let read = try #require(try await backend.pull()[id: key.id]?.contexts.first)
        #expect(read == context)
    }

    @Test(arguments: fixtures.map(\.name)) func recordsHistory(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let key = StringKey(key: "k", translations: ["en": Translation("One")])
        var snapshot = try await backend.push([.addKey(key)], basedOn: try await backend.pull(),
                                              context: PushContext(actor: "Alice", note: "figma", date: alice.date)).snapshot
        snapshot = try await backend.push([.setValue(id: key.id, locale: "en", value: "Two")], basedOn: snapshot, context: bob).snapshot
        _ = try await backend.addLocale("de", context: alice)
        let history = try await backend.history(keyID: key.id, limit: 10)
        #expect(history.map(\.action) == [.setValue, .addKey])
        #expect(history[0].before == "One")
        #expect(history[0].after == "Two")
        #expect(history[0].actor == "Bob")
        #expect(history[1].note == "figma")
        #expect(try await backend.history(keyID: nil, limit: 1).first?.action == .addLocale)
        _ = snapshot
    }

    @Test(arguments: fixtures.map(\.name)) func noOpPushWritesNothing(_ name: String) async throws {
        let backend = try await fixture(name).make()
        let key = StringKey(key: "k", translations: ["en": Translation("Same")])
        let snapshot = try await backend.push([.addKey(key)], basedOn: try await backend.pull(), context: alice).snapshot
        _ = try await backend.push([.setValue(id: key.id, locale: "en", value: "Same")], basedOn: snapshot, context: alice)
        #expect(try await backend.history(keyID: key.id, limit: 10).count == 1)
    }

    func fixture(_ name: String) -> any BackendFixture {
        fixtures.first { $0.name == name }!
    }
}
