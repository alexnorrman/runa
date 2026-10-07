import ArgumentParser
import Foundation
import MCP
import RunaCore

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run an MCP server on stdio so coding agents can look up, add and pull strings.",
        discussion: """
        Claude Code:  claude mcp add runa -- runa mcp
        Other clients: {"command": "runa", "args": ["mcp", "--config", "/path/to/runa.yml"]}
        """)

    @OptionGroup var project: ProjectOptions

    func run() async throws {
        let loaded = try project.load()
        let tools = RunaTools(project: loaded)
        let serial = SerialExecutor()
        let server = Server(
            name: "runa",
            version: RunaVersion.current,
            instructions: RunaTools.instructions,
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: RunaTools.definitions) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                // Clients may send calls concurrently; run them one at a time so a pull sees a preceding add.
                let text = try await serial.run { try await tools.call(params.name, arguments: params.arguments ?? [:]) }
                return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            } catch {
                return .init(content: [.text(text: (error as? LocalizedError)?.errorDescription ?? "\(error)", annotations: nil, _meta: nil)],
                             isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [Resource(name: "Project summary", uri: RunaTools.summaryURI,
                                       description: "Languages, coverage and naming conventions", mimeType: "text/markdown")],
                  nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard params.uri == RunaTools.summaryURI else { throw MCPError.invalidParams("Unknown resource \(params.uri)") }
            return .init(contents: [.text(try await tools.summary(), uri: params.uri, mimeType: "text/markdown")])
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

/// The tools the MCP server exposes. Kept separate from MCP types so the logic is easy to test.
struct RunaTools: Sendable {
    let project: LoadedProject

    static let summaryURI = "runa://project/summary"

    static let instructions = """
    Runa manages the UI strings of this project in a shared backend (often a Google Sheet). When you add \
    user-facing text to iOS, Android or web code, look for an existing key first with runa_search_keys, \
    reuse it if the meaning matches, otherwise create one with runa_add_key, then call runa_pull to \
    regenerate the platform files. Key names use dot-separated segments: screen.element.purpose, for \
    example checkout.summary.title. Placeholders use {name}, {count:int}, {price:double}. Write only the \
    source language; translators and the Runa app handle the rest. Never edit generated files \
    (Localizable.xcstrings, strings.xml, locale JSON) by hand.
    """

    static let definitions: [Tool] = [
        Tool(name: "runa_search_keys", description: "Fuzzy search keys by name, text in any language, or description. Use before adding a key.",
             inputSchema: schema(["query": ("string", "What to look for"), "limit": ("integer", "Maximum results, default 10")], required: ["query"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "runa_get_key", description: "Get one key with its description, placeholders, Figma links and text and status in every language.",
             inputSchema: schema(["key": ("string", "Key name")], required: ["key"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "runa_add_key",
             description: "Add a key in the source language. For plural keys pass `one` and `other` instead of `text`. Fails if the key exists.",
             inputSchema: schema([
                 "key": ("string", "Dot-separated name, e.g. checkout.summary.title"),
                 "text": ("string", "Source-language text with {placeholders}"),
                 "description": ("string", "Where and how the text is used, for translators"),
                 "one": ("string", "Plural: singular form, e.g. {count:int} item"),
                 "other": ("string", "Plural: general form, e.g. {count:int} items"),
                 "platforms": ("string", "Comma-separated subset of ios, android, web. Omit for all."),
             ], required: ["key"]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
        Tool(name: "runa_update_source_text", description: "Change a key's source-language text. Existing translations become 'needs review'.",
             inputSchema: schema(["key": ("string", "Key name"), "text": ("string", "New text"),
                                  "form": ("string", "Plural form to change (zero, one, two, few, many, other). Omit for plain keys.")],
                                 required: ["key", "text"]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "runa_set_translation",
             description: "Propose a translation. It is saved as a machine draft that a person approves in the Runa app.",
             inputSchema: schema(["key": ("string", "Key name"), "locale": ("string", "Language code, e.g. sv"), "text": ("string", "Translated text"),
                                  "form": ("string", "Plural form. Omit for plain keys.")], required: ["key", "locale", "text"]),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
        Tool(name: "runa_delete_key", description: "Delete a key in every language. Only when the user asked for it.",
             inputSchema: schema(["key": ("string", "Key name")], required: ["key"]),
             annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
        Tool(name: "runa_list_locales", description: "Languages in the project and how complete each one is.",
             inputSchema: schema([:], required: []), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "runa_check", description: "Keys missing a translation, per language.",
             inputSchema: schema(["locale": ("string", "Only this language")], required: []),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "runa_pull", description: "Regenerate the platform string files listed in runa.yml from the backend. Returns the files that changed.",
             inputSchema: schema([:], required: []),
             annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
    ]

    static func schema(_ properties: [String: (String, String)], required: [String]) -> Value {
        var props: [String: Value] = [:]
        for (name, (type, description)) in properties {
            props[name] = .object(["type": .string(type), "description": .string(description)])
        }
        return .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) })])
    }

    func call(_ name: String, arguments: [String: Value]) async throws -> String {
        func string(_ key: String) -> String? {
            guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func require(_ key: String) throws -> String {
            guard let value = string(key) else { throw ToolError("Missing \(key)") }
            return value
        }
        let backend = project.backend
        let context = project.context(note: "mcp")
        switch name {
        case "runa_search_keys":
            let snapshot = try await backend.pull()
            let limit = arguments["limit"]?.intValue ?? 10
            let results = KeySearch.search(try require("query"), in: snapshot, limit: limit)
            if results.isEmpty { return "No matching keys." }
            return try Output.json(results.map { KeySummary($0, in: snapshot) })

        case "runa_get_key":
            let snapshot = try await backend.pull()
            let key = try require("key")
            guard let found = snapshot.key(named: key) else { throw ToolError("No key named \(key). Search with runa_search_keys.") }
            return try Output.json(KeySummary(found, in: snapshot))

        case "runa_add_key":
            let key = try require("key")
            if let problem = KeyNaming.problem(with: key) { throw ToolError(problem) }
            let snapshot = try await backend.pull()
            if snapshot.key(named: key) != nil { throw ToolError("\(key) already exists. Use runa_get_key or pick another name.") }
            var forms: [PluralCategory: String] = [:]
            let plural = string("one") != nil || string("other") != nil
            if plural {
                forms[.one] = string("one")
                forms[.other] = try require("other")
            } else {
                forms[.other] = try require("text")
            }
            let platforms = (string("platforms") ?? "").split(separator: ",").compactMap {
                Platform(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased())
            }
            let newKey = StringKey(key: key, description: string("description") ?? "", platforms: platforms, isPlural: plural,
                                   translations: [snapshot.settings.sourceLocale: Translation(forms: forms.compactMapValues { $0 })])
            let result = try await backend.push([.addKey(newKey)], basedOn: snapshot, context: context)
            if let conflict = result.conflicts.first { throw ToolError("Not added: \(conflict.kind.rawValue)") }
            return "Added \(key). Run runa_pull to update the platform files."

        case "runa_update_source_text", "runa_set_translation":
            let snapshot = try await backend.pull()
            let key = try require("key")
            guard let found = snapshot.key(named: key) else { throw ToolError("No key named \(key)") }
            let isSource = name == "runa_update_source_text"
            let locale: LocaleCode
            if isSource {
                locale = snapshot.settings.sourceLocale
            } else {
                guard let parsed = LocaleCode(rawValue: try require("locale")), snapshot.settings.locales.contains(parsed) else {
                    throw ToolError("Unknown language. The project has: \(snapshot.settings.locales.map(\.rawValue).joined(separator: ", "))")
                }
                locale = parsed
            }
            let category: PluralCategory
            if let form = string("form") {
                guard let parsed = PluralCategory(rawValue: form) else { throw ToolError("Unknown plural form \(form)") }
                category = parsed
            } else {
                if found.isPlural { throw ToolError("\(key) is plural; pass form (one, other, …)") }
                category = .other
            }
            let change = Change.setValue(id: found.id, locale: locale, category: category, value: try require("text"),
                                         status: isSource ? .approved : .machine)
            let result = try await backend.push([change], basedOn: snapshot, context: context)
            if let conflict = result.conflicts.first { throw ToolError("Not saved: \(conflict.kind.rawValue)") }
            return isSource ? "Updated \(key). Translations of it now need review." : "Saved a draft for \(key) [\(locale)]; a person approves it in Runa."

        case "runa_delete_key":
            let snapshot = try await backend.pull()
            let key = try require("key")
            guard let found = snapshot.key(named: key) else { throw ToolError("No key named \(key)") }
            _ = try await backend.push([.deleteKey(id: found.id)], basedOn: snapshot, context: context)
            return "Deleted \(key)."

        case "runa_list_locales":
            let snapshot = try await backend.pull()
            struct Row: Encodable { var locale: String; var name: String; var source: Bool; var missing: Int; var needsReview: Int; var machine: Int; var total: Int }
            return try Output.json(snapshot.settings.locales.map { locale in
                let coverage = snapshot.coverage(for: locale)
                return Row(locale: locale.rawValue, name: locale.displayName(), source: locale == snapshot.settings.sourceLocale,
                           missing: coverage.missing, needsReview: coverage.needsReview, machine: coverage.machine, total: coverage.total)
            })

        case "runa_check":
            let snapshot = try await backend.pull()
            let only = string("locale").flatMap(LocaleCode.init(rawValue:))
            var missing: [String: [String]] = [:]
            for (key, locales) in snapshot.missingTranslations() {
                let filtered = locales.filter { only == nil || $0 == only }
                if !filtered.isEmpty { missing[key.key] = filtered.map(\.rawValue) }
            }
            return missing.isEmpty ? "Nothing is missing." : try Output.json(missing)

        case "runa_pull":
            guard !project.config.targets.isEmpty else { throw ToolError("runa.yml has no targets.") }
            let snapshot = try await backend.pull()
            let report = try Exporter.write(snapshot, config: project.config, root: project.root)
            var lines = report.written.map { "wrote \($0)" }
            lines += report.warnings.map { "warning: \($0)" }
            lines.append("\(report.written.count) files changed, \(report.unchanged.count) unchanged.")
            return lines.joined(separator: "\n")

        default:
            throw ToolError("Unknown tool \(name)")
        }
    }

    func summary() async throws -> String {
        let snapshot = try await project.backend.pull()
        var lines = ["# \(snapshot.settings.name)", "", "\(snapshot.keys.count) keys. Source language: \(snapshot.settings.sourceLocale.displayName()).", ""]
        lines.append("| Language | Missing | Needs review | Machine drafts |")
        lines.append("|---|---|---|---|")
        for locale in snapshot.settings.locales {
            let coverage = snapshot.coverage(for: locale)
            lines.append("| \(locale.displayName()) (\(locale)) | \(coverage.missing) | \(coverage.needsReview) | \(coverage.machine) |")
        }
        let prefixes = Dictionary(grouping: snapshot.keys, by: { $0.key.split(separator: ".").first.map(String.init) ?? "" })
            .sorted { $0.value.count > $1.value.count }.prefix(12).map { "\($0.key) (\($0.value.count))" }
        lines += ["", "Most used key prefixes: \(prefixes.joined(separator: ", "))", "", Self.instructions]
        return lines.joined(separator: "\n")
    }
}

/// Runs async operations one after another, in the order they were submitted.
actor SerialExecutor {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

struct ToolError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
