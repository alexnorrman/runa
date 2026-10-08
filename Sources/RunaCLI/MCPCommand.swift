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
        // The project's naming guide goes into the instructions. If the backend is slow or unreachable, agents are
        // told to call runa_guidelines instead, so connecting never waits long.
        let guidelines = await withTimeout(seconds: 8) { try await loaded.backend.pull().guidelines }
        let server = Server(
            name: "runa",
            version: RunaVersion.current,
            instructions: AgentGuide.instructions(guidelines: guidelines),
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
                                       description: "Languages, coverage and the key format", mimeType: "text/markdown"),
                              Resource(name: "Guidelines", uri: RunaTools.guidelinesURI,
                                       description: "Naming guide, glossary and style guides", mimeType: "text/markdown")],
                  nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in
            switch params.uri {
            case RunaTools.summaryURI: return .init(contents: [.text(try await tools.summary(), uri: params.uri, mimeType: "text/markdown")])
            case RunaTools.guidelinesURI: return .init(contents: [.text(try await tools.guidelines(), uri: params.uri, mimeType: "text/markdown")])
            default: throw MCPError.invalidParams("Unknown resource \(params.uri)")
            }
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

/// The tools the MCP server exposes. Kept separate from MCP types so the logic is easy to test.
struct RunaTools: Sendable {
    let project: LoadedProject

    static let summaryURI = "runa://project/summary"
    static let guidelinesURI = "runa://project/guidelines"

    static let definitions: [Tool] = [
        Tool(name: "runa_search_keys", description: "Fuzzy search keys by name, text in any language, or description. Use before adding a key.",
             inputSchema: schema(["query": ("string", "What to look for"), "limit": ("integer", "Maximum results, default 10")], required: ["query"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "runa_get_key", description: "Get one key with its description, placeholders, Figma links and text and status in every language.",
             inputSchema: schema(["key": ("string", "Key name")], required: ["key"]),
             annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "runa_guidelines",
             description: "This project's naming guide and key format, glossary and style guides. Read it before naming keys or translating.",
             inputSchema: schema([:], required: []), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "runa_add_key",
             description: "Add a key in the source language. The name must follow the project's key format (see runa_guidelines). "
                 + "For plural keys pass `one` and `other` instead of `text`. Fails if the key exists.",
             inputSchema: schema([
                 "key": ("string", "Dot-separated name, e.g. checkout.summary.title"),
                 "text": ("string", "Source-language text with {placeholders}"),
                 "description": ("string", "Where and how the text is used, for translators"),
                 "one": ("string", "Plural: singular form, e.g. {count:int} item"),
                 "other": ("string", "Plural: general form, e.g. {count:int} items"),
                 "platforms": ("string", "Comma-separated subset of ios, android, web. Omit for all, or to take it from a platform prefix in the name."),
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
        Tool(name: "runa_check", description: "Keys missing a translation, per language. With names, also keys whose names break the project's key format.",
             inputSchema: schema(["locale": ("string", "Only this language"),
                                  "names": ("boolean", "Also check key names against the key format and their platforms")], required: []),
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

        case "runa_guidelines":
            return try await guidelines()

        case "runa_add_key":
            let key = try require("key")
            if let problem = KeyNaming.problem(with: key) { throw ToolError(problem) }
            let snapshot = try await backend.pull()
            let rules = snapshot.namingRules
            if let problem = rules.problem(with: key) { throw ToolError("\(problem) Call runa_guidelines for this project's naming guide.") }
            if snapshot.key(named: key) != nil { throw ToolError("\(key) already exists. Use runa_get_key or pick another name.") }
            var forms: [PluralCategory: String] = [:]
            let plural = string("one") != nil || string("other") != nil
            if plural {
                forms[.one] = string("one")
                forms[.other] = try require("other")
            } else {
                forms[.other] = try require("text")
            }
            var platforms = (string("platforms") ?? "").split(separator: ",").compactMap {
                Platform(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased())
            }
            let implied = platforms.isEmpty ? rules.impliedPlatforms(for: key) : nil
            if let implied { platforms = implied }
            let newKey = StringKey(key: key, description: string("description") ?? "", platforms: platforms, isPlural: plural,
                                   translations: [snapshot.settings.sourceLocale: Translation(forms: forms.compactMapValues { $0 })])
            if let problem = rules.platformProblem(for: newKey) { throw ToolError(problem) }
            let result = try await backend.push([.addKey(newKey)], basedOn: snapshot, context: context)
            if let conflict = result.conflicts.first { throw ToolError("Not added: \(conflict.kind.rawValue)") }
            let scope = implied.map { " It ships to \($0.map(\.displayName).joined()) only, as its name says." } ?? ""
            return "Added \(key).\(scope) Run runa_pull to update the platform files."

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
            guard arguments["names"]?.boolValue == true else {
                return missing.isEmpty ? "Nothing is missing." : try Output.json(missing)
            }
            struct Report: Encodable { var missing: [String: [String]]; var naming: [String: String] }
            let naming = Dictionary(AgentGuide.namingProblems(in: snapshot).map { ($0.key, $0.problem) }, uniquingKeysWith: { first, _ in first })
            if missing.isEmpty, naming.isEmpty { return "Nothing is missing, and every key name follows the project's key format." }
            return try Output.json(Report(missing: missing, naming: naming))

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

    func guidelines() async throws -> String {
        let snapshot = try await project.backend.pull()
        return AgentGuide.markdown(snapshot.guidelines, settings: snapshot.settings)
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
        func firstSegment(_ key: StringKey) -> String {
            let segments = key.key.split { $0 == "." || $0 == "_" }
            return segments.first.map(String.init) ?? ""
        }
        let groups: [String: [StringKey]] = Dictionary(grouping: snapshot.keys, by: firstSegment)
        let prefixes: [String] = groups.sorted { $0.value.count > $1.value.count }.prefix(12).map { "\($0.key) (\($0.value.count))" }
        lines += ["", "Most used key prefixes: \(prefixes.joined(separator: ", "))"]
        if let format = snapshot.namingRules.formatDescription { lines += ["", "Key format: \(format)"] }
        lines += ["", AgentGuide.instructions(guidelines: snapshot.guidelines)]
        return lines.joined(separator: "\n")
    }
}

/// The operation's result, or nil when it fails or takes longer than `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
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
