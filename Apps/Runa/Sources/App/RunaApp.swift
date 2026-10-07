import RunaCore
import RunaDesign
import SwiftUI

@main
struct RunaApp: App {
    @State private var app = AppModel()

    init() {
        RunaFont.register()
    }

    var body: some Scene {
        Window("Runa", id: "main") {
            MainView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    app.applyAppearance()
                    #if DEBUG
                    DebugSnapshots.runIfRequested(app: app)
                    #endif
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1320, height: 820)
        .commands { RunaCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}

struct RunaCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Key") { app.currentStore?.isCreatingKey = true }
                .keyboardShortcut("n")
                .disabled(app.currentStore?.snapshot == nil)
            Button("Add Project…") { app.isAddingProject = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Strings…") { app.currentStore?.sidebar = .importStrings }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(app.currentStore?.snapshot == nil)
            Button("Export Strings…") { app.currentStore?.isExporting = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(app.currentStore?.snapshot == nil)
        }
        CommandMenu("Strings") {
            Button("Command Palette") { app.isShowingCommandPalette = true }
                .keyboardShortcut("k")
            Button("Sync Now") { Task { await app.currentStore?.refresh() } }
                .keyboardShortcut("r")
                .disabled(app.currentStore == nil)
            Divider()
            Button("Translate Missing…") {
                guard let store = app.currentStore else { return }
                store.translateScope = .init(keyIDs: nil, locales: store.missingByLocale.map(\.locale))
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(app.currentStore?.snapshot == nil)
            Button("Review Drafts") { app.currentStore?.sidebar = .review }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(app.currentStore?.snapshot == nil)
            Divider()
            Button("All Keys") { app.currentStore?.sidebar = .keys(.all) }.keyboardShortcut("1")
            Button("Missing") { app.currentStore?.sidebar = .keys(.missing(nil)) }.keyboardShortcut("2")
            Button("Languages") { app.currentStore?.sidebar = .languages }.keyboardShortcut("3")
            Button("Activity") { app.currentStore?.sidebar = .activity }.keyboardShortcut("4")
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { app.currentStore?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
