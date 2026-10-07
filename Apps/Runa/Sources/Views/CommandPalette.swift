import RunaCore
import RunaDesign
import SwiftUI

/// ⌘K: jump to any key or run a command.
struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    let store: ProjectStore
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let icon: String
        let action: @MainActor () -> Void
    }

    var entries: [Entry] {
        var commands: [Entry] = [
            Entry(id: "new", title: "New key", subtitle: "⌘N", icon: "plus") { store.isCreatingKey = true },
            Entry(id: "sync", title: "Sync now", subtitle: "⌘R", icon: "arrow.triangle.2.circlepath") { Task { await store.refresh() } },
            Entry(id: "translate", title: "Translate missing strings", subtitle: "⇧⌘T", icon: "sparkles") {
                store.translateScope = .init(keyIDs: nil, locales: store.missingByLocale.map(\.locale))
            },
            Entry(id: "review", title: "Review drafts", subtitle: "\(store.reviewCount) waiting", icon: "checkmark.circle") { store.sidebar = .review },
            Entry(id: "missing", title: "Show missing translations", subtitle: nil, icon: "circle.dashed") { store.sidebar = .keys(.missing(nil)) },
            Entry(id: "languages", title: "Languages", subtitle: nil, icon: "globe") { store.sidebar = .languages },
            Entry(id: "import", title: "Import strings files", subtitle: nil, icon: "square.and.arrow.down") { store.sidebar = .importStrings },
            Entry(id: "export", title: "Export strings files", subtitle: nil, icon: "square.and.arrow.up") { store.isExporting = true },
            Entry(id: "activity", title: "Activity", subtitle: nil, icon: "clock") { store.sidebar = .activity },
            Entry(id: "project", title: "Add project", subtitle: nil, icon: "folder.badge.plus") { app.isAddingProject = true },
        ]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            commands = commands.filter { KeySearch.score(trimmed.lowercased(), $0.title.lowercased(), weight: 1) > 0 }
        }
        var keys: [Entry] = []
        if let snapshot = store.snapshot, !trimmed.isEmpty {
            keys = KeySearch.search(trimmed, in: snapshot, limit: 8).map { key in
                Entry(id: key.id.uuidString, title: key.key, subtitle: key.value(for: snapshot.settings.sourceLocale) ?? key.value(for: snapshot.settings.sourceLocale, .one),
                      icon: "character.textbox") {
                    store.sidebar = .keys(.all)
                    store.searchText = ""
                    store.selection = [key.id]
                    store.showInspector = true
                }
            }
        }
        return Array((keys + commands).prefix(12))
    }

    var body: some View {
        let items = entries
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: RunaSpacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(RunaColor.textTertiary)
                    TextField("Type a command or search keys…", text: $query)
                        .textFieldStyle(.plain)
                        .font(RunaFont.font(size: 15))
                        .focused($focused)
                        .onSubmit { run(items) }
                        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(RunaSpacing.m)
                HairlineDivider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: RunaSpacing.s) {
                                Image(systemName: entry.icon).frame(width: 18).foregroundStyle(RunaColor.textTertiary)
                                Text(entry.title).font(entry.icon == "character.textbox" ? RunaFont.keyName : RunaFont.body)
                                    .foregroundStyle(RunaColor.textPrimary).lineLimit(1)
                                Spacer()
                                if let subtitle = entry.subtitle {
                                    Text(subtitle).font(RunaFont.small).foregroundStyle(RunaColor.textTertiary).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, RunaSpacing.s)
                            .frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(index == highlighted ? RunaColor.selected : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                highlighted = index
                                run(items)
                            }
                        }
                    }
                    .padding(RunaSpacing.xs)
                }
                .frame(maxHeight: 380)
            }
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: RunaRadius.sheet).fill(RunaColor.elevated))
            .overlay(RoundedRectangle(cornerRadius: RunaRadius.sheet).strokeBorder(RunaColor.borderStrong))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    func run(_ items: [Entry]) {
        guard items.indices.contains(highlighted) else { return }
        let action = items[highlighted].action
        close()
        action()
    }

    func close() {
        app.isShowingCommandPalette = false
    }
}
