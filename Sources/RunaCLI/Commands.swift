import ArgumentParser
import Foundation
import RunaCore

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a runa.yml in this folder.")

    @Option(help: "Google Sheets link or id.")
    var spreadsheet: String?

    @Option(name: .customLong("local"), help: "Use a local .runa.json file instead of Google Sheets.")
    var localPath: String?

    @Flag(help: "Overwrite an existing runa.yml.")
    var force = false

    func run() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(RunaConfig.fileName)
        if FileManager.default.fileExists(atPath: url.path), !force {
            throw ValidationError("runa.yml already exists. Pass --force to overwrite it.")
        }
        try RunaConfig.template(spreadsheet: spreadsheet, localPath: localPath).write(to: url, atomically: true, encoding: .utf8)
        print("Created runa.yml. Uncomment the targets you need, then run `runa pull`.")
    }
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Prepare the backend: lay out an empty Google Sheet or create a local file.",
        discussion: "Safe to run on a sheet that already has a \"strings\" tab: missing columns and tabs are added, data is kept.")

    @OptionGroup var project: ProjectOptions

    @Option(name: .long, help: "Source language, for example en.")
    var source: String = "en"

    @Option(name: .long, parsing: .upToNextOption, help: "Other languages, for example sv de.")
    var locales: [String] = []

    @Option(name: .long, help: "Project name shown in the app.")
    var name: String?

    func run() async throws {
        guard let sourceLocale = LocaleCode(rawValue: source) else { throw ValidationError("\(source) is not a language code") }
        let others = try locales.map { raw -> LocaleCode in
            guard let locale = LocaleCode(rawValue: raw) else { throw ValidationError("\(raw) is not a language code") }
            return locale
        }
        let loaded = try project.load()
        let snapshot: Snapshot
        switch loaded.backend {
        case let sheets as GoogleSheetsBackend:
            snapshot = try await sheets.setUp(projectName: name, sourceLocale: sourceLocale, locales: others, context: loaded.context(note: "cli setup"))
        case let local as LocalJSONBackend:
            if FileManager.default.fileExists(atPath: local.url.path) {
                snapshot = try await local.pull()
            } else {
                let settings = ProjectSettings(name: name ?? "Strings", sourceLocale: sourceLocale, locales: others)
                snapshot = try await LocalJSONBackend.create(at: local.url, settings: settings).pull()
            }
        default:
            throw ValidationError("This backend does not need setup.")
        }
        print("Ready: \(snapshot.settings.name), \(snapshot.keys.count) keys, languages \(snapshot.settings.locales.map(\.rawValue).joined(separator: ", ")).")
    }
}

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write every target in runa.yml from the backend.")

    @OptionGroup var project: ProjectOptions

    @Flag(help: "Show what would change without writing files.")
    var dryRun = false

    func run() async throws {
        let loaded = try project.load()
        guard !loaded.config.targets.isEmpty else {
            throw ValidationError("runa.yml has no targets. Uncomment at least one under `targets:`.")
        }
        let snapshot = try await loaded.backend.pull()
        for warning in snapshot.warnings { Output.warn(warning.description) }
        let report = try Exporter.write(snapshot, config: loaded.config, root: loaded.root, dryRun: dryRun)
        for warning in report.warnings { Output.warn(warning) }
        for path in report.written { print("  \(dryRun ? "would write" : "wrote") \(path)") }
        let verb = dryRun ? "would change" : "changed"
        print("\(snapshot.keys.count) keys, \(snapshot.settings.locales.count) languages. \(report.written.count) files \(verb), \(report.unchanged.count) unchanged.")
        let incomplete = snapshot.settings.locales.map(snapshot.coverage).filter { !$0.isComplete }
        if !incomplete.isEmpty {
            print(Output.yellow("Missing translations: ") + incomplete.map { "\($0.locale) \($0.missing)" }.joined(separator: ", ")
                + Output.dim(" (run `runa check` for details)"))
        }
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fail when translations are missing. Use it in CI.",
        discussion: "Exit status 1 when any key is missing in a checked language, or with --approved, when anything is not approved.")

    @OptionGroup var project: ProjectOptions

    @Option(name: .long, parsing: .upToNextOption, help: "Only check these languages.")
    var locale: [String] = []

    @Flag(help: "Also fail on machine drafts and translations that need review.")
    var approved = false

    @Flag(help: "Print JSON.")
    var json = false

    func run() async throws {
        let loaded = try project.load()
        let snapshot = try await loaded.backend.pull()
        let locales = locale.isEmpty ? snapshot.settings.locales : locale.compactMap(LocaleCode.init(rawValue:))
        var problems: [String: [String: String]] = [:]
        for key in snapshot.keys.sorted(by: { $0.key < $1.key }) {
            for locale in locales {
                let status = snapshot.status(of: key, locale: locale)
                if status == .missing || (approved && status != .approved) {
                    problems[key.key, default: [:]][locale.rawValue] = status.rawValue
                }
            }
        }
        if json {
            struct Report: Encodable {
                var ok: Bool
                var problems: [String: [String: String]]
            }
            print(try Output.json(Report(ok: problems.isEmpty, problems: problems)))
        } else {
            print(Output.bold(snapshot.settings.name))
            for locale in locales {
                print(Output.coverageLine(snapshot.coverage(for: locale), source: locale == snapshot.settings.sourceLocale))
            }
            if !problems.isEmpty {
                print("")
                for key in problems.keys.sorted() {
                    let detail = problems[key]!.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                    print("  \(key)  \(Output.dim(detail))")
                }
            }
        }
        if !problems.isEmpty { throw ExitCode(1) }
    }
}

struct Locales: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, add or remove languages.", subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show languages and how complete they are.")
        @OptionGroup var project: ProjectOptions

        func run() async throws {
            let snapshot = try await project.load().backend.pull()
            for locale in snapshot.settings.locales {
                print(Output.coverageLine(snapshot.coverage(for: locale), source: locale == snapshot.settings.sourceLocale)
                      + Output.dim("  \(locale.displayName())"))
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a language.")
        @OptionGroup var project: ProjectOptions
        @Argument(help: "Language code, for example de or pt-BR.") var code: String

        func run() async throws {
            guard let locale = LocaleCode(rawValue: code), locale.isKnownLanguage else { throw ValidationError("\(code) is not a known language code") }
            let loaded = try project.load()
            let snapshot = try await loaded.backend.addLocale(locale, context: loaded.context(note: "cli"))
            let forms = PluralRules.requiredCategories(for: locale).map(\.rawValue).joined(separator: ", ")
            print("Added \(locale.displayName()). \(snapshot.keys.count) keys to translate. Plural forms: \(forms).")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a language and its translations.")
        @OptionGroup var project: ProjectOptions
        @Argument(help: "Language code.") var code: String
        @Option(help: "Type the language code again to confirm.") var confirm: String?

        func run() async throws {
            guard let locale = LocaleCode(rawValue: code) else { throw ValidationError("\(code) is not a language code") }
            guard confirm.flatMap(LocaleCode.init(rawValue:)) == locale else {
                throw ValidationError("This deletes every \(locale.displayName()) translation. Repeat the code with --confirm \(locale.rawValue).")
            }
            let loaded = try project.load()
            // Keep a backup of what is about to be deleted.
            let before = try await loaded.backend.pull()
            let backup = loaded.root.appendingPathComponent("runa-backup-\(locale.rawValue)-\(Int(Date().timeIntervalSince1970)).json")
            let values = before.keys.reduce(into: [String: [String: String]]()) { result, key in
                guard let forms = key.translations[locale]?.nonEmptyForms, !forms.isEmpty else { return }
                result[key.key] = Dictionary(uniqueKeysWithValues: forms.map { ($0.key.rawValue, $0.value) })
            }
            try Output.json(values).write(to: backup, atomically: true, encoding: .utf8)
            _ = try await loaded.backend.removeLocale(locale, context: loaded.context(note: "cli"))
            print("Removed \(locale.displayName()). A backup of its \(values.count) translations is in \(backup.lastPathComponent).")
        }
    }
}
