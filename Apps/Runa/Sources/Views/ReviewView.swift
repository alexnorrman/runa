import RunaCore
import RunaDesign
import SwiftUI

/// Machine drafts and stale translations, one at a time, keyboard first:
/// ⌘↩ approves, ⌘→ skips.
struct ReviewView: View {
    @Bindable var store: ProjectStore
    @State private var locale: LocaleCode?
    @State private var skipped: Set<String> = []
    @State private var edited = ""

    struct Item: Identifiable {
        var key: StringKey
        var locale: LocaleCode
        var status: TranslationStatus
        var id: String { "\(key.id)|\(locale)" }
    }

    var items: [Item] {
        guard let snapshot = store.snapshot else { return [] }
        return snapshot.keys.sorted { $0.key < $1.key }.flatMap { key in
            snapshot.settings.targetLocales.filter { locale == nil || $0 == locale }.compactMap { target -> Item? in
                let status = snapshot.status(of: key, locale: target)
                guard status == .machine || status == .needsReview else { return nil }
                return Item(key: key, locale: target, status: status)
            }
        }
    }

    var body: some View {
        let queue = items.filter { !skipped.contains($0.id) }
        VStack(spacing: 0) {
            HStack {
                Text("Review").runaTitle(RunaFont.title3)
                Text("\(queue.count) left").font(RunaFont.body).foregroundStyle(RunaColor.textTertiary)
                Spacer()
                Picker("Language", selection: $locale) {
                    Text("All languages").tag(LocaleCode?.none)
                    ForEach(store.snapshot?.settings.targetLocales ?? [], id: \.self) { locale in
                        Text(locale.displayName()).tag(LocaleCode?.some(locale))
                    }
                }
                .fixedSize()
                if !skipped.isEmpty { Button("Show skipped") { skipped = [] }.buttonStyle(.runa(.ghost, size: .small)) }
            }
            .padding(.horizontal, RunaSpacing.l)
            .padding(.vertical, RunaSpacing.m)
            HairlineDivider()
            if let item = queue.first, let snapshot = store.snapshot {
                ScrollView {
                    card(item, snapshot: snapshot, remaining: queue.count)
                        .padding(RunaSpacing.xl)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
                .id(item.id)
            } else {
                EmptyStateView(systemImage: "checkmark.seal", title: "Nothing to review",
                               message: "Machine drafts and translations whose source changed show up here.") {
                    Button("Back to Keys") { store.sidebar = .keys(.all) }.buttonStyle(.runaSecondary)
                }
            }
        }
    }

    func card(_ item: Item, snapshot: Snapshot, remaining: Int) -> some View {
        let source = snapshot.settings.sourceLocale
        let isPlural = item.key.isPlural
        return VStack(alignment: .leading, spacing: RunaSpacing.l) {
            HStack {
                Text(item.key.key).font(RunaFont.mono(size: 14, weight: .medium)).foregroundStyle(RunaColor.textPrimary)
                Spacer()
                StatusDot(item.status)
                Text(item.status == .machine ? "Machine draft" : "Source changed since approval")
                    .font(RunaFont.small).foregroundStyle(item.status.color)
            }
            if !item.key.description.isEmpty {
                Text(item.key.description).font(RunaFont.body).foregroundStyle(RunaColor.textSecondary)
            }
            if let context = item.key.contexts.first { FigmaContextCard(context: context) }
            HStack(alignment: .top, spacing: RunaSpacing.l) {
                VStack(alignment: .leading, spacing: RunaSpacing.s) {
                    SectionLabel(source.displayName())
                    ForEach(isPlural ? PluralRules.categories(for: source) : [.other], id: \.self) { category in
                        if let text = item.key.translations[source]?.forms[category] {
                            VStack(alignment: .leading, spacing: 2) {
                                if isPlural { Text(category.rawValue).font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary) }
                                PlaceholderText(text).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: RunaSpacing.s) {
                    SectionLabel(item.locale.displayName())
                    if isPlural {
                        ForEach(PluralRules.categories(for: item.locale), id: \.self) { category in
                            HStack(alignment: .top) {
                                Text(category.rawValue).font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary).frame(width: 36, alignment: .trailing)
                                FormEditor(store: store, key: item.key, locale: item.locale, category: category, isSource: false)
                            }
                        }
                    } else {
                        FormEditor(store: store, key: item.key, locale: item.locale, category: .other, isSource: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Edits save as approved. ").font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
                Spacer()
                Button {
                    skipped.insert(item.id)
                } label: { HStack(spacing: 6) { Text("Skip"); KeyCap("⌘→") } }
                    .buttonStyle(.runaSecondary)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button {
                    store.perform([.setStatus(id: item.key.id, locale: item.locale, status: .approved)])
                } label: { HStack(spacing: 6) { Text("Approve"); KeyCap("⌘↩").colorScheme(.dark) } }
                    .buttonStyle(.runaPrimary)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}
