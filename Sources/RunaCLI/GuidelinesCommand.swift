import ArgumentParser
import Foundation
import RunaCore

struct Guidelines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change the project's naming guide, key format and style guides.",
        discussion: """
        Guidelines live in the backend (the sheet's guidelines and glossary tabs), so the Mac app, the Figma
        plugin and every agent using `runa mcp` follow the same ones.
        """,
        subcommands: [Show.self, Set.self], defaultSubcommand: Show.self)

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the guidelines as markdown.")
        @OptionGroup var project: ProjectOptions

        func run() async throws {
            let snapshot = try await project.load().backend.pull()
            print(AgentGuide.markdown(snapshot.guidelines, settings: snapshot.settings), terminator: "")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change parts of the guidelines. Parts you leave out stay as they are; pass \"\" to clear one.",
            discussion: """
            runa guidelines set --naming docs/naming.md --key-template "{platform?}_{feature}_{description}_{type:title|text|action}"
            runa guidelines set --style sv "Informal, address the reader as du."
            """)
        @OptionGroup var project: ProjectOptions

        @Option(help: ArgumentHelp("Markdown file with the naming guide, or - to read it from standard input.", valueName: "file"))
        var naming: String?

        @Option(help: ArgumentHelp("Key format, for example {feature}_{description}_{type:title|text|action}.", valueName: "template"))
        var keyTemplate: String?

        @Option(help: ArgumentHelp("Regular expression every key name must match. Overrides the template for checks.", valueName: "regex"))
        var keyPattern: String?

        @Option(parsing: .upToNextOption, help: ArgumentHelp("A language code and its style guide.", valueName: "code text"))
        var style: [String] = []

        func validate() throws {
            guard naming != nil || keyTemplate != nil || keyPattern != nil || !style.isEmpty else {
                throw ValidationError("Pass at least one of --naming, --key-template, --key-pattern or --style.")
            }
            guard style.count % 2 == 0 || style.isEmpty else { throw ValidationError("--style takes a language code and a text.") }
        }

        func run() async throws {
            let loaded = try project.load()
            let base = try await loaded.backend.pull().guidelines
            var edited = base
            if let naming {
                if naming.isEmpty {
                    edited.naming = ""
                } else {
                    let data = naming == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: naming))
                    guard let text = String(data: data, encoding: .utf8) else { throw ValidationError("\(naming) is not UTF-8 text.") }
                    edited.naming = text
                }
            }
            if let keyTemplate { edited.keyTemplate = keyTemplate }
            if let keyPattern { edited.keyPattern = keyPattern }
            for pair in stride(from: 0, to: style.count, by: 2) {
                guard let locale = LocaleCode(rawValue: style[pair]) else { throw ValidationError("\(style[pair]) is not a language code.") }
                edited.styleGuides[locale] = style[pair + 1]
            }
            let rules = KeyNamingRules(edited)
            if let problem = rules.configurationProblems.first { throw ValidationError(problem) }

            let saved = try await loaded.backend.setGuidelines(edited, basedOn: base, context: loaded.context(note: "cli"))
            let changes = saved.guidelines.changes(from: base.normalized)
            if changes.isEmpty {
                print("Nothing changed.")
                return
            }
            print("Saved \(changes.map(\.label).joined(separator: ", ")).")
            let broken = AgentGuide.namingProblems(in: saved)
            if !broken.isEmpty {
                print(Output.dim("\(broken.count) existing key\(broken.count == 1 ? "" : "s") do not follow it yet; see `runa check --names`."))
            }
        }
    }
}
