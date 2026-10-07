import RunaCore
import RunaDesign
import SwiftUI
import UniformTypeIdentifiers

struct AddProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind = BackendKind.googleSheets

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.l) {
            Text("Add a project").runaTitle(RunaFont.title2)
            Picker("", selection: $kind) {
                Text("Google Sheet").tag(BackendKind.googleSheets)
                Text("Local file").tag(BackendKind.localJSON)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch kind {
            case .googleSheets: GoogleSheetSetup { dismiss() }
            case .localJSON: LocalFileSetup { dismiss() }
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 580)
        .background(RunaColor.elevated)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }
}

struct GoogleSheetSetup: View {
    @Environment(AppModel.self) private var app
    let done: () -> Void
    @State private var link = ""
    @State private var accountEmail: String?
    @State private var importingKey = false
    @State private var checking = false
    @State private var inspection: GoogleSheetsBackend.Inspection?
    @State private var problem: String?
    @State private var projectName = ""
    @State private var sourceLocale: LocaleCode = "en"
    @State private var extraLocales = ""

    var spreadsheetID: String? { GoogleSheetsBackend.spreadsheetID(from: link) }

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            step(1, "Service account") {
                let accounts = app.serviceAccounts
                if accounts.isEmpty {
                    Text("Runa reads and writes the sheet as a Google service account you own. Create one in Google Cloud (enable the Google Sheets API, create a service account, add a JSON key), then add the key here. It is stored in your Keychain.")
                        .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Add Key File…") { importingKey = true }.buttonStyle(.runaPrimary)
                        Link("How to create one", destination: URL(string: "https://console.cloud.google.com/iam-admin/serviceaccounts")!)
                            .font(RunaFont.small)
                    }
                } else {
                    HStack {
                        Picker("", selection: Binding(get: { accountEmail ?? accounts.first?.clientEmail }, set: { accountEmail = $0 })) {
                            ForEach(accounts, id: \.clientEmail) { Text($0.clientEmail).tag(String?.some($0.clientEmail)) }
                        }
                        .labelsHidden()
                        Button("Add Key…") { importingKey = true }.buttonStyle(.runa(.ghost, size: .small))
                    }
                    if let email = accountEmail ?? accounts.first?.clientEmail {
                        HStack(spacing: 6) {
                            Text("Share your sheet with this address as an Editor:").font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(email, forType: .string)
                            } label: { Label("Copy", systemImage: "doc.on.doc").font(RunaFont.small) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            step(2, "Spreadsheet") {
                TextField("Paste the sheet's link from the browser", text: $link).textFieldStyle(.runa)
                    .onChange(of: link) { _, _ in inspection = nil; problem = nil }
                HStack {
                    Button(checking ? "Checking…" : "Connect") { check() }
                        .buttonStyle(.runaSecondary)
                        .disabled(spreadsheetID == nil || app.serviceAccounts.isEmpty || checking)
                    Link("Create a new sheet", destination: URL(string: "https://sheets.new")!).font(RunaFont.small)
                }
                if let problem { Text(problem).font(RunaFont.small).foregroundStyle(RunaColor.missing).fixedSize(horizontal: false, vertical: true) }
            }
            if let inspection { setupStep(inspection) }
        }
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let credentials = try app.saveServiceAccount(json: Data(contentsOf: url))
                accountEmail = credentials.clientEmail
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @ViewBuilder
    func setupStep(_ inspection: GoogleSheetsBackend.Inspection) -> some View {
        step(3, "Project") {
            switch inspection.state {
            case .empty:
                Text("“\(inspection.title)” has no strings yet. Runa will add a \"strings\" tab and a few hidden tabs for status, Figma links and history.")
                    .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                TextField("Project name", text: $projectName).textFieldStyle(.runa)
                HStack {
                    LocalePicker(title: "Source language", selection: $sourceLocale)
                    TextField("Other languages, e.g. sv, de, pl", text: $extraLocales).textFieldStyle(.runa)
                }
                Button("Set Up Sheet and Add") { setUp(inspection) }.buttonStyle(.runaPrimary).disabled(checking)
            case .adoptable(let locales, let keyCount, let missing):
                Text("Found \(keyCount) keys in \(locales.map { $0.displayName() }.joined(separator: ", ")). Runa will add \(missing.joined(separator: ", ")) without changing existing data.")
                    .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                if !locales.isEmpty {
                    LocalePicker(title: "Source language", selection: $sourceLocale, options: locales)
                }
                Button("Add Runa's Columns and Add") { setUp(inspection) }.buttonStyle(.runaPrimary).disabled(checking)
            case .ready(let locales, let keyCount):
                Text("“\(inspection.title)”: \(keyCount) keys in \(locales.count) languages.").font(RunaFont.body).foregroundStyle(RunaColor.textSecondary)
                Button("Add Project") { finish(name: inspection.title) }.buttonStyle(.runaPrimary)
            }
        }
    }

    func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: RunaSpacing.m) {
            Text("\(number)").font(RunaFont.smallMedium).foregroundStyle(RunaColor.textSecondary)
                .frame(width: 20, height: 20).background(Circle().fill(RunaColor.hover))
            VStack(alignment: .leading, spacing: RunaSpacing.s) {
                Text(title).font(RunaFont.bodyMedium).foregroundStyle(RunaColor.textPrimary)
                content()
            }
        }
    }

    var backend: GoogleSheetsBackend? {
        guard let id = spreadsheetID, let email = accountEmail ?? app.serviceAccounts.first?.clientEmail,
              let credentials = app.serviceAccount(email: email)
        else { return nil }
        return GoogleSheetsBackend(spreadsheetID: id, api: GoogleSheetsAPI(credentials: credentials))
    }

    func check() {
        guard let backend else { return }
        checking = true
        problem = nil
        Task {
            do {
                let result = try await backend.inspect()
                inspection = result
                if projectName.isEmpty { projectName = result.title }
                if case .adoptable(let locales, _, _) = result.state, let first = locales.first { sourceLocale = first }
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            checking = false
        }
    }

    func setUp(_ inspection: GoogleSheetsBackend.Inspection) {
        guard let backend else { return }
        checking = true
        let others = extraLocales.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { LocaleCode(rawValue: String($0)) }
            .filter(\.isKnownLanguage)
        Task {
            do {
                let snapshot = try await backend.setUp(projectName: projectName.isEmpty ? nil : projectName, sourceLocale: sourceLocale, locales: others,
                                                       context: PushContext(actor: app.settings.displayName, note: "setup"))
                finish(name: snapshot.settings.name)
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            checking = false
        }
    }

    func finish(name: String) {
        guard let id = spreadsheetID, let email = accountEmail ?? app.serviceAccounts.first?.clientEmail else { return }
        app.add(ProjectRecord(name: name, location: .googleSheets(spreadsheetID: id, serviceAccount: email)))
        done()
    }
}

struct LocalFileSetup: View {
    @Environment(AppModel.self) private var app
    let done: () -> Void
    @State private var name = "Strings"
    @State private var sourceLocale: LocaleCode = "en"
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            Text("A .runa.json file on your Mac, in iCloud Drive or in a repository. Good for trying Runa or for teams that keep strings in git.")
                .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary).fixedSize(horizontal: false, vertical: true)
            TextField("Project name", text: $name).textFieldStyle(.runa)
            LocalePicker(title: "Source language", selection: $sourceLocale)
            HStack {
                Button("Create File…") { create() }.buttonStyle(.runaPrimary)
                Button("Open Existing…") { open() }.buttonStyle(.runaSecondary)
                Spacer()
                Button("Demo Project") {
                    do {
                        app.add(try DemoProject.create())
                        done()
                    } catch { problem = error.localizedDescription }
                }
                .buttonStyle(.runa(.ghost))
            }
            if let problem { Text(problem).font(RunaFont.small).foregroundStyle(RunaColor.missing) }
        }
    }

    func create() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).runa.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            _ = try LocalJSONBackend.create(at: url, settings: ProjectSettings(name: name, sourceLocale: sourceLocale))
            app.add(ProjectRecord(name: name, location: .localJSON(path: url.path)))
            done()
        } catch {
            problem = error.localizedDescription
        }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let snapshot = try await LocalJSONBackend(url: url).pull()
                app.add(ProjectRecord(name: snapshot.settings.name, location: .localJSON(path: url.path)))
                done()
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct LocalePicker: View {
    let title: String
    @Binding var selection: LocaleCode
    var options: [LocaleCode] = AddLanguageSheet.common + ["en"]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Set(options + [selection])).sorted { $0.displayName() < $1.displayName() }, id: \.self) { locale in
                Text("\(locale.displayName()) (\(locale.rawValue))").tag(locale)
            }
        }
        .font(RunaFont.body)
        .fixedSize()
    }
}
