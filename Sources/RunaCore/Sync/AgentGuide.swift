import Foundation

/// What coding agents are told about a project: the MCP server's instructions and the guidelines as markdown.
/// Built from the backend, so every agent that connects follows the same convention.
public enum AgentGuide {
    /// Naming guides longer than this are not repeated in the instructions; agents read them with runa_guidelines.
    static let inlineNamingLimit = 8_000

    /// Facts about Runa that hold in every project.
    static let basics = """
    Placeholders use {name}, {count:int}, {price:double} and {price:double.2}. Runa converts them to each platform's \
    format (%1$d, %lld, {{name}}), so never write %d, %s or %@ in values. A plural is one key with forms \
    (one, other, and few or many where a language needs them); never put a plural form in the key name.
    """

    /// Instructions sent when an agent connects. `guidelines` is nil when the backend could not be read at startup.
    public static func instructions(guidelines: ProjectGuidelines?) -> String {
        var text = """
        Runa manages the UI strings of this project in a shared backend (often a Google Sheet). When you add \
        user-facing text to iOS, Android or web code, look for an existing key first with runa_search_keys, \
        reuse it if the meaning matches, otherwise create one with runa_add_key, then call runa_pull to \
        regenerate the platform files. \(basics) Write only the source language; translators and the Runa app \
        handle the rest, and translations you propose with runa_set_translation wait for a person's approval. \
        Never edit generated files (Localizable.xcstrings, strings.xml, locale JSON) by hand.
        """
        guard let guidelines else {
            return text + "\n\nBefore naming a key or translating, call runa_guidelines for this project's naming convention, glossary and style guides."
        }
        let rules = KeyNamingRules(guidelines)
        if let format = rules.formatDescription {
            text += "\n\nKey names in this project must be \(format). runa_add_key rejects other names."
        } else if guidelines.naming.isEmpty {
            text += "\n\nKey names use dot-separated segments: screen.element.purpose, for example checkout.summary.title."
        }
        if let template = rules.template, !template.platformOptions.isEmpty {
            text += " Start a name with a platform only when the text exists on that platform alone; Runa then ships it there only."
        }
        let naming = guidelines.naming
        if !naming.isEmpty {
            if naming.count <= inlineNamingLimit {
                text += "\n\nThis project's naming guide, from its Runa backend:\n\n\(naming)"
            } else {
                text += "\n\nThis project has a naming guide; read it with runa_guidelines before adding keys."
            }
        }
        if !guidelines.glossary.isEmpty || !guidelines.styleGuides.isEmpty {
            text += "\n\nBefore translating, call runa_guidelines for the glossary and style guides."
        }
        return text
    }

    /// The guidelines as one markdown document, for runa_guidelines and `runa guidelines show`.
    public static func markdown(_ guidelines: ProjectGuidelines, settings: ProjectSettings) -> String {
        let rules = KeyNamingRules(guidelines)
        var lines = ["# \(settings.name): guidelines", "", "## Key names", ""]
        if let template = rules.template { lines.append("Format: `\(template.source)`") }
        if let pattern = rules.customPattern { lines.append("Pattern: `\(pattern)`") }
        if rules.template == nil, rules.customPattern == nil { lines.append("No key format is set; any letters, digits, `_`, `-` and `.` work.") }
        for problem in rules.configurationProblems { lines.append("Warning: \(problem) It is ignored until fixed.") }
        lines += ["", guidelines.naming.isEmpty ? "No naming guide yet." : guidelines.naming, "", "## Text", "", basics]

        lines += ["", "## Glossary", ""]
        if guidelines.glossary.isEmpty {
            lines.append("No glossary.")
        } else {
            let locales = settings.targetLocales
            lines.append("| Term | Note | " + locales.map(\.rawValue).joined(separator: " | ") + " |")
            lines.append("|---|---|" + String(repeating: "---|", count: locales.count))
            for term in guidelines.glossary {
                let cells = locales.map { term.translations[$0] ?? "keep as is" }
                lines.append("| \(escape(term.term)) | \(escape(term.note)) | " + cells.map(escape).joined(separator: " | ") + " |")
            }
        }

        lines += ["", "## Style guides", ""]
        let guides = guidelines.styleGuides.filter { !$0.value.isEmpty }.sorted { $0.key.rawValue < $1.key.rawValue }
        if guides.isEmpty { lines.append("No style guides.") }
        for (locale, text) in guides { lines += ["### \(locale.displayName()) (\(locale.rawValue))", "", text, ""] }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// Problems with key names in a snapshot: the naming convention and platform prefixes. Sorted by key.
    public static func namingProblems(in snapshot: Snapshot) -> [(key: String, problem: String)] {
        let rules = snapshot.namingRules
        return snapshot.keys.sorted { $0.key < $1.key }.compactMap { key in
            (rules.problem(with: key.key) ?? rules.platformProblem(for: key)).map { (key.key, $0) }
        }
    }
}
