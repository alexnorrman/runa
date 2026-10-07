import Foundation
import RunaCore

/// Installs the bundled `runa` command line tool and, optionally, a Google key for it.
enum CLIInstaller {
    static var bundledBinary: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/runa")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// `~/.local/bin` needs no administrator rights; it is on PATH for most shells, and Runa says so when it is not.
    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var installedLink: URL { installDirectory.appendingPathComponent("runa") }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: installedLink.path)) != nil
            || FileManager.default.isExecutableFile(atPath: installedLink.path)
    }

    static var isOnPath: Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { $0 == installDirectory.path || $0 == "~/.local/bin" }
    }

    static func install() throws {
        guard let binary = bundledBinary else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                "This build has no bundled command line tool. Build it with `swift build -c release --product runa`, or use a release build of Runa."])
        }
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installedLink)
        try FileManager.default.createSymbolicLink(at: installedLink, withDestinationURL: binary)
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: installedLink)
    }

    static func mcpConfigJSON(configPath: String?) -> String {
        var args = ["\"mcp\""]
        if let configPath { args += ["\"--config\"", "\"\(configPath)\""] }
        return """
        {
          "mcpServers": {
            "runa": { "command": "\(installedLink.path)", "args": [\(args.joined(separator: ", "))] }
          }
        }
        """
    }

    static func runaYAML(for record: ProjectRecord, serviceAccount: String?) -> String {
        switch record.location {
        case .googleSheets(let id, _):
            return RunaConfig.template(spreadsheet: "https://docs.google.com/spreadsheets/d/\(id)/edit", localPath: nil)
        case .localJSON(let path):
            return RunaConfig.template(spreadsheet: nil, localPath: path)
        }
    }
}
