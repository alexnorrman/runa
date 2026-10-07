import Foundation
import RunaCore

/// A project the user added: which backend, plus local-only settings for AI translation.
struct ProjectRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var location: Location
    var glossary: [GlossaryTerm] = []
    var styleGuides: [LocaleCode: String] = [:]
    var addedAt = Date()

    enum Location: Codable, Hashable {
        case googleSheets(spreadsheetID: String, serviceAccount: String)
        case localJSON(path: String)

        var kind: BackendKind {
            switch self {
            case .googleSheets: .googleSheets
            case .localJSON: .localJSON
            }
        }

        var detail: String {
            switch self {
            case .googleSheets(let id, _): "Google Sheet \(id.prefix(10))…"
            case .localJSON(let path): (path as NSString).abbreviatingWithTildeInPath
            }
        }

        var webURL: URL? {
            switch self {
            case .googleSheets(let id, _): URL(string: "https://docs.google.com/spreadsheets/d/\(id)/edit")
            case .localJSON(let path): URL(fileURLWithPath: path)
            }
        }
    }
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AppSettings: Codable, Equatable {
    var displayName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    var appearance = Appearance.system
    var ai: AIProviderConfig?
    var autoSyncMinutes = 2
}

/// Files under ~/Library/Application Support/Runa.
enum Storage {
    static var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runa", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var projectsFile: URL { root.appendingPathComponent("projects.json") }
    static func cacheFile(_ id: UUID) -> URL { directory("Cache").appendingPathComponent("\(id.uuidString).json") }
    static var backups: URL { directory("Backups") }
    static var figmaImages: URL { directory("FigmaImages") }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
