import ArgumentParser
import Foundation
import RunaCore

@main
struct Runa: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runa",
        abstract: "Pull UI strings from your Runa backend into iOS, Android and web projects.",
        discussion: """
        Run commands inside a repository that has a runa.yml (see `runa init`). Runa writes files;
        you review and commit them as usual.
        """,
        version: RunaVersion.current,
        subcommands: [Init.self, Setup.self, Pull.self, Check.self, Keys.self, Locales.self, Guidelines.self, Import.self, MCPCommand.self]
    )
}

enum RunaVersion {
    static let current = "0.1.0"
}
