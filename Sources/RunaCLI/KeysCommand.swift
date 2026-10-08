import ArgumentParser
import Foundation
import RunaCore

struct Keys: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search, add, edit and delete keys.",
        subcommands: [List.self, Search.self, Show.self, Add.self, Set.self, Delete.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List keys.")
        @OptionGroup var project: ProjectOptions
        @Option(help: "Only keys missing in this language.") var missing: String?
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let snapshot = try await project.load().backend.pull()
            var keys = snapshot.keys.sorted { $0.key < $1.key }
            if let missing {
                guard let locale = LocaleCode(rawValue: missing) else { throw ValidationError("\(missing) is not a language code") }
                keys = keys.filter { snapshot.status(of: $0, locale: locale) == .missing }
            }
            try Keys.print(keys, snapshot: snapshot, json: json)
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Fuzzy search over key names, text in every language and descriptions.")
        @OptionGroup var project: ProjectOptions
        @Argument(help: "What to look for.") var query: String
        @Option(help: "Maximum results.") var limit = 20
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let snapshot = try await project.load().backend.pull()
            try Keys.print(KeySearch.search(query, in: snapshot, limit: limit), snapshot: snapshot, json: json)
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one key in every language.")
        @OptionGroup var project: ProjectOptions
        @Argument(help: "Key name.") var key: String

        func run() async throws {
            let snapshot = try await project.load().backend.pull()
            guard let found = snapshot.key(named: key) else { throw ValidationError("No key named \(key)") }
            Swift.print(try Output.json(KeySummary(found, in: snapshot)))
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a key with its source-language text.")
        @OptionGroup var project: ProjectOptions
        @Argument(help: "Key name in the project's key format (see `runa guidelines`).") var key: String
        @Option(help: "Source-language text. Placeholders: {name}, {count:int}, {price:double}.") var text: String?
        @Option(help: "Context for translators.") var description = ""
        @Option(name: .customLong("one"), help: "Plural key: the singular form.") var one: String?
        @Option(name: .customLong("other"), help: "Plural key: the general form.") var other: String?
        @Option(parsing: .upToNextOption, help: "Tags.") var tags: [String] = []
        @Option(parsing: .upToNextOption, help: "Only these platforms: ios android web.") var platforms: [String] = []

        func run() async throws {
            if let problem = KeyNaming.problem(with: key) { throw ValidationError(problem) }
            let loaded = try project.load()
            let snapshot = try await loaded.backend.pull()
            let rules = snapshot.namingRules
            if let problem = rules.problem(with: key) { throw ValidationError("\(problem) See `runa guidelines`.") }
            let source = snapshot.settings.sourceLocale
            let translation: Translation
            let plural = one != nil || other != nil
            if plural {
                guard let other else { throw ValidationError("Plural keys need --other") }
                translation = Translation(forms: [.one: one ?? "", .other: other].filter { !$0.value.isEmpty })
            } else {
                guard let text, !text.isEmpty else { throw ValidationError("Pass --text, or --one and --other for a plural key") }
                translation = Translation(text)
            }
            var chosen = try platforms.map { raw in
                guard let platform = Platform(rawValue: raw.lowercased()) else { throw ValidationError("Unknown platform \(raw)") }
                return platform
            }
            if chosen.isEmpty, let implied = rules.impliedPlatforms(for: key) { chosen = implied }
            let newKey = StringKey(key: key, description: description, tags: tags, platforms: chosen, isPlural: plural,
                                   translations: [source: translation])
            if let problem = rules.platformProblem(for: newKey) { throw ValidationError(problem) }
            let result = try await loaded.backend.push([.addKey(newKey)], basedOn: snapshot, context: loaded.context(note: "cli"))
            if let conflict = result.conflicts.first { throw ValidationError("Not added: \(conflict.kind == .duplicateKey ? "the key already exists" : "\(conflict.kind)")") }
            Swift.print("Added \(key).")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a key's text in one language.")
        @OptionGroup var project: ProjectOptions
        @Argument(help: "Key name.") var key: String
        @Option(help: "Language code. Defaults to the source language.") var locale: String?
        @Option(help: "Plural form: zero one two few many other.") var form: String?
        @Option(help: "The text.") var text: String
        @Flag(help: "Mark as a machine draft that needs approval in the app.") var draft = false

        func run() async throws {
            let loaded = try project.load()
            let snapshot = try await loaded.backend.pull()
            guard let found = snapshot.key(named: key) else { throw ValidationError("No key named \(key)") }
            let target = try locale.map { raw in
                guard let code = LocaleCode(rawValue: raw) else { throw ValidationError("\(raw) is not a language code") }
                return code
            } ?? snapshot.settings.sourceLocale
            let category = try form.map { raw in
                guard let category = PluralCategory(rawValue: raw) else { throw ValidationError("Unknown plural form \(raw)") }
                return category
            } ?? .other
            let change = Change.setValue(id: found.id, locale: target, category: category, value: text, status: draft ? .machine : .approved)
            let result = try await loaded.backend.push([change], basedOn: snapshot, context: loaded.context(note: "cli"))
            if let conflict = result.conflicts.first { throw ValidationError("Not saved: \(conflict.kind.rawValue)") }
            Swift.print("Saved \(key) [\(target)].")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a key in every language.")
        @OptionGroup var project: ProjectOptions
        @Argument(help: "Key name.") var key: String
        @Flag(help: "Confirm the deletion.") var yes = false

        func run() async throws {
            guard yes else { throw ValidationError("This deletes \(key) in every language. Pass --yes to confirm.") }
            let loaded = try project.load()
            let snapshot = try await loaded.backend.pull()
            guard let found = snapshot.key(named: key) else { throw ValidationError("No key named \(key)") }
            _ = try await loaded.backend.push([.deleteKey(id: found.id)], basedOn: snapshot, context: loaded.context(note: "cli"))
            Swift.print("Deleted \(key).")
        }
    }

    static func print(_ keys: [StringKey], snapshot: Snapshot, json: Bool) throws {
        if json {
            Swift.print(try Output.json(keys.map { KeySummary($0, in: snapshot) }))
            return
        }
        let source = snapshot.settings.sourceLocale
        let width = min(48, (keys.map(\.key.count).max() ?? 0) + 2)
        for key in keys {
            let text = key.isPlural ? (key.value(for: source, .other) ?? "") : (key.value(for: source) ?? "")
            let marks = snapshot.settings.targetLocales.map { locale -> String in
                switch snapshot.status(of: key, locale: locale) {
                case .missing: return Output.red("○")
                case .machine, .needsReview: return Output.yellow("◐")
                case .approved: return Output.green("●")
                }
            }.joined()
            Swift.print("\(key.key.padding(toLength: width, withPad: " ", startingAt: 0)) \(marks)  \(Output.dim(String(text.prefix(60))))")
        }
        if keys.isEmpty { Swift.print(Output.dim("No keys.")) }
    }
}
