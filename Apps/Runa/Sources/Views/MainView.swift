import RunaCore
import RunaDesign
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let store = app.currentStore {
                ProjectView(store: store)
                    .id(store.record.id)
            } else {
                WelcomeView()
            }
        }
        .background(RunaColor.appBackground)
        .sheet(isPresented: $app.isAddingProject) {
            AddProjectSheet()
        }
        .overlay {
            if app.isShowingCommandPalette, let store = app.currentStore {
                CommandPalette(store: store)
            }
        }
    }
}

struct ProjectView: View {
    @Environment(AppModel.self) private var app
    @Bindable var store: ProjectStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            detail
                .background(RunaColor.appBackground)
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search keys and text")
        .toolbar { toolbar }
        .sheet(isPresented: $store.isCreatingKey) { NewKeySheet(store: store) }
        .sheet(item: $store.translateScope) { scope in TranslateSheet(store: store, scope: scope) }
        .sheet(isPresented: $store.isExporting) { ExportSheet(store: store) }
        .sheet(isPresented: Binding(get: { !store.conflicts.isEmpty }, set: { if !$0 { store.conflicts = [] } })) {
            ConflictsSheet(store: store)
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    var detail: some View {
        if store.snapshot == nil {
            loading
        } else {
            switch store.sidebar {
            case .keys:
                KeyListView(store: store)
                    .inspector(isPresented: $store.showInspector) {
                        KeyInspector(store: store)
                            .inspectorColumnWidth(min: 340, ideal: 420, max: 680)
                    }
            case .review: ReviewView(store: store)
            case .languages: LanguagesView(store: store)
            case .activity: ActivityView(store: store)
            case .importStrings: ImportView(store: store)
            }
        }
    }

    @ViewBuilder
    var loading: some View {
        switch store.syncState {
        case .failed(let message):
            EmptyStateView(systemImage: "exclamationmark.icloud", title: "Could not open \(store.record.name)", message: message) {
                HStack {
                    Button("Try Again") { Task { await store.refresh() } }.buttonStyle(.runaPrimary)
                    SettingsLink { Text("Open Settings") }.buttonStyle(.runaSecondary)
                }
            }
        default:
            VStack(spacing: RunaSpacing.m) {
                ProgressView().controlSize(.small)
                Text("Loading \(store.record.name)…").font(RunaFont.body).foregroundStyle(RunaColor.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            SyncIndicator(store: store)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.translateScope = .init(keyIDs: store.selection.isEmpty ? nil : Array(store.selection),
                                             locales: store.missingByLocale.map(\.locale))
            } label: {
                Label("Translate", systemImage: "sparkles")
            }
            .help(app.aiProviderName.map { "Translate with \($0) (⇧⌘T)" } ?? "Set up AI translation in Settings")
            .disabled(store.snapshot == nil)

            Button { store.isCreatingKey = true } label: { Label("New Key", systemImage: "plus") }
                .help("New key (⌘N)")
                .disabled(store.snapshot == nil)
        }
    }
}

struct SyncIndicator: View {
    let store: ProjectStore

    var body: some View {
        HStack(spacing: 6) {
            switch store.syncState {
            case .pulling, .pushing:
                ProgressView().controlSize(.mini)
                Text(store.syncState == .pushing ? "Saving…" : "Syncing…")
            case .failed(let message):
                Circle().fill(RunaColor.missing).frame(width: 6, height: 6)
                Text(store.pending.isEmpty ? "Offline" : "Offline · \(store.pending.count) unsaved")
                    .help(message)
            case .idle:
                Circle().fill(store.pending.isEmpty ? RunaColor.approved : RunaColor.review).frame(width: 6, height: 6)
                if let date = store.lastSynced {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(store.pending.isEmpty ? "Synced \(date.formatted(.relative(presentation: .named)))" : "\(store.pending.count) unsaved")
                    }
                } else {
                    Text("Not synced")
                }
            }
        }
        .font(RunaFont.small)
        .foregroundStyle(RunaColor.textTertiary)
        .padding(.horizontal, 8)
        .onTapGesture { Task { await store.refresh() } }
        .help("Sync now (⌘R)")
    }
}
