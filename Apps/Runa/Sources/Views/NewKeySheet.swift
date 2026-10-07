import RunaCore
import RunaDesign
import SwiftUI

struct NewKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore
    @State private var name = ""
    @State private var text = ""
    @State private var one = ""
    @State private var description = ""
    @State private var plural = false
    @State private var addAnother = false
    @FocusState private var focusName: Bool

    var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let problem = KeyNaming.problem(with: trimmed) { return problem }
        if store.snapshot?.key(named: trimmed) != nil { return "\(trimmed) already exists." }
        return nil
    }

    var similar: [StringKey] {
        guard let snapshot = store.snapshot, text.count >= 3 else { return [] }
        return KeySearch.search(text, in: snapshot, limit: 3).filter { key in
            key.translations[snapshot.settings.sourceLocale]?.forms.values.contains { $0.localizedCaseInsensitiveContains(text) } == true
        }
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && problem == nil && !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            Text("New key").runaTitle(RunaFont.title3)
            VStack(alignment: .leading, spacing: 4) {
                TextField("screen.element.purpose", text: $name).textFieldStyle(.runaMono).focused($focusName)
                if let problem { Text(problem).font(RunaFont.small).foregroundStyle(RunaColor.missing) }
            }
            if plural {
                TextField("Singular, e.g. {count:int} item", text: $one).textFieldStyle(.runa)
                TextField("Plural, e.g. {count:int} items", text: $text).textFieldStyle(.runa)
            } else {
                TextField("\(store.settings?.sourceLocale.displayName() ?? "Source") text. Placeholders: {name}, {count:int}", text: $text, axis: .vertical)
                    .textFieldStyle(.runa).lineLimit(1...5)
            }
            TextField("Description for translators (optional)", text: $description, axis: .vertical).textFieldStyle(.runa).lineLimit(1...4)
            Toggle("Plural (different text for one and many)", isOn: $plural).toggleStyle(.runaCheckbox).font(RunaFont.body)
            if !similar.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Similar text already exists:").font(RunaFont.small).foregroundStyle(RunaColor.review)
                    ForEach(similar) { key in
                        Button {
                            store.selection = [key.id]
                            dismiss()
                        } label: {
                            Text("\(key.key) — \(key.value(for: store.settings!.sourceLocale) ?? "")").font(RunaFont.small).lineLimit(1)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            HStack {
                Toggle("Add another", isOn: $addAnother).toggleStyle(.runaCheckbox).font(RunaFont.small)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.runaSecondary).keyboardShortcut(.cancelAction)
                Button("Create Key") { save() }.buttonStyle(.runaPrimary).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 500)
        .background(RunaColor.elevated)
        .onAppear {
            focusName = true
            if !store.searchText.isEmpty, KeyNaming.problem(with: store.searchText) == nil { name = store.searchText }
        }
    }

    func save() {
        guard let source = store.settings?.sourceLocale else { return }
        var forms: [PluralCategory: String] = [.other: text]
        if plural, !one.isEmpty { forms[.one] = one }
        let key = StringKey(key: name.trimmingCharacters(in: .whitespaces), description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                            isPlural: plural, translations: [source: Translation(forms: forms)])
        store.perform([.addKey(key)])
        store.selection = [key.id]
        if addAnother {
            name = ""
            text = ""
            one = ""
            description = ""
            focusName = true
        } else {
            dismiss()
        }
    }
}
