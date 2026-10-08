import RunaCore
import RunaDesign
import SwiftUI

extension ProjectStore {
    /// Drafts translations with the configured provider and stores them as machine drafts.
    @discardableResult
    func translate(keyIDs: [UUID], locales: [LocaleCode], overwrite: Bool, app: AppModel,
                   progress: @escaping @Sendable (TranslationRunner.Progress) -> Void = { _ in }) async -> TranslationRunner.Outcome?
    {
        guard let snapshot else { return nil }
        let provider: any TranslationProvider
        do {
            guard let configured = try app.translationProvider() else {
                lastError = "Set up an AI provider in Settings → AI first."
                return nil
            }
            provider = configured
        } catch {
            lastError = message(error)
            return nil
        }
        var images: [UUID: TranslationImage] = [:]
        if provider.config.sendImages, let token = app.figmaToken {
            for id in keyIDs.prefix(40) {
                if let context = snapshot[id: id]?.contexts.first, let image = await FigmaImages.shared.translationImage(for: context, token: token) {
                    images[id] = image
                }
            }
        }
        let shared = guidelines
        let job = TranslationRunner.Job(snapshot: snapshot, keyIDs: keyIDs, locales: locales, glossary: shared.glossary,
                                        styleGuides: shared.styleGuides, images: images, overwrite: overwrite)
        let outcome = await TranslationRunner(provider: provider).run(job, progress: progress)
        let changes = outcome.changes()
        if !changes.isEmpty {
            perform(changes)
            await push(note: "ai \(provider.config.model)")
        }
        if outcome.draftCount == 0, let failure = outcome.failures.first {
            lastError = failure.reason
        }
        return outcome
    }
}

struct TranslateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let store: ProjectStore
    let scope: ProjectStore.TranslateScope
    @State private var locales: Set<LocaleCode> = []
    @State private var overwrite = false
    @State private var running: Task<Void, Never>?
    @State private var progress: TranslationRunner.Progress?
    @State private var outcome: TranslationRunner.Outcome?

    var keyIDs: [UUID] { scope.keyIDs ?? store.snapshot?.keys.map(\.id) ?? [] }

    var job: TranslationRunner.Job? {
        guard let snapshot = store.snapshot else { return nil }
        return TranslationRunner.Job(snapshot: snapshot, keyIDs: keyIDs, locales: Array(locales).sorted(), overwrite: overwrite)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.l) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(RunaColor.accent)
                Text(scope.keyIDs == nil ? "Translate missing strings" : "Translate \(keyIDs.count) \(keyIDs.count == 1 ? "key" : "keys")")
                    .runaTitle(RunaFont.title3)
            }
            if app.aiProviderName == nil {
                Banner(.info, title: "No AI provider yet", message: "Connect Claude, OpenAI, Gemini or a local model in Settings.") {
                    SettingsLink { Text("Open Settings") }.buttonStyle(.runa(.primary, size: .small))
                }
            } else if let outcome {
                result(outcome)
            } else if let progress {
                VStack(alignment: .leading, spacing: RunaSpacing.s) {
                    ProgressView(value: Double(progress.completedBatches), total: Double(max(progress.totalBatches, 1)))
                    Text("\(progress.translated) drafted\(progress.failed > 0 ? ", \(progress.failed) failed" : "") · batch \(progress.completedBatches) of \(progress.totalBatches)")
                        .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                }
            } else {
                options
            }
            HStack {
                if let model = app.settings.ai?.model { Text("Model: \(model)").font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary) }
                Spacer()
                if outcome != nil {
                    Button("Done") { dismiss() }.buttonStyle(.runaSecondary)
                    Button("Review Drafts") {
                        store.sidebar = .review
                        dismiss()
                    }
                    .buttonStyle(.runaPrimary)
                } else if running != nil {
                    Button("Stop") { running?.cancel() }.buttonStyle(.runaSecondary)
                } else {
                    Button("Cancel") { dismiss() }.buttonStyle(.runaSecondary).keyboardShortcut(.cancelAction)
                    Button("Translate") { start() }
                        .buttonStyle(.runaPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(app.aiProviderName == nil || (job.map { TranslationRunner.plan($0).isEmpty } ?? true))
                }
            }
        }
        .padding(RunaSpacing.xl)
        .frame(width: 480)
        .background(RunaColor.elevated)
        .onAppear {
            locales = Set(scope.locales.isEmpty ? store.snapshot?.settings.targetLocales ?? [] : scope.locales)
            overwrite = scope.keyIDs != nil && store.snapshot.map { snapshot in
                keyIDs.compactMap { snapshot[id: $0] }.allSatisfy { key in
                    snapshot.settings.targetLocales.allSatisfy { snapshot.status(of: key, locale: $0) != .missing }
                }
            } ?? false
        }
    }

    var options: some View {
        VStack(alignment: .leading, spacing: RunaSpacing.m) {
            SectionLabel("Languages")
            if let snapshot = store.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.settings.targetLocales, id: \.self) { locale in
                        let missing = snapshot.coverage(for: locale).missing
                        Toggle(isOn: Binding(get: { locales.contains(locale) }, set: { if $0 { locales.insert(locale) } else { locales.remove(locale) } })) {
                            HStack {
                                Text(locale.displayName()).font(RunaFont.body)
                                Text(missing > 0 ? "\(missing) missing" : "complete").font(RunaFont.small)
                                    .foregroundStyle(missing > 0 ? RunaColor.missing : RunaColor.textQuaternary)
                            }
                        }
                        .toggleStyle(.runaCheckbox)
                    }
                }
            }
            Toggle("Also retranslate strings that already have a translation", isOn: $overwrite).toggleStyle(.runaCheckbox).font(RunaFont.body)
            if let job {
                let requests = TranslationRunner.plan(job)
                let strings = requests.reduce(0) { $0 + $1.items.count }
                let estimate = TranslationRunner.estimate(requests)
                let cost = app.settings.ai.flatMap { AnthropicProvider.price(for: $0.model) }.map {
                    (Double(estimate.inputTokens) * $0.input + Double(estimate.outputTokens) * $0.output) / 1_000_000
                }
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(strings) strings in \(requests.count) \(requests.count == 1 ? "request" : "requests")").font(RunaFont.bodyMedium)
                        Text("About \(((estimate.inputTokens + estimate.outputTokens) / 1000).formatted())k tokens" +
                             (cost.map { " · roughly \($0.formatted(.currency(code: "USD").precision(.fractionLength(2))))" } ?? ""))
                            .font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                        Text("Drafts are saved as machine translations for someone to review. Descriptions, Figma context and screenshots are sent with each string.")
                            .font(RunaFont.small).foregroundStyle(RunaColor.textQuaternary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func result(_ outcome: TranslationRunner.Outcome) -> some View {
        VStack(alignment: .leading, spacing: RunaSpacing.s) {
            Banner(outcome.failures.isEmpty ? .success : .warning,
                   title: "\(outcome.draftCount) drafts saved\(outcome.failures.isEmpty ? "" : ", \(outcome.failures.count) failed")",
                   message: "\(outcome.usage.inputTokens + outcome.usage.outputTokens) tokens used") { EmptyView() }
            if !outcome.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(outcome.failures, id: \.self) { failure in
                            Text("\(failure.key) [\(failure.locale.rawValue)]: \(failure.reason)").font(RunaFont.small).foregroundStyle(RunaColor.textTertiary)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    func start() {
        let ids = keyIDs
        let selected = Array(locales).sorted()
        let overwrite = overwrite
        running = Task {
            let result = await store.translate(keyIDs: ids, locales: selected, overwrite: overwrite, app: app) { update in
                Task { @MainActor in progress = update }
            }
            outcome = result ?? TranslationRunner.Outcome()
            running = nil
        }
    }
}
