import RunaCore
import RunaDesign
import SwiftUI

struct KeyInspector: View {
    @Bindable var store: ProjectStore

    var body: some View {
        Group {
            if let key = store.selectedKey, let snapshot = store.snapshot {
                KeyDetailView(store: store, key: key, snapshot: snapshot)
                    .id(key.id)
            } else if store.selection.count > 1 {
                MultiSelectionView(store: store)
            } else {
                EmptyStateView(systemImage: "sidebar.right", title: "No key selected", message: "Select a key to edit it in every language.") {
                    EmptyView()
                }
            }
        }
        .background(RunaColor.panel)
    }
}

struct MultiSelectionView: View {
    let store: ProjectStore

    var body: some View {
        let ids = Array(store.selection)
        let drafts = ids.flatMap { id -> [Change] in
            guard let snapshot = store.snapshot, let key = snapshot[id: id] else { return [] }
            return snapshot.settings.targetLocales.compactMap { locale in
                let status = snapshot.status(of: key, locale: locale)
                return status == .machine || status == .needsReview ? .setStatus(id: id, locale: locale, status: .approved) : nil
            }
        }
        EmptyStateView(systemImage: "square.stack.3d.up", title: "\(ids.count) keys selected", message: "Act on all of them at once.") {
            VStack(spacing: RunaSpacing.s) {
                Button {
                    store.translateScope = .init(keyIDs: ids, locales: store.snapshot?.settings.targetLocales ?? [])
                } label: { Label("Translate…", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .buttonStyle(.runaPrimary)
                Button {
                    store.perform(drafts)
                } label: { Label("Approve \(drafts.count) drafts", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(.runaSecondary)
                    .disabled(drafts.isEmpty)
            }
            .frame(width: 220)
        }
    }
}

struct KeyDetailView: View {
    @Environment(AppModel.self) private var app
    let store: ProjectStore
    let key: StringKey
    let snapshot: Snapshot
    @State private var name = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var nameProblem: String?
    @State private var history: [HistoryEntry] = []
    @State private var translating: Set<LocaleCode> = []
    @State private var confirmDelete = false

    var source: LocaleCode { snapshot.settings.sourceLocale }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RunaSpacing.l) {
                header
                metadata
                if !key.contexts.isEmpty {
                    VStack(alignment: .leading, spacing: RunaSpacing.s) {
                        SectionLabel("Figma")
                        ForEach(key.contexts, id: \.url) { context in FigmaContextCard(context: context) }
                    }
                }
                LocaleSection(store: store, key: key, snapshot: snapshot, locale: source, translating: false, onTranslate: nil)
                ForEach(snapshot.settings.targetLocales, id: \.self) { locale in
                    LocaleSection(store: store, key: key, snapshot: snapshot, locale: locale, translating: translating.contains(locale)) {
                        translate(locale)
                    }
                }
                historySection
            }
            .padding(RunaSpacing.l)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: load)
        .task(id: key.id) { history = await store.loadHistory(keyID: key.id) }
        .confirmationDialog("Delete \(key.key)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                store.perform([.deleteKey(id: key.id)])
                store.selection = []
            }
        } message: {
            Text("The key is removed in every language.")
        }
    }

    func load() {
        name = key.key
        description = key.description
        tags = key.tags.filter { $0 != StringKey.doNotTranslateTag }.joined(separator: ", ")
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: RunaSpacing.s) {
                TextField("key.name", text: $name)
                    .textFieldStyle(.plain)
                    .font(RunaFont.mono(size: 15, weight: .medium))
                    .foregroundStyle(RunaColor.textPrimary)
                    .onSubmit(commitName)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key.key, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.runa(.ghost, size: .small))
                    .help("Copy key")
                Menu {
                    Button("Delete Key…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button)
                    .buttonStyle(.runa(.ghost, size: .small))
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            if let nameProblem {
                Text(nameProblem).font(RunaFont.small).foregroundStyle(RunaColor.missing)
            }
            TextField("Add context for translators: where it appears and what it means", text: $description, axis: .vertical)
                .textFieldStyle(.plain)
                .font(RunaFont.body)
                .foregroundStyle(RunaColor.textSecondary)
                .lineLimit(1...6)
                .onSubmit(commitMetadata)
                .onChange(of: description) { _, _ in scheduleMetadataCommit() }
        }
    }

    @State private var metadataTask: Task<Void, Never>?

    func scheduleMetadataCommit() {
        metadataTask?.cancel()
        metadataTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            commitMetadata()
        }
    }

    var metadata: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.s) {
            HStack(spacing: RunaSpacing.s) {
                Toggle("Plural", isOn: Binding(get: { key.isPlural }, set: { setPlural($0) }))
                    .toggleStyle(.runaCheckbox).font(RunaFont.small)
                Toggle("Don't translate", isOn: Binding(get: { key.doNotTranslate }, set: { setDoNotTranslate($0) }))
                    .toggleStyle(.runaCheckbox).font(RunaFont.small)
                    .help("Every language uses the source text, for brand names and the like")
                Spacer()
                ForEach(Platform.allCases, id: \.self) { platform in
                    let on = key.platforms.isEmpty || key.platforms.contains(platform)
                    Button { togglePlatform(platform) } label: {
                        Text(platform.displayName).font(RunaFont.mini)
                            .foregroundStyle(on ? RunaColor.textPrimary : RunaColor.textQuaternary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: RunaRadius.chip).fill(on ? RunaColor.hover : .clear))
                            .overlay(RoundedRectangle(cornerRadius: RunaRadius.chip).strokeBorder(RunaColor.borderSubtle))
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Included in \(platform.displayName) exports" : "Left out of \(platform.displayName) exports")
                }
            }
            HStack(spacing: RunaSpacing.s) {
                Image(systemName: "number").font(.system(size: 10)).foregroundStyle(RunaColor.textTertiary)
                TextField("Tags, comma separated", text: $tags)
                    .textFieldStyle(.plain).font(RunaFont.small).foregroundStyle(RunaColor.textSecondary)
                    .onSubmit(commitMetadata)
            }
        }
        .padding(RunaSpacing.s)
        .background(RoundedRectangle(cornerRadius: RunaRadius.card).fill(RunaColor.elevated))
        .overlay(RoundedRectangle(cornerRadius: RunaRadius.card).strokeBorder(RunaColor.borderSubtle))
    }

    var historySection: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.s) {
            SectionLabel("History")
            if history.isEmpty {
                Text("No changes recorded yet.").font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
            }
            ForEach(history.prefix(25)) { entry in
                HistoryRow(entry: entry, showKey: false)
            }
        }
    }

    // MARK: Actions

    func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != key.key else { nameProblem = nil; return }
        if let problem = KeyNaming.problem(with: trimmed) {
            nameProblem = problem
            return
        }
        if snapshot.key(named: trimmed) != nil {
            nameProblem = "Another key is already called \(trimmed)."
            return
        }
        nameProblem = nil
        var metadata = key.metadata
        metadata.key = trimmed
        store.perform([.updateKey(id: key.id, metadata: metadata)])
    }

    func commitMetadata() {
        var metadata = key.metadata
        metadata.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var newTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if key.doNotTranslate { newTags.append(StringKey.doNotTranslateTag) }
        metadata.tags = newTags
        guard metadata.description != key.description || Set(metadata.tags) != Set(key.tags) else { return }
        store.perform([.updateKey(id: key.id, metadata: metadata)])
    }

    func setPlural(_ plural: Bool) {
        var metadata = key.metadata
        metadata.isPlural = plural
        store.perform([.updateKey(id: key.id, metadata: metadata)])
    }

    func setDoNotTranslate(_ on: Bool) {
        var metadata = key.metadata
        metadata.tags.removeAll { $0 == StringKey.doNotTranslateTag }
        if on { metadata.tags.append(StringKey.doNotTranslateTag) }
        store.perform([.updateKey(id: key.id, metadata: metadata)])
    }

    func togglePlatform(_ platform: Platform) {
        var metadata = key.metadata
        var platforms = Set(metadata.platforms.isEmpty ? Platform.allCases : metadata.platforms)
        if platforms.contains(platform) { platforms.remove(platform) } else { platforms.insert(platform) }
        if platforms.isEmpty { return }
        metadata.platforms = platforms.count == Platform.allCases.count ? [] : platforms.sorted()
        store.perform([.updateKey(id: key.id, metadata: metadata)])
    }

    func translate(_ locale: LocaleCode) {
        guard !translating.contains(locale) else { return }
        translating.insert(locale)
        Task {
            await store.translate(keyIDs: [key.id], locales: [locale], overwrite: true, app: app)
            translating.remove(locale)
        }
    }
}

/// One language of a key: status, editors for each plural form, approve and translate actions.
struct LocaleSection: View {
    @Environment(AppModel.self) private var app
    let store: ProjectStore
    let key: StringKey
    let snapshot: Snapshot
    let locale: LocaleCode
    let translating: Bool
    let onTranslate: (() -> Void)?

    var isSource: Bool { locale == snapshot.settings.sourceLocale }

    var body: some View {
        let status = snapshot.status(of: key, locale: locale)
        let translation = key.translations[locale]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: RunaSpacing.s) {
                StatusDot(status)
                Text(locale.displayName()).font(RunaFont.bodyMedium).foregroundStyle(RunaColor.textPrimary)
                Text(isSource ? "source" : status.displayName.lowercased())
                    .font(RunaFont.small).foregroundStyle(isSource ? RunaColor.textQuaternary : status.color)
                if let by = translation?.updatedBy, !isSource {
                    Text("· \(by)").font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary).lineLimit(1)
                }
                Spacer()
                if !isSource, status == .machine || status == .needsReview {
                    Button {
                        store.perform([.setStatus(id: key.id, locale: locale, status: .approved)])
                    } label: { Label("Approve", systemImage: "checkmark") }
                        .buttonStyle(.runa(.secondary, size: .small))
                        .keyboardShortcut(.return, modifiers: .command)
                }
                if let onTranslate, !key.doNotTranslate {
                    Button(action: onTranslate) {
                        if translating { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                    }
                    .buttonStyle(.runa(.ghost, size: .small))
                    .disabled(app.aiProviderName == nil || translating)
                    .help(app.aiProviderName.map { "Translate with \($0)" } ?? "Set up AI translation in Settings")
                }
            }
            if key.doNotTranslate && !isSource {
                Text(key.value(for: snapshot.settings.sourceLocale) ?? "")
                    .font(RunaFont.body).foregroundStyle(RunaColor.textTertiary)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: RunaRadius.control).strokeBorder(RunaColor.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .help("Uses the source text in every language")
            } else if key.isPlural {
                let required = PluralRules.requiredCategories(for: locale)
                let all = PluralRules.categories(for: locale)
                ForEach(all, id: \.self) { category in
                    HStack(alignment: .top, spacing: RunaSpacing.s) {
                        Text(category.rawValue)
                            .font(RunaFont.small)
                            .foregroundStyle(required.contains(category) ? RunaColor.textTertiary : RunaColor.textQuaternary)
                            .frame(width: 40, alignment: .trailing)
                            .padding(.top, 8)
                            .help(required.contains(category) ? "" : "Optional: only used for large or decimal numbers")
                        FormEditor(store: store, key: key, locale: locale, category: category, isSource: isSource)
                    }
                }
            } else {
                FormEditor(store: store, key: key, locale: locale, category: .other, isSource: isSource)
            }
        }
    }
}

/// An editor for one form that saves when you press Return or leave the field, and picks up
/// remote changes while you are not typing.
struct FormEditor: View {
    let store: ProjectStore
    let key: StringKey
    let locale: LocaleCode
    let category: PluralCategory
    let isSource: Bool
    @State private var text = ""
    @State private var loaded = false

    var stored: String { key.translations[locale]?.forms[category] ?? "" }

    var body: some View {
        RunaTextEditor(isSource ? "Source text" : "Translation", text: $text, isRightToLeft: locale.isRightToLeft) { commit() }
            .onAppear {
                if !loaded {
                    text = stored
                    loaded = true
                }
            }
            .onChange(of: stored) { _, newValue in text = newValue }
            .onDisappear { commit() }
            .overlay(alignment: .bottomTrailing) {
                if let problem = placeholderProblem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(RunaColor.review)
                        .padding(6)
                        .help(problem)
                }
            }
    }

    var placeholderProblem: String? {
        guard !isSource, !text.isEmpty, let snapshot = store.snapshot else { return nil }
        let expected = Set(CanonicalText.placeholders(in: key.translations[snapshot.settings.sourceLocale]?.forms[category]
                ?? key.translations[snapshot.settings.sourceLocale]?.forms[.other] ?? "").map(\.canonical))
        let found = Set(CanonicalText.placeholders(in: text).map(\.canonical))
        let missing = expected.subtracting(found).filter { !(key.isPlural && $0.hasSuffix(":int}")) }
        let extra = found.subtracting(expected)
        if !missing.isEmpty { return "Missing \(missing.sorted().joined(separator: ", "))" }
        if !extra.isEmpty { return "\(extra.sorted().joined(separator: ", ")) is not in the source" }
        return nil
    }

    func commit() {
        let value = text
        guard value != stored else { return }
        store.perform([.setValue(id: key.id, locale: locale, category: category, value: value.isEmpty ? nil : value, status: .approved)])
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let showKey: Bool

    var body: some View {
        HStack(alignment: .top, spacing: RunaSpacing.s) {
            Avatar(entry.actor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.actor).font(RunaFont.smallMedium).foregroundStyle(RunaColor.textSecondary)
                    Text(summary).font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                    if showKey, let key = entry.key { Text(key).font(RunaFont.mono(size: 11.5)).foregroundStyle(RunaColor.textSecondary) }
                    Spacer(minLength: 4)
                    Text(entry.date.formatted(.relative(presentation: .named))).font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
                }
                if let before = entry.before, entry.action == .setValue || entry.action == .updateKey {
                    Text(before).font(RunaFont.small).strikethrough().foregroundStyle(RunaColor.textQuaternary).lineLimit(2)
                }
                if let after = entry.after, entry.action != .setStatus {
                    Text(after).font(RunaFont.small).foregroundStyle(RunaColor.textSecondary).lineLimit(3)
                }
                if let note = entry.note { Text(note).font(RunaFont.font(size: 11)).foregroundStyle(RunaColor.textQuaternary) }
            }
        }
    }

    var summary: String {
        let locale = entry.locale.map { " \($0.displayName())" } ?? ""
        switch entry.action {
        case .addKey: return "added"
        case .updateKey: return "edited details of"
        case .deleteKey: return "deleted"
        case .setValue: return entry.after == nil ? "cleared\(locale) in" : "changed\(locale) in"
        case .setStatus: return "marked\(locale) \(TranslationStatus(rawValue: entry.after ?? "")?.displayName.lowercased() ?? "") in"
        case .linkFigma: return "linked Figma to"
        case .addLocale: return "added\(locale)"
        case .removeLocale: return "removed\(locale)"
        }
    }
}
