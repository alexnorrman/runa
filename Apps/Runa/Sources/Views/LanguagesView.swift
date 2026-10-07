import RunaCore
import RunaDesign
import SwiftUI

struct LanguagesView: View {
    @Environment(AppModel.self) private var app
    @Bindable var store: ProjectStore
    @State private var adding = false
    @State private var removing: LocaleCode?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Languages").runaTitle(RunaFont.title3)
                Spacer()
                Button { adding = true } label: { Label("Add Language", systemImage: "plus") }.buttonStyle(.runaPrimary)
            }
            .padding(.horizontal, RunaSpacing.l)
            .padding(.vertical, RunaSpacing.m)
            HairlineDivider()
            if let snapshot = store.snapshot {
                ScrollView {
                    VStack(spacing: RunaSpacing.s) {
                        ForEach(snapshot.settings.locales, id: \.self) { locale in
                            row(locale, snapshot: snapshot)
                        }
                    }
                    .padding(RunaSpacing.l)
                }
            }
        }
        .sheet(isPresented: $adding) { AddLanguageSheet(store: store) }
        .sheet(item: Binding(get: { removing.map(RemovalTarget.init) }, set: { removing = $0?.locale })) { target in
            RemoveLanguageSheet(store: store, locale: target.locale)
        }
    }

    struct RemovalTarget: Identifiable {
        var locale: LocaleCode
        var id: String { locale.rawValue }
    }

    func row(_ locale: LocaleCode, snapshot: Snapshot) -> some View {
        let coverage = snapshot.coverage(for: locale)
        let isSource = locale == snapshot.settings.sourceLocale
        return Card {
            HStack(spacing: RunaSpacing.l) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: RunaSpacing.s) {
                        Text(locale.displayName()).font(RunaFont.bodyMedium).foregroundStyle(RunaColor.textPrimary)
                        Text(locale.rawValue).font(RunaFont.mono(size: 11.5)).foregroundStyle(RunaColor.textTertiary)
                        if isSource { Chip("source") }
                        if locale.isRightToLeft { Chip("right to left") }
                    }
                    Text("Plural forms: " + PluralRules.requiredCategories(for: locale).map(\.rawValue).joined(separator: ", "))
                        .font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
                }
                .frame(width: 240, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    CoverageBar(coverage).frame(maxWidth: 440)
                    HStack(spacing: RunaSpacing.m) {
                        stat(coverage.approved, "approved", RunaColor.approved)
                        stat(coverage.needsReview, "need review", RunaColor.review)
                        stat(coverage.machine, coverage.machine == 1 ? "draft" : "drafts", RunaColor.machine)
                        stat(coverage.missing, "missing", RunaColor.missing)
                    }
                }
                Spacer(minLength: RunaSpacing.l)
                if !isSource {
                    if coverage.missing > 0 {
                        Button("Show Missing") { store.sidebar = .keys(.missing(locale)) }.buttonStyle(.runa(.ghost, size: .small))
                        Button {
                            store.translateScope = .init(keyIDs: nil, locales: [locale])
                        } label: { Label("Translate", systemImage: "sparkles") }
                            .buttonStyle(.runa(.secondary, size: .small))
                            .disabled(app.aiProviderName == nil)
                    }
                    Menu {
                        Button("Remove \(locale.displayName())…", role: .destructive) { removing = locale }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(.runa(.ghost, size: .small)).menuIndicator(.hidden).fixedSize()
                }
            }
        }
    }

    func stat(_ value: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(value) \(label)").font(RunaFont.small).monospacedDigit().foregroundStyle(value == 0 ? RunaColor.textQuaternary : RunaColor.textSecondary)
        }
    }
}

struct AddLanguageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore
    @State private var query = ""
    @State private var selected: LocaleCode?
    @State private var working = false

    static let common: [LocaleCode] = ["sv", "da", "nb", "fi", "de", "fr", "es", "it", "nl", "pt", "pt-BR", "pl", "cs", "ru", "uk", "tr", "ar",
                                       "he", "hi", "ja", "ko", "zh-Hans", "zh-Hant", "th", "vi", "id", "en-GB", "es-419", "fr-CA"]

    var candidates: [LocaleCode] {
        let existing = Set(store.snapshot?.settings.locales ?? [])
        var all = Self.common
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            if let locale = LocaleCode(rawValue: code), !all.contains(locale) { all.append(locale) }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var results = all.filter { !existing.contains($0) }
        if !trimmed.isEmpty {
            results = results.filter { $0.displayName().localizedCaseInsensitiveContains(trimmed) || $0.rawValue.lowercased().hasPrefix(trimmed.lowercased()) }
            if let typed = LocaleCode(rawValue: trimmed), typed.isKnownLanguage, !existing.contains(typed), !results.contains(typed) {
                results.insert(typed, at: 0)
            }
        }
        return Array(results.prefix(60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            Text("Add a language").runaTitle(RunaFont.title3)
            TextField("Search by name or code, e.g. Swedish or pt-BR", text: $query).textFieldStyle(.runa)
            List(candidates, id: \.self, selection: $selected) { locale in
                HStack {
                    Text(locale.displayName()).font(RunaFont.body)
                    Text(locale.rawValue).font(RunaFont.mono(size: 11.5)).foregroundStyle(RunaColor.textTertiary)
                    Spacer()
                    Text(PluralRules.requiredCategories(for: locale).map(\.rawValue).joined(separator: " · "))
                        .font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
                }
            }
            .listStyle(.plain)
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(RunaColor.panel))
            if let selected {
                Text("\(selected.displayName()) adds a column to the backend. \(store.snapshot?.keys.count ?? 0) keys will need translating" +
                     (PluralRules.requiredCategories(for: selected).count > 2 ? ", and plural keys need the \(PluralRules.requiredCategories(for: selected).map(\.rawValue).joined(separator: ", ")) forms." : "."))
                    .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.runaSecondary).keyboardShortcut(.cancelAction)
                Button(working ? "Adding…" : "Add Language") { add() }
                    .buttonStyle(.runaPrimary).keyboardShortcut(.defaultAction).disabled(selected == nil || working)
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 520)
        .background(RunaColor.elevated)
    }

    func add() {
        guard let selected else { return }
        working = true
        Task {
            let ok = await store.run { backend, context in try await backend.addLocale(selected, context: context) }
            working = false
            if ok { dismiss() }
        }
    }
}

struct RemoveLanguageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore
    let locale: LocaleCode
    @State private var confirmation = ""
    @State private var working = false

    var body: some View {
        let count = store.snapshot.map { snapshot in snapshot.keys.filter { $0.translations[locale] != nil }.count } ?? 0
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            Text("Remove \(locale.displayName())?").runaTitle(RunaFont.title3)
            Text("This deletes \(count) \(locale.displayName()) translations from the backend for everyone. Runa saves a backup file first.")
                .font(RunaFont.body).foregroundStyle(RunaColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            Text("Type \(locale.rawValue) to confirm.").font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
            TextField(locale.rawValue, text: $confirmation).textFieldStyle(.runaMono)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.runaSecondary).keyboardShortcut(.cancelAction)
                Button(working ? "Removing…" : "Remove") { remove() }
                    .buttonStyle(.runa(.destructive))
                    .disabled(LocaleCode(rawValue: confirmation) != locale || working)
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 440)
        .background(RunaColor.elevated)
    }

    func remove() {
        working = true
        if let snapshot = store.snapshot {
            var backup: [String: [String: String]] = [:]
            for key in snapshot.keys {
                if let forms = key.translations[locale]?.nonEmptyForms, !forms.isEmpty {
                    backup[key.key] = Dictionary(uniqueKeysWithValues: forms.map { ($0.key.rawValue, $0.value) })
                }
            }
            let url = Storage.backups.appendingPathComponent("\(store.record.name)-\(locale.rawValue)-\(Int(Date().timeIntervalSince1970)).json")
            Storage.save(backup, to: url)
        }
        Task {
            let ok = await store.run { backend, context in try await backend.removeLocale(locale, context: context) }
            working = false
            if ok {
                if case .keys(.missing(let filtered)) = store.sidebar, filtered == locale { store.sidebar = .keys(.all) }
                dismiss()
            }
        }
    }
}
