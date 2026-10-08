import RunaCore
import RunaDesign
import SwiftUI

/// The project's guidelines: key format and naming guide, glossary and per-language style guides. They are saved
/// to the backend, so the Figma plugin, the command line and AI agents through `runa mcp` follow the same ones.
struct ProjectSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore
    /// What the backend had when the sheet opened; saving merges on top of it.
    @State private var original = ProjectGuidelines()
    @State private var edited = ProjectGuidelines()
    @State private var sampleName = ""
    @State private var saving = false
    @State private var saveError: String?
    @State private var cliConfigCopied = false
    @State private var movesLocalSettings = false

    var rules: KeyNamingRules { KeyNamingRules(edited) }
    var targetLocales: [LocaleCode] { store.settings?.targetLocales ?? [] }
    var storageName: String { store.record.location.kind == .googleSheets ? "the project's sheet" : "the project file" }

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.l) {
            Text("\(store.record.name) settings").runaTitle(RunaFont.title3)
            ScrollView {
                VStack(alignment: .leading, spacing: RunaSpacing.l) {
                    if movesLocalSettings {
                        Banner(.info, title: "Your glossary and style guides are only on this Mac",
                               message: "Saving moves them into \(storageName), so everyone and every agent uses the same ones.") { EmptyView() }
                    }
                    keyNamesSection
                    namingGuideSection
                    glossarySection
                    styleGuidesSection
                    commandLineSection
                }
                .padding(.trailing, RunaSpacing.s)
            }
            .frame(maxHeight: 600)
            if let saveError {
                Text(saveError).font(RunaFont.small).foregroundStyle(RunaColor.missing).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Saved to \(storageName) and shared with the Figma plugin and AI agents.")
                    .font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.runaSecondary).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.runaPrimary).keyboardShortcut(.defaultAction)
                    .disabled(saving || !rules.configurationProblems.isEmpty)
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 680)
        .background(RunaColor.elevated)
        .onAppear {
            original = store.snapshot?.guidelines ?? ProjectGuidelines()
            edited = store.guidelines
            movesLocalSettings = store.hasLocalOnlyGuidelines
        }
    }

    // MARK: Sections

    var keyNamesSection: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.s) {
            SectionLabel("Key names")
            labeled("Format") {
                TextField("", text: $edited.keyTemplate, prompt: Text(verbatim: "{platform?}_{feature}_{description}_{type:title|text|action}"))
                    .textFieldStyle(.runaMono)
            }
            labeled("") {
                Text(verbatim: "Parts in braces: {feature} is one camelCase word, {type:title|text} one of the listed values, and ? makes a part "
                     + "optional. {platform} is ios, android or web; a key that starts with one ships to that platform only. Leave empty for no rule.")
                    .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            labeled("Pattern") {
                TextField("", text: $edited.keyPattern, prompt: Text(verbatim: "Optional regular expression, checked instead of the format"))
                    .textFieldStyle(.runaMono)
            }
            ForEach(rules.configurationProblems, id: \.self) { problem in
                labeled("") { Text(problem).font(RunaFont.small).foregroundStyle(RunaColor.missing) }
            }
            if rules.isActive {
                labeled("Try") {
                    HStack(spacing: RunaSpacing.s) {
                        TextField("", text: $sampleName, prompt: Text(verbatim: "A key name")).textFieldStyle(.runaMono).frame(width: 240)
                        if !sampleName.isEmpty {
                            if let problem = rules.problem(with: sampleName) {
                                Text(problem).font(RunaFont.small).foregroundStyle(RunaColor.missing).lineLimit(2)
                            } else {
                                let platforms = rules.impliedPlatforms(for: sampleName)
                                Label(platforms.map { "Follows the format; \($0.map(\.displayName).joined()) only" } ?? "Follows the format",
                                      systemImage: "checkmark")
                                    .font(RunaFont.small).foregroundStyle(RunaColor.approved)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RunaSpacing.s) {
            Text(label).font(RunaFont.body).foregroundStyle(RunaColor.textSecondary).frame(width: 64, alignment: .leading)
            content()
        }
    }

    var namingGuideSection: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.s) {
            SectionLabel("Naming guide")
            Text("Markdown for people and AI agents: how to name keys and write strings. Agents read it when they connect to runa mcp.")
                .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
            TextEditor(text: $edited.naming)
                .font(RunaFont.mono(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: RunaRadius.control).fill(RunaColor.panel))
                .overlay(RoundedRectangle(cornerRadius: RunaRadius.control).strokeBorder(RunaColor.borderSubtle))
        }
    }

    var glossarySection: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.s) {
            SectionLabel("Glossary") {
                Button { edited.glossary.append(GlossaryTerm(term: "")) } label: { Image(systemName: "plus") }.buttonStyle(.runa(.ghost, size: .small))
            }
            Text("Terms AI must translate a fixed way. Leave a language empty to keep the term as is.")
                .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
            VStack(spacing: 6) {
                ForEach($edited.glossary) { $term in
                    HStack {
                        TextField("Term", text: $term.term).textFieldStyle(.runa).frame(width: 140)
                        ForEach(targetLocales, id: \.self) { locale in
                            TextField(locale.rawValue, text: Binding(get: { term.translations[locale] ?? "" },
                                                                    set: { term.translations[locale] = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.runa)
                        }
                        Button { edited.glossary.removeAll { $0.id == term.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.runa(.ghost, size: .small))
                    }
                }
            }
        }
    }

    var styleGuidesSection: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.s) {
            SectionLabel("Style guides")
            ForEach(targetLocales, id: \.self) { locale in
                HStack(alignment: .top) {
                    Text(locale.displayName()).font(RunaFont.body).frame(width: 110, alignment: .leading).padding(.top, 7)
                    TextField("e.g. Informal \"du\", short sentences, no exclamation marks", text: Binding(
                        get: { edited.styleGuides[locale] ?? "" }, set: { edited.styleGuides[locale] = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .textFieldStyle(.runa).lineLimit(1...4)
                }
            }
        }
    }

    var commandLineSection: some View {
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
    }

    // MARK: Saving

    func save() {
        saving = true
        saveError = nil
        Task {
            let error = await store.saveGuidelines(edited.normalized, basedOn: original)
            saving = false
            if let error {
                saveError = error
            } else {
                dismiss()
            }
        }
    }
}
