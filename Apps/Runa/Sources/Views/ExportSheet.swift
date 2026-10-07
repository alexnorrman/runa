import RunaCore
import RunaDesign
import SwiftUI

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore
    @State private var formats: Set<FormatKind> = [.xcstrings, .android, .i18next]
    @State private var approvedOnly = false
    @State private var nested = true
    @State private var result: (folder: URL, files: Int, warnings: [String])?

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            Text("Export strings").runaTitle(RunaFont.title3)
            Text("For one-off exports. In a repository, `runa pull` writes the same files from runa.yml.")
                .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
            ForEach(FormatKind.allCases, id: \.self) { format in
                Toggle(format.displayName, isOn: Binding(get: { formats.contains(format) }, set: { if $0 { formats.insert(format) } else { formats.remove(format) } }))
                    .toggleStyle(.runaCheckbox).font(RunaFont.body)
            }
            HairlineDivider()
            Toggle("Only approved translations", isOn: $approvedOnly).toggleStyle(.runaCheckbox).font(RunaFont.body)
            Toggle("Nest i18next keys on dots", isOn: $nested).toggleStyle(.runaCheckbox).font(RunaFont.body)
            if let result {
                Banner(.success, title: "Wrote \(result.files) files", message: result.warnings.first) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }.buttonStyle(.runa(.secondary, size: .small))
                }
            }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(.runaSecondary).keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.buttonStyle(.runaPrimary).disabled(formats.isEmpty)
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 460)
        .background(RunaColor.elevated)
    }

    func export() {
        guard let snapshot = store.snapshot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let root = folder.appendingPathComponent("\(store.record.name) strings", isDirectory: true)
        var targets: [RunaConfig.Target] = []
        for format in FormatKind.allCases where formats.contains(format) {
            switch format {
            case .xcstrings: targets.append(.init(format: format, path: "ios/Localizable.xcstrings"))
            case .appleStrings: targets.append(.init(format: format, path: "ios-legacy"))
            case .android: targets.append(.init(format: format, path: "android/res"))
            case .i18next: targets.append(.init(format: format, path: "web/i18next", nested: nested, file: "{locale}/translation.json"))
            case .icu: targets.append(.init(format: format, path: "web/icu"))
            }
        }
        let config = RunaConfig(backend: .init(type: .localJSON), targets: targets, approvedOnly: approvedOnly)
        do {
            let report = try Exporter.write(snapshot, config: config, root: root)
            result = (root, report.written.count + report.unchanged.count, report.warnings)
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}
