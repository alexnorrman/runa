import AppKit
import Foundation
import Observation
import RunaCore

/// App-wide state: the projects you added, settings, and credentials.
@MainActor @Observable
final class AppModel {
    var projects: [ProjectRecord] = []
    var selectedProjectID: UUID? {
        didSet { UserDefaults.standard.set(selectedProjectID?.uuidString, forKey: "selectedProject") }
    }
    var settings = AppSettings() {
        didSet { saveSettings() }
    }
    var isAddingProject = false
    var isShowingCommandPalette = false
    private var stores: [UUID: ProjectStore] = [:]

    init() {
        projects = Storage.load([ProjectRecord].self, from: Storage.projectsFile) ?? []
        if let data = UserDefaults.standard.data(forKey: "settings"), let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = saved
        }
        // `--demo` opens the demo project on a fresh install; handy for screenshots and trying Runa.
        if projects.isEmpty, CommandLine.arguments.contains("--demo"), let demo = try? DemoProject.create() {
            projects = [demo]
            saveProjects()
        }
        let saved = UserDefaults.standard.string(forKey: "selectedProject").flatMap(UUID.init(uuidString:))
        selectedProjectID = projects.first { $0.id == saved }?.id ?? projects.first?.id
        applyAppearance()
    }

    var selectedProject: ProjectRecord? { projects.first { $0.id == selectedProjectID } }

    var currentStore: ProjectStore? {
        guard let project = selectedProject else { return nil }
        return store(for: project)
    }

    func store(for project: ProjectRecord) -> ProjectStore {
        if let store = stores[project.id] { return store }
        let store = ProjectStore(record: project, app: self)
        stores[project.id] = store
        return store
    }

    func add(_ project: ProjectRecord) {
        projects.append(project)
        saveProjects()
        selectedProjectID = project.id
    }

    func update(_ project: ProjectRecord) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        saveProjects()
    }

    func remove(_ project: ProjectRecord) {
        projects.removeAll { $0.id == project.id }
        stores[project.id] = nil
        try? FileManager.default.removeItem(at: Storage.cacheFile(project.id))
        saveProjects()
        if selectedProjectID == project.id { selectedProjectID = projects.first?.id }
    }

    private func saveProjects() {
        Storage.save(projects, to: Storage.projectsFile)
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
        applyAppearance()
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp?.appearance = nil
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        }
    }

    // MARK: Credentials

    var serviceAccounts: [ServiceAccountCredentials] {
        Keychain.accounts(prefix: "google:").compactMap { account in
            Keychain.get(account).flatMap { try? ServiceAccountCredentials(json: $0) }
        }
    }

    func serviceAccount(email: String) -> ServiceAccountCredentials? {
        Keychain.get(Keychain.Account.google(email)).flatMap { try? ServiceAccountCredentials(json: $0) }
    }

    @discardableResult
    func saveServiceAccount(json: Data) throws -> ServiceAccountCredentials {
        let credentials = try ServiceAccountCredentials(json: json)
        try Keychain.set(try credentials.jsonData(), account: Keychain.Account.google(credentials.clientEmail))
        return credentials
    }

    func removeServiceAccount(email: String) {
        Keychain.delete(Keychain.Account.google(email))
    }

    func aiKey(for kind: AIProviderKind) -> String? {
        Keychain.string(Keychain.Account.ai(kind.rawValue))
    }

    func setAIKey(_ key: String, for kind: AIProviderKind) {
        if key.isEmpty {
            Keychain.delete(Keychain.Account.ai(kind.rawValue))
        } else {
            try? Keychain.setString(key, account: Keychain.Account.ai(kind.rawValue))
        }
    }

    var figmaToken: String? {
        get { Keychain.string(Keychain.Account.figma) }
        set {
            if let newValue, !newValue.isEmpty { try? Keychain.setString(newValue, account: Keychain.Account.figma) } else { Keychain.delete(Keychain.Account.figma) }
        }
    }

    /// The configured AI provider, or nil when none is set up.
    func translationProvider() throws -> (any TranslationProvider)? {
        guard let config = settings.ai, !config.model.isEmpty else { return nil }
        return try TranslationProviders.make(config, apiKey: aiKey(for: config.kind))
    }

    var aiProviderName: String? {
        guard let config = settings.ai, !config.model.isEmpty else { return nil }
        switch config.kind {
        case .anthropic: return "Claude"
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        case .openAICompatible: return config.model
        }
    }

    // MARK: Backends

    func backend(for project: ProjectRecord) throws -> any StringsBackend {
        switch project.location {
        case .googleSheets(let spreadsheetID, let email):
            guard let credentials = serviceAccount(email: email) else {
                throw BackendError.authenticationFailed("The service account key for \(email) is missing. Add it in Settings → Google.")
            }
            return GoogleSheetsBackend(spreadsheetID: spreadsheetID, api: GoogleSheetsAPI(credentials: credentials))
        case .localJSON(let path):
            return LocalJSONBackend(url: URL(fileURLWithPath: path))
        }
    }
}
