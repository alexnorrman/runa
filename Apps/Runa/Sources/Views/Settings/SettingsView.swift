import RunaCore
import RunaDesign
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            GoogleSettings().tabItem { Label("Google", systemImage: "tablecells") }
            FigmaSettings().tabItem { Label("Figma", systemImage: "paintbrush.pointed") }
            CommandLineSettings().tabItem { Label("Command Line", systemImage: "terminal") }
        }
        .frame(width: 600)
        .font(RunaFont.body)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            TextField("Your name", text: $app.settings.displayName)
            Text("Shown in history next to your changes.").font(RunaFont.small).foregroundStyle(.secondary)
            Picker("Appearance", selection: $app.settings.appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("Sync every \(app.settings.autoSyncMinutes) min", value: $app.settings.autoSyncMinutes, in: 1...30)
        }
        .formStyle(.grouped)
        .frame(height: 240)
    }
}

struct AISettings: View {
    @Environment(AppModel.self) private var app
    @State private var kind = AIProviderKind.anthropic
    @State private var apiKey = ""
    @State private var model = ""
    @State private var baseURL = "http://localhost:11434/v1"
    @State private var effort = "medium"
    @State private var sendImages = true
    @State private var models: [String] = []
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Picker("Provider", selection: $kind) {
                ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: kind) { _, newKind in load(newKind) }
            if kind.needsBaseURL {
                TextField("Server address", text: $baseURL)
                Text("Ollama: http://localhost:11434/v1 · LM Studio: http://localhost:1234/v1 · OpenRouter: https://openrouter.ai/api/v1")
                    .font(RunaFont.small).foregroundStyle(.secondary)
            }
            SecureField(kind.needsAPIKey ? "API key" : "API key (optional)", text: $apiKey)
            HStack {
                if models.isEmpty {
                    TextField("Model", text: $model)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(Array(Set(models + [model])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Button(testing ? "Checking…" : "Load Models") { test() }.disabled(testing || (kind.needsAPIKey && apiKey.isEmpty))
            }
            if kind == .anthropic {
                Picker("Effort", selection: $effort) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)
                Text("Medium suits UI strings. Requests use server-side fallback, so a declined batch is retried on another Claude model instead of failing.")
                    .font(RunaFont.small).foregroundStyle(.secondary)
            }
            Toggle("Send Figma screenshots as context", isOn: $sendImages)
            if let status { Text(status).font(RunaFont.small).foregroundStyle(status.hasPrefix("✓") ? .green : .red) }
            HStack {
                if app.settings.ai != nil {
                    Button("Disconnect", role: .destructive) {
                        app.settings.ai = nil
                        status = nil
                    }
                }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(model.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .onAppear {
            if let config = app.settings.ai {
                kind = config.kind
                model = config.model
                baseURL = config.baseURL ?? baseURL
                effort = config.effort ?? "medium"
                sendImages = config.sendImages
                apiKey = app.aiKey(for: config.kind) ?? ""
            } else {
                load(kind)
            }
        }
    }

    func load(_ kind: AIProviderKind) {
        apiKey = app.aiKey(for: kind) ?? ""
        model = app.settings.ai?.kind == kind ? app.settings.ai?.model ?? "" : kind.defaultModel ?? ""
        models = []
        status = nil
        sendImages = kind != .openAICompatible
    }

    var config: AIProviderConfig {
        AIProviderConfig(kind: kind, model: model, baseURL: kind.needsBaseURL ? baseURL : nil, effort: kind == .anthropic ? effort : nil, sendImages: sendImages)
    }

    func test() {
        testing = true
        status = nil
        Task {
            do {
                let provider = try TranslationProviders.make(config, apiKey: apiKey)
                let found = try await provider.availableModels()
                models = found
                if model.isEmpty || !found.contains(model) { model = kind.defaultModel.flatMap { found.contains($0) ? $0 : nil } ?? found.first ?? model }
                status = "✓ Connected. \(found.count) models available."
            } catch {
                status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            testing = false
        }
    }

    func save() {
        app.setAIKey(apiKey, for: kind)
        app.settings.ai = config
        status = "✓ Saved. Translate from the toolbar or any language section."
    }
}

struct GoogleSettings: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var dropping = false
    @State private var problem: String?
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(app.serviceAccounts, id: \.clientEmail) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.clientEmail).font(RunaFont.body)
                            Text(account.projectID ?? "").font(RunaFont.small).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            app.removeServiceAccount(email: account.clientEmail)
                            refresh += 1
                        }
                    }
                }
                HStack {
                    Button("Add Service Account Key…") { importing = true }
                    Text(dropping ? "Drop to add the key" : "or drop a JSON key file anywhere here")
                        .font(RunaFont.small).foregroundStyle(dropping ? RunaColor.accent : .secondary)
                }
            } header: {
                Text("Service accounts")
            } footer: {
                Text("Keys are stored in your Keychain. Share each sheet with the account's email as an Editor. Removing the account from the sheet's sharing settings cuts off access immediately.")
                    .font(RunaFont.small).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).foregroundStyle(.red).font(RunaFont.small) }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .id(refresh)
        .overlay {
            RoundedRectangle(cornerRadius: RunaRadius.sheet)
                .strokeBorder(RunaColor.accent, lineWidth: 1.5)
                .padding(RunaSpacing.s)
                .opacity(dropping ? 1 : 0)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "json" }) ?? (urls.count == 1 ? urls.first : nil) else { return false }
            addKey(from: url)
            return true
        } isTargeted: { dropping = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            addKey(from: url)
        }
    }

    /// Reads a key file from the picker or a drop and stores it in the Keychain.
    func addKey(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try app.saveServiceAccount(json: Data(contentsOf: url))
            refresh += 1
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct FigmaSettings: View {
    @Environment(AppModel.self) private var app
    @State private var token = ""
    @State private var status: String?

    var body: some View {
        Form {
            SecureField("Personal access token", text: $token)
            Text("Used only to render screenshots of linked frames, for you and as AI context. Create a token in Figma under Settings → Security with \"File content: read\".")
                .font(RunaFont.small).foregroundStyle(.secondary)
            if let status { Text(status).font(RunaFont.small).foregroundStyle(status.hasPrefix("✓") ? .green : .red) }
            HStack {
                Spacer()
                Button("Save") {
                    app.figmaToken = token
                    Task { await verify() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
        .onAppear { token = app.figmaToken ?? "" }
    }

    func verify() async {
        guard !token.isEmpty else { status = nil; return }
        var request = URLRequest(url: URL(string: "https://api.figma.com/v1/me")!)
        request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        let result = try? await URLSession.shared.data(for: request)
        let code = (result?.1 as? HTTPURLResponse)?.statusCode
        if code == 200, let data = result?.0, let json = try? JSONValue.parse(data) {
            status = "✓ Signed in as \(json["handle"]?.stringValue ?? json["email"]?.stringValue ?? "Figma user")."
        } else {
            status = "Figma did not accept the token\(code.map { " (\($0))" } ?? "")."
        }
    }
}

struct CommandLineSettings: View {
    @Environment(AppModel.self) private var app
    @State private var installed = CLIInstaller.isInstalled
    @State private var message: String?

    var body: some View {
        Form {
            Section("runa") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installed ? "Installed at \(CLIInstaller.installedLink.path)" : "Not installed").font(RunaFont.body)
                        Text("`runa pull` writes platform files from runa.yml; `runa check` fails CI on missing translations.")
                            .font(RunaFont.small).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installed {
                        Button("Uninstall") {
                            CLIInstaller.uninstall()
                            installed = CLIInstaller.isInstalled
                        }
                    } else {
                        Button("Install") { install() }
                    }
                }
                if installed && !CLIInstaller.isOnPath {
                    Text("Add ~/.local/bin to your PATH, for example: echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc")
                        .font(RunaFont.small).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Section("Google credentials for the CLI") {
                ForEach(app.serviceAccounts, id: \.clientEmail) { account in
                    HStack {
                        Text(account.clientEmail).font(RunaFont.small)
                        Spacer()
                        Button("Use for CLI") {
                            do {
                                try CredentialStore.saveDefault(account)
                                message = "Saved to \(CredentialStore.defaultURL.path) (readable only by you)."
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
                Text("CI should use the RUNA_GOOGLE_CREDENTIALS secret instead.").font(RunaFont.small).foregroundStyle(.secondary)
            }
            Section("MCP for coding agents") {
                Text("claude mcp add runa -- runa mcp").font(RunaFont.mono(size: 12)).textSelection(.enabled)
                Text("Other clients:").font(RunaFont.small).foregroundStyle(.secondary)
                Text(CLIInstaller.mcpConfigJSON(configPath: nil)).font(RunaFont.mono(size: 11)).textSelection(.enabled)
            }
            if let message { Text(message).font(RunaFont.small) }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    func install() {
        do {
            try CLIInstaller.install()
            installed = CLIInstaller.isInstalled
            message = "Installed. Open a new terminal and run `runa --help`."
        } catch {
            message = error.localizedDescription
        }
    }
}
