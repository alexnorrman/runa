import ArgumentParser
import Foundation
import RunaCore
import Yams

/// Options every command that talks to a backend shares.
struct ProjectOptions: ParsableArguments {
    @Option(name: .long, help: "Path to runa.yml. Defaults to the nearest runa.yml in this folder or a parent.")
    var config: String?

    @Option(name: .long, help: "Path to a Google service account key, overriding runa.yml and RUNA_GOOGLE_CREDENTIALS.")
    var credentials: String?

    @Option(name: .long, help: "Name recorded in history for changes. Defaults to runa.yml's actor, then your git user name.")
    var actor: String?

    func load() throws -> LoadedProject {
        let url: URL
        if let config {
            url = URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
        } else if let found = RunaConfig.locate(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
            url = found
        } else {
            throw ValidationError("No runa.yml found here or in a parent folder. Create one with `runa init`.")
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ValidationError("Could not read \(url.path): \(error.localizedDescription)")
        }
        let decoded: RunaConfig
        do {
            decoded = try YAMLDecoder().decode(RunaConfig.self, from: text)
        } catch {
            throw ValidationError("\(url.lastPathComponent) is not valid: \(describe(error))")
        }
        let root = url.deletingLastPathComponent()
        let backend = try CredentialStore.backend(for: decoded, root: root, credentialsPath: credentials)
        return LoadedProject(config: decoded, root: root, backend: backend, actor: actor ?? decoded.actor ?? Self.defaultActor())
    }

    static func defaultActor() -> String {
        if let name = ProcessInfo.processInfo.environment["RUNA_ACTOR"], !name.isEmpty { return name }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "config", "user.name"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            let name = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, !name.isEmpty { return name }
        }
        return ProcessInfo.processInfo.environment["USER"] ?? "runa"
    }

    private func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        if case DecodingError.keyNotFound(let key, _) = error { return "missing \"\(key.stringValue)\"" }
        if case DecodingError.typeMismatch(_, let context) = error {
            return "wrong value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        }
        return "\(error)"
    }
}

struct LoadedProject: Sendable {
    var config: RunaConfig
    var root: URL
    var backend: any StringsBackend
    var actor: String

    func context(note: String) -> PushContext {
        PushContext(actor: actor, note: note)
    }
}

/// Plain terminal output. Colors only when writing to a terminal.
enum Output {
    static let isTerminal = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func dim(_ text: String) -> String { isTerminal ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
    static func bold(_ text: String) -> String { isTerminal ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
    static func red(_ text: String) -> String { isTerminal ? "\u{1B}[31m\(text)\u{1B}[0m" : text }
    static func green(_ text: String) -> String { isTerminal ? "\u{1B}[32m\(text)\u{1B}[0m" : text }
    static func yellow(_ text: String) -> String { isTerminal ? "\u{1B}[33m\(text)\u{1B}[0m" : text }

    static func warn(_ text: String) {
        FileHandle.standardError.write(Data((yellow("warning: ") + text + "\n").utf8))
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func coverageLine(_ coverage: Coverage, source: Bool) -> String {
        let name = "\(coverage.locale.rawValue)".padding(toLength: 8, withPad: " ", startingAt: 0)
        let percent = Int((coverage.translatedFraction * 100).rounded())
        var parts = ["\(percent)%".padding(toLength: 5, withPad: " ", startingAt: 0)]
        if coverage.missing > 0 { parts.append(red("\(coverage.missing) missing")) }
        if coverage.needsReview > 0 { parts.append(yellow("\(coverage.needsReview) \(coverage.needsReview == 1 ? "needs" : "need") review")) }
        if coverage.machine > 0 { parts.append("\(coverage.machine) machine \(coverage.machine == 1 ? "draft" : "drafts")") }
        if parts.count == 1 { parts.append(green("complete")) }
        return "  \(name)\(parts.joined(separator: "  "))\(source ? dim("  source") : "")"
    }
}

/// Codable summaries for --json output and the MCP server.
struct KeySummary: Codable, Sendable {
    var key: String
    var description: String?
    var plural: Bool
    var tags: [String]?
    var platforms: [String]?
    var placeholders: [String]?
    var values: [String: LocaleValue]
    var figma: [String]?

    struct LocaleValue: Codable, Sendable {
        var status: String
        var text: String?
        var forms: [String: String]?
    }

    init(_ key: StringKey, in snapshot: Snapshot) {
        self.key = key.key
        description = key.description.isEmpty ? nil : key.description
        plural = key.isPlural
        tags = key.tags.isEmpty ? nil : key.tags
        platforms = key.platforms.isEmpty ? nil : key.platforms.map(\.rawValue)
        let placeholders = key.placeholders(sourceLocale: snapshot.settings.sourceLocale).map(\.canonical)
        self.placeholders = placeholders.isEmpty ? nil : placeholders
        var values: [String: LocaleValue] = [:]
        for locale in snapshot.settings.locales {
            let translation = key.translations[locale]
            let status = snapshot.status(of: key, locale: locale).rawValue
            if key.isPlural {
                let forms = translation?.nonEmptyForms ?? [:]
                values[locale.rawValue] = LocaleValue(status: status, forms: forms.isEmpty ? nil : Dictionary(uniqueKeysWithValues: forms.map { ($0.key.rawValue, $0.value) }))
            } else {
                values[locale.rawValue] = LocaleValue(status: status, text: translation?.value)
            }
        }
        self.values = values
        figma = key.contexts.isEmpty ? nil : key.contexts.map(\.url)
    }
}

/// Simple fuzzy search shared by `runa keys search` and the MCP server.
enum KeySearch {
    static func search(_ query: String, in snapshot: Snapshot, limit: Int) -> [StringKey] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Array(snapshot.keys.sorted { $0.key < $1.key }.prefix(limit)) }
        let scored = snapshot.keys.compactMap { key -> (StringKey, Int)? in
            var best = score(needle, key.key.lowercased(), weight: 3)
            for translation in key.translations.values {
                for text in translation.forms.values { best = max(best, score(needle, text.lowercased(), weight: 2)) }
            }
            best = max(best, score(needle, key.description.lowercased(), weight: 1))
            return best > 0 ? (key, best) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.key < $1.0.key }.prefix(limit).map(\.0)
    }

    /// Exact substring beats prefix-of-word beats in-order subsequence.
    static func score(_ needle: String, _ haystack: String, weight: Int) -> Int {
        if haystack == needle { return 1000 * weight }
        if haystack.contains(needle) { return (haystack.hasPrefix(needle) ? 600 : 400) * weight }
        var index = haystack.startIndex
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return 0 }
            index = haystack.index(after: found)
        }
        return 100 * weight
    }
}
