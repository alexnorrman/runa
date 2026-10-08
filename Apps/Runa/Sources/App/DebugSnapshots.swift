#if DEBUG
import AppKit
import RunaCore
import SwiftUI

/// Debug builds only: `--snapshots <directory>` renders the main window for each section to PNG
/// files and quits. Used to check the UI from scripts without screen-recording permission.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(app: AppModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshots"), arguments.count > index + 1 else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let dark = arguments.contains("--dark")
        Task { @MainActor in
            app.settings.appearance = dark ? .dark : .light
            try? await Task.sleep(for: .seconds(4))
            guard let store = app.currentStore else { return }
            // Demo projects made before guidelines existed get the sample ones, so the settings sheet has content.
            if case .localJSON(let path) = store.record.location, path.contains("/Demo/"), store.snapshot?.guidelines.isEmpty == true {
                _ = await store.saveGuidelines(DemoProject.guidelines, basedOn: ProjectGuidelines())
            }
            let steps: [(String, @MainActor () -> Void)] = [
                ("keys", { store.sidebar = .keys(.all); store.selection = store.snapshot?.keys.sorted { $0.key < $1.key }.dropFirst(2).first.map { [$0.id] } ?? [] }),
                ("plural", { store.selection = store.snapshot?.key(named: "cart.items").map { [$0.id] } ?? [] }),
                ("missing", { store.sidebar = .keys(.missing(nil)); store.selection = [] }),
                ("review", { store.sidebar = .review }),
                ("languages", { store.sidebar = .languages }),
                ("activity", { store.sidebar = .activity }),
                ("import", { store.sidebar = .importStrings }),
                ("palette", { store.sidebar = .keys(.all); app.isShowingCommandPalette = true }),
                ("settings", { app.isShowingCommandPalette = false; store.isEditingProject = true }),
                ("newkey", { store.isEditingProject = false; store.isCreatingKey = true }),
            ]
            for (name, step) in steps {
                step()
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: directory.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
            }
            // An open sheet keeps the app from quitting.
            store.isCreatingKey = false
            store.isEditingProject = false
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        }
    }

    static func capture(to url: URL) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) else { return }
        // An open sheet is its own window; capture it instead of the window behind it.
        let window = main.attachedSheet ?? main
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
