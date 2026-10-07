#if DEBUG
import AppKit
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
            let steps: [(String, @MainActor () -> Void)] = [
                ("keys", { store.sidebar = .keys(.all); store.selection = store.snapshot?.keys.sorted { $0.key < $1.key }.dropFirst(2).first.map { [$0.id] } ?? [] }),
                ("plural", { store.selection = store.snapshot?.key(named: "cart.items").map { [$0.id] } ?? [] }),
                ("missing", { store.sidebar = .keys(.missing(nil)); store.selection = [] }),
                ("review", { store.sidebar = .review }),
                ("languages", { store.sidebar = .languages }),
                ("activity", { store.sidebar = .activity }),
                ("import", { store.sidebar = .importStrings }),
                ("palette", { store.sidebar = .keys(.all); app.isShowingCommandPalette = true }),
            ]
            for (name, step) in steps {
                step()
                try? await Task.sleep(for: .seconds(1.5))
                capture(to: directory.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
            }
            NSApp.terminate(nil)
        }
    }

    static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView
        else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
