import RunaCore
import RunaDesign
import SwiftUI

/// Glossary and per-language style guides that steer AI translation for this project.
struct ProjectSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore
    @State private var glossary: [GlossaryTerm] = []
    @State private var styleGuides: [LocaleCode: String] = [:]
    @State private var cliConfigCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.l) {
            Text("\(store.record.name) settings").runaTitle(RunaFont.title3)
            VStack(alignment: .leading, spacing: RunaSpacing.s) {
                SectionLabel("Glossary") {
                    Button { glossary.append(GlossaryTerm(term: "")) } label: { Image(systemName: "plus") }.buttonStyle(.runa(.ghost, size: .small))
                }
                Text("Terms AI must translate a fixed way. Leave a language empty to keep the term as is.")
                    .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($glossary) { $term in
                            HStack {
                                TextField("Term", text: $term.term).textFieldStyle(.runa).frame(width: 140)
                                ForEach(store.settings?.targetLocales ?? [], id: \.self) { locale in
                                    TextField(locale.rawValue, text: Binding(get: { term.translations[locale] ?? "" },
                                                                            set: { term.translations[locale] = $0.isEmpty ? nil : $0 }))
                                        .textFieldStyle(.runa)
                                }
                                Button { glossary.removeAll { $0.id == term.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.runa(.ghost, size: .small))
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            VStack(alignment: .leading, spacing: RunaSpacing.s) {
                SectionLabel("Style guides")
                ForEach(store.settings?.targetLocales ?? [], id: \.self) { locale in
                    HStack(alignment: .top) {
                        Text(locale.displayName()).font(RunaFont.body).frame(width: 110, alignment: .leading).padding(.top, 7)
                        TextField("e.g. Informal \"du\", short sentences, no exclamation marks", text: Binding(
                            get: { styleGuides[locale] ?? "" }, set: { styleGuides[locale] = $0.isEmpty ? nil : $0 }), axis: .vertical)
                            .textFieldStyle(.runa).lineLimit(1...4)
                    }
                }
            }
            VStack(alignment: .leading, spacing: RunaSpacing.s) {
                SectionLabel("Command line")
                Text("Copy a runa.yml for a repository that uses this project, then uncomment its targets.")
                    .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                Button(cliConfigCopied ? "Copied" : "Copy runa.yml") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CLIInstaller.runaYAML(for: store.record, serviceAccount: nil), forType: .string)
                    cliConfigCopied = true
                }
                .buttonStyle(.runa(.secondary, size: .small))
            }
            HStack {
                Text("Glossary and style guides are stored on this Mac.").font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.runaSecondary).keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.updateRecord {
                        $0.glossary = glossary.filter { !$0.term.trimmingCharacters(in: .whitespaces).isEmpty }
                        $0.styleGuides = styleGuides
                    }
                    dismiss()
                }
                .buttonStyle(.runaPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 640)
        .background(RunaColor.elevated)
        .onAppear {
            glossary = store.record.glossary
            styleGuides = store.record.styleGuides
        }
    }
}
