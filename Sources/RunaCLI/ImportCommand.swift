import ArgumentParser
import Foundation
import RunaCore

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import existing strings files (strings.xml, .strings, .stringsdict, .xcstrings, JSON).",
        discussion: """
        New keys and new translations are added. Values that differ from the backend are conflicts:
        they are kept as they are unless you pass --prefer file. Placeholder or plural mismatches are
        never applied automatically; resolve them in the Runa app.
        """)

    @OptionGroup var project: ProjectOptions

    @Argument(help: "Files or folders to import.") var paths: [String]

    @Option(help: "Language of the files, when the path does not say (for example a lone strings.xml).")
    var locale: String?

    @Option(help: "Which side wins a conflict: backend (default) or file.")
    var prefer: Preference = .backend

    @Flag(help: "Add languages found in the files that the project does not have yet.")
    var addLocales = false

    @Flag(help: "Show the plan without writing anything.")
    var dryRun = false

    enum Preference: String, ExpressibleByArgument { case backend, file }

    func run() async throws {
        let loaded = try project.load()
        var snapshot = try await loaded.backend.pull()
        let overrideLocale = try locale.map { raw in
            guard let code = LocaleCode(rawValue: raw) else { throw ValidationError("\(raw) is not a language code") }
            return code
        }
        var entries: [ImportedEntry] = []
        for path in try files(in: paths) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let parsed = try FormatDetector.parse(path: path, data: data, locale: overrideLocale, defaultLocale: snapshot.settings.sourceLocale)
            entries += parsed.entries
            for warning in parsed.warnings { Output.warn(warning) }
        }
        var plan = ImportPlanner.plan(entries, against: snapshot)
        for warning in plan.warnings { Output.warn(warning) }
        if prefer == .file { plan.resolveConflicts(.useFile) }

        let summary = plan.summary
        print(Output.bold("Import plan"))
        for kind in ImportItemKind.allCases {
            let count = summary[kind] ?? 0
            guard count > 0 else { continue }
            print("  \(label(kind).padding(toLength: 22, withPad: " ", startingAt: 0))\(count)")
        }
        for item in plan.items(.conflict).prefix(20) {
            print(Output.yellow("  conflict ") + "\(item.keyName) [\(item.locale)]  " +
                  Output.dim("backend: \(preview(item.current))  file: \(preview(item.imported))"))
        }
        for item in plan.items(.mismatch).prefix(20) {
            print(Output.red("  mismatch ") + "\(item.keyName) [\(item.locale)]  " + Output.dim(item.reason ?? ""))
        }
        if !plan.newLocales.isEmpty {
            let names = plan.newLocales.map(\.rawValue).joined(separator: ", ")
            print(addLocales ? "  New languages to add: \(names)" : Output.yellow("  Languages not in the project (skipped; pass --add-locales): \(names)"))
        }
        guard !dryRun else { return }

        if addLocales {
            for newLocale in plan.newLocales {
                snapshot = try await loaded.backend.addLocale(newLocale, context: loaded.context(note: "import"))
            }
        }
        let changes = plan.changes(projectLocales: snapshot.settings.locales)
        guard !changes.isEmpty else {
            print("Nothing to change.")
            return
        }
        let note = "import " + Set(entries.map(\.file)).sorted().prefix(3).joined(separator: ", ")
        let result = try await loaded.backend.push(changes, basedOn: snapshot, context: loaded.context(note: note))
        print("Applied \(result.applied.count) changes.\(result.conflicts.isEmpty ? "" : " \(result.conflicts.count) changed in the backend meanwhile and were skipped.")")
    }

    func files(in paths: [String]) throws -> [String] {
        var result: [String] = []
        for path in paths {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { throw ValidationError("\(path) does not exist") }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(atPath: expanded)
                while let item = enumerator?.nextObject() as? String {
                    let full = (expanded as NSString).appendingPathComponent(item)
                    if item.contains("node_modules") || item.contains("/build/") || item.hasPrefix(".") { continue }
                    if FormatDetector.detect(path: full) != nil, isStringsFile(full) { result.append(full) }
                }
            } else {
                result.append(expanded)
            }
        }
        return result.sorted()
    }

    /// In folders, only pick files that look like strings files, not every XML or JSON.
    func isStringsFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        switch (name as NSString).pathExtension {
        case "xcstrings", "strings", "stringsdict": return true
        case "xml": return name == "strings.xml" && parent.hasPrefix("values")
        case "json": return FormatDetector.detect(path: path)?.locale != nil
        default: return false
        }
    }

    func label(_ kind: ImportItemKind) -> String {
        switch kind {
        case .newKey: "New keys"
        case .newTranslation: "New translations"
        case .same: "Already identical"
        case .conflict: "Conflicts"
        case .mismatch: "Need manual review"
        }
    }

    func preview(_ forms: [PluralCategory: String]?) -> String {
        guard let forms, !forms.isEmpty else { return "—" }
        let text = forms[.other] ?? forms.values.first ?? ""
        return "\"\(text.prefix(40))\""
    }
}
