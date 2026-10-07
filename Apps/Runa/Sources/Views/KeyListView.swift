import RunaCore
import RunaDesign
import SwiftUI

struct KeyListView: View {
    @Environment(AppModel.self) private var app
    @Bindable var store: ProjectStore
    @State private var pendingDelete: [StringKey] = []

    var body: some View {
        let keys = store.visibleKeys
        VStack(spacing: 0) {
            header(count: keys.count)
            if case .all = store.filter, store.searchText.isEmpty, !store.missingByLocale.isEmpty {
                MissingBanner(store: store)
                    .padding(.horizontal, RunaSpacing.l)
                    .padding(.bottom, RunaSpacing.s)
            }
            HairlineDivider()
            if keys.isEmpty {
                emptyState
            } else {
                KeyTable(store: store, keys: keys, contextMenu: { key in AnyView(contextMenu(for: key)) }) {
                    pendingDelete = store.selection.compactMap { store.snapshot?[id: $0] }
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                store.perform(pendingDelete.map { .deleteKey(id: $0.id) })
                store.selection.subtract(pendingDelete.map(\.id))
                pendingDelete = []
            }
        } message: {
            Text("The key is removed in every language. History keeps a record of it.")
        }
    }

    var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete \(pendingDelete[0].key)?" : "Delete \(pendingDelete.count) keys?"
    }

    func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RunaSpacing.s) {
            Text(store.filter.title).runaTitle(RunaFont.title3)
            Text("\(count)").font(RunaFont.body).monospacedDigit().foregroundStyle(RunaColor.textTertiary)
            Spacer()
            if let snapshot = store.snapshot {
                HStack(spacing: 10) {
                    ForEach(snapshot.settings.targetLocales, id: \.self) { locale in
                        Text(locale.rawValue.uppercased())
                            .font(RunaFont.font(size: 9.5, weight: .semibold))
                            .foregroundStyle(RunaColor.textQuaternary)
                            .frame(width: 18)
                            .help(locale.displayName())
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.horizontal, RunaSpacing.l)
        .padding(.top, RunaSpacing.m)
        .padding(.bottom, RunaSpacing.s)
    }

    @ViewBuilder
    var emptyState: some View {
        if store.snapshot?.keys.isEmpty == true {
            EmptyStateView(systemImage: "character.bubble", title: "No strings yet",
                           message: "Add your first key, import existing strings files, or link text from Figma with the Runa plugin.") {
                HStack {
                    Button("New Key") { store.isCreatingKey = true }.buttonStyle(.runaPrimary)
                    Button("Import Files…") { store.sidebar = .importStrings }.buttonStyle(.runaSecondary)
                }
            }
        } else if !store.searchText.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass", title: "No matches", message: "Nothing matches “\(store.searchText)”.") {
                Button("New Key “\(store.searchText)”") { store.isCreatingKey = true }.buttonStyle(.runaSecondary)
            }
        } else {
            EmptyStateView(systemImage: "checkmark.circle", title: "All clear", message: "No keys match \(store.filter.title.lowercased()).") {
                Button("Show All Keys") { store.sidebar = .keys(.all) }.buttonStyle(.runaSecondary)
            }
        }
    }

    @ViewBuilder
    func contextMenu(for key: StringKey) -> some View {
        let ids = store.selection.contains(key.id) ? Array(store.selection) : [key.id]
        Button("Copy Key") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key.key, forType: .string)
        }
        Button("Translate…") {
            store.translateScope = .init(keyIDs: ids, locales: store.snapshot?.settings.targetLocales ?? [])
        }
        if let url = key.contexts.first.flatMap({ URL(string: $0.url) }) {
            Button("Open in Figma") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            pendingDelete = ids.compactMap { store.snapshot?[id: $0] }
        }
    }
}

/// The key list. Selection is drawn by Runa (a quiet highlight, as in Linear) rather than the
/// system's accent bar, and supports click, ⌘-click, ⇧-click and the arrow keys.
struct KeyTable: View {
    @Bindable var store: ProjectStore
    let keys: [StringKey]
    let contextMenu: (StringKey) -> AnyView
    let onDelete: () -> Void
    @State private var anchor: UUID?
    @State private var hovered: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(keys) { key in
                        let selected = store.selection.contains(key.id)
                        KeyRow(key: key, snapshot: store.snapshot!)
                            .background(
                                RoundedRectangle(cornerRadius: RunaRadius.control)
                                    .fill(selected ? (focused ? RunaColor.selected : RunaColor.hover) : hovered == key.id ? RunaColor.hover.opacity(0.6) : .clear)
                            )
                            .overlay(alignment: .leading) {
                                if selected && focused {
                                    RoundedRectangle(cornerRadius: 1).fill(RunaColor.accent).frame(width: 2, height: 16).padding(.leading, 1)
                                }
                            }
                            .padding(.horizontal, 6)
                            .id(key.id)
                            .onHover { hovered = $0 ? key.id : (hovered == key.id ? nil : hovered) }
                            .onTapGesture { click(key) }
                            .contextMenu { contextMenu(key) }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                move(by: 1, extend: press.modifiers.contains(.shift), proxy: proxy)
                return .handled
            }
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                move(by: -1, extend: press.modifiers.contains(.shift), proxy: proxy)
                return .handled
            }
            .onKeyPress(.escape) {
                store.selection = []
                return .handled
            }
            .onDeleteCommand(perform: onDelete)
            .onAppear { focused = true }
        }
    }

    func click(_ key: StringKey) {
        focused = true
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if store.selection.contains(key.id) { store.selection.remove(key.id) } else { store.selection.insert(key.id) }
            anchor = key.id
        } else if modifiers.contains(.shift), let anchor, let from = keys.firstIndex(where: { $0.id == anchor }),
                  let to = keys.firstIndex(where: { $0.id == key.id })
        {
            store.selection = Set(keys[min(from, to)...max(from, to)].map(\.id))
        } else {
            store.selection = [key.id]
            anchor = key.id
        }
    }

    func move(by offset: Int, extend: Bool, proxy: ScrollViewProxy) {
        guard !keys.isEmpty else { return }
        let current = keys.firstIndex { store.selection.contains($0.id) && $0.id == (extend ? lastExtended : anchor) }
            ?? keys.firstIndex { store.selection.contains($0.id) }
        let next = max(0, min(keys.count - 1, (current ?? (offset > 0 ? -1 : keys.count)) + offset))
        let id = keys[next].id
        if extend {
            store.selection.insert(id)
            lastExtended = id
        } else {
            store.selection = [id]
            anchor = id
            lastExtended = id
        }
        withAnimation(RunaMotion.quick) { proxy.scrollTo(id) }
    }

    @State private var lastExtended: UUID?
}

struct KeyRow: View {
    let key: StringKey
    let snapshot: Snapshot

    var body: some View {
        let source = snapshot.settings.sourceLocale
        let text = key.isPlural ? (key.value(for: source, .other) ?? key.value(for: source, .one)) : key.value(for: source)
        HStack(spacing: RunaSpacing.m) {
            Text(key.key)
                .font(RunaFont.keyName)
                .foregroundStyle(RunaColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 280, alignment: .leading)
            Group {
                if let text {
                    PlaceholderText(text, color: RunaColor.textTertiary)
                } else {
                    Text("No source text").font(RunaFont.body).foregroundStyle(RunaColor.missing)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if key.isPlural { Chip("plural") }
                if key.doNotTranslate { Chip("fixed", systemImage: "lock.fill") }
                if !key.contexts.isEmpty {
                    Image(systemName: "paintbrush.pointed.fill").font(.system(size: 10)).foregroundStyle(RunaColor.textQuaternary)
                        .help("Linked to Figma")
                }
            }
            HStack(spacing: 10) {
                ForEach(snapshot.settings.targetLocales, id: \.self) { locale in
                    StatusDot(snapshot.status(of: key, locale: locale))
                        .frame(width: 18)
                        .help("\(locale.displayName()): \(snapshot.status(of: key, locale: locale).displayName)")
                }
            }
        }
        .padding(.horizontal, RunaSpacing.s)
        .frame(height: 34)
        .contentShape(Rectangle())
    }
}

struct MissingBanner: View {
    @Environment(AppModel.self) private var app
    let store: ProjectStore

    var body: some View {
        let missing = store.missingByLocale
        let summary = missing.prefix(3).map { "\($0.count) in \($0.locale.displayName())" }.joined(separator: ", ")
        let total = Set(store.keys(matching: .missing(nil)).map(\.id)).count
        Banner(.warning, title: "\(total) \(total == 1 ? "key is" : "keys are") missing translations", message: summary + (missing.count > 3 ? ", …" : "")) {
            Button("Show") { store.sidebar = .keys(.missing(nil)) }.buttonStyle(.runa(.ghost, size: .small))
            if let provider = app.aiProviderName {
                Button {
                    store.translateScope = .init(keyIDs: nil, locales: missing.map(\.locale))
                } label: {
                    Label("Translate with \(provider)", systemImage: "sparkles")
                }
                .buttonStyle(.runa(.primary, size: .small))
            } else {
                SettingsLink { Label("Set Up AI Translation", systemImage: "sparkles") }.buttonStyle(.runa(.secondary, size: .small))
            }
        }
    }
}
