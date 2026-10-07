import Foundation

/// Translates many keys into many locales: builds context-rich batches, calls the provider with
/// limited concurrency, validates every draft, retries failures once with the problems attached,
/// and returns changes that save the drafts as machine translations.
public struct TranslationRunner: Sendable {
    public struct Job: Sendable {
        public var snapshot: Snapshot
        public var keyIDs: [UUID]
        public var locales: [LocaleCode]
        public var glossary: [GlossaryTerm]
        public var styleGuides: [LocaleCode: String]
        /// Screenshots of Figma frames by key, from the Figma REST API.
        public var images: [UUID: TranslationImage]
        /// Retranslate keys that already have a value (otherwise only missing values are filled).
        public var overwrite: Bool
        public var batchSize: Int
        public var concurrency: Int

        public init(snapshot: Snapshot, keyIDs: [UUID], locales: [LocaleCode], glossary: [GlossaryTerm] = [],
                    styleGuides: [LocaleCode: String] = [:], images: [UUID: TranslationImage] = [:], overwrite: Bool = false,
                    batchSize: Int = 25, concurrency: Int = 3)
        {
            self.snapshot = snapshot
            self.keyIDs = keyIDs
            self.locales = locales
            self.glossary = glossary
            self.styleGuides = styleGuides
            self.images = images
            self.overwrite = overwrite
            self.batchSize = batchSize
            self.concurrency = concurrency
        }
    }

    public struct Failure: Sendable, Hashable {
        public var keyID: UUID
        public var key: String
        public var locale: LocaleCode
        public var reason: String
    }

    public struct Outcome: Sendable {
        public var drafts: [UUID: [LocaleCode: [PluralCategory: String]]] = [:]
        public var notes: [UUID: [LocaleCode: String]] = [:]
        public var warnings: [UUID: [LocaleCode: [String]]] = [:]
        public var failures: [Failure] = []
        public var usage = TranslationUsage()

        public var draftCount: Int { drafts.values.reduce(0) { $0 + $1.count } }

        /// Changes that store every draft as a machine translation awaiting review.
        public func changes() -> [Change] {
            var changes: [Change] = []
            for (id, locales) in drafts.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                for (locale, forms) in locales.sorted(by: { $0.key < $1.key }) {
                    for (category, text) in forms.sorted(by: { $0.key < $1.key }) {
                        changes.append(.setValue(id: id, locale: locale, category: category, value: text, status: .machine))
                    }
                }
            }
            return changes
        }
    }

    public struct Progress: Sendable {
        public var completedBatches: Int
        public var totalBatches: Int
        public var translated: Int
        public var failed: Int
    }

    public let provider: any TranslationProvider

    public init(provider: any TranslationProvider) {
        self.provider = provider
    }

    /// Batches the job would send, for showing an estimate before running.
    public static func plan(_ job: Job) -> [TranslationRequest] {
        let snapshot = job.snapshot
        let source = snapshot.settings.sourceLocale
        var requests: [TranslationRequest] = []
        for locale in job.locales where locale != source {
            var items: [TranslationItem] = []
            var images: [TranslationImage] = []
            var imageIndexes: [UUID: Int] = [:]
            func flush() {
                guard !items.isEmpty else { return }
                requests.append(TranslationRequest(projectName: snapshot.settings.name, sourceLocale: source, targetLocale: locale, items: items,
                                                   glossary: job.glossary, styleGuide: job.styleGuides[locale] ?? "", images: images))
                items = []
                images = []
                imageIndexes = [:]
            }
            for id in job.keyIDs {
                guard let key = snapshot[id: id], !key.doNotTranslate, let sourceForms = key.translations[source]?.nonEmptyForms,
                      !sourceForms.isEmpty
                else { continue }
                let status = snapshot.status(of: key, locale: locale)
                if !job.overwrite && status != .missing { continue }
                let required = snapshot.requiredCategories(for: key, locale: locale)
                var others: [LocaleCode: String] = [:]
                for other in snapshot.settings.targetLocales where other != locale {
                    if let text = key.translations[other]?.forms[.other], snapshot.status(of: key, locale: other) == .approved { others[other] = text }
                }
                var imageIndex: Int?
                if let image = job.images[id] {
                    if let existing = imageIndexes[id] { imageIndex = existing } else if images.count < 4 {
                        images.append(image)
                        imageIndex = images.count - 1
                        imageIndexes[id] = imageIndex
                    }
                }
                items.append(TranslationItem(keyID: id, key: key.key, description: key.description, source: sourceForms, requiredForms: required,
                                             placeholders: key.placeholders(sourceLocale: source), otherLocales: others,
                                             current: job.overwrite ? key.translations[locale]?.nonEmptyForms : nil,
                                             figma: key.contexts.first, imageIndex: imageIndex))
                if items.count >= job.batchSize { flush() }
            }
            flush()
        }
        return requests
    }

    /// Rough token estimate: about four characters per token, plus overhead per request.
    public static func estimate(_ requests: [TranslationRequest]) -> TranslationUsage {
        var usage = TranslationUsage()
        for request in requests {
            let prompt = TranslationPrompt.system(for: request).count + TranslationPrompt.user(for: request).count
            usage.inputTokens += prompt / 4 + 400 + request.images.count * 1200
            usage.outputTokens += request.items.reduce(0) { $0 + $1.source.values.reduce(0) { $0 + $1.count } } / 3 + request.items.count * 25
        }
        return usage
    }

    public func run(_ job: Job, progress: @escaping @Sendable (Progress) -> Void = { _ in }) async -> Outcome {
        let requests = Self.plan(job)
        var outcome = Outcome()
        var completed = 0
        await withTaskGroup(of: (TranslationRequest, Result<[ValidatedDraft], Error>, TranslationUsage).self) { group in
            var iterator = requests.makeIterator()
            func next() -> Bool {
                guard let request = iterator.next() else { return false }
                group.addTask { await self.translateWithRetry(request) }
                return true
            }
            for _ in 0..<max(1, job.concurrency) where !next() { break }
            while let (request, result, usage) = await group.next() {
                completed += 1
                outcome.usage = outcome.usage + usage
                switch result {
                case .success(let drafts):
                    for draft in drafts {
                        let item = request.items.first { $0.keyID == draft.keyID }
                        if draft.errors.isEmpty {
                            outcome.drafts[draft.keyID, default: [:]][request.targetLocale] = draft.forms
                            if let note = draft.note { outcome.notes[draft.keyID, default: [:]][request.targetLocale] = note }
                            if !draft.warnings.isEmpty { outcome.warnings[draft.keyID, default: [:]][request.targetLocale] = draft.warnings }
                        } else {
                            outcome.failures.append(Failure(keyID: draft.keyID, key: item?.key ?? "", locale: request.targetLocale,
                                                            reason: draft.errors.joined(separator: "; ")))
                        }
                    }
                case .failure(let error):
                    let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    for item in request.items {
                        outcome.failures.append(Failure(keyID: item.keyID, key: item.key, locale: request.targetLocale, reason: reason))
                    }
                }
                progress(Progress(completedBatches: completed, totalBatches: requests.count, translated: outcome.draftCount,
                                  failed: outcome.failures.count))
                if Task.isCancelled { group.cancelAll() } else { _ = next() }
            }
        }
        return outcome
    }

    struct ValidatedDraft: Sendable {
        var keyID: UUID
        var forms: [PluralCategory: String]
        var note: String?
        var errors: [String]
        var warnings: [String]
    }

    func translateWithRetry(_ request: TranslationRequest) async -> (TranslationRequest, Result<[ValidatedDraft], Error>, TranslationUsage) {
        var usage = TranslationUsage()
        do {
            let first = try await provider.translate(request)
            usage = usage + first.usage
            var validated = validate(first.drafts, request: request)
            let failed = validated.filter { !$0.errors.isEmpty }
            if !failed.isEmpty, !Task.isCancelled {
                // One retry with only the failing strings and what was wrong.
                var retry = request
                retry.items = request.items.filter { item in failed.contains { $0.keyID == item.keyID } }
                retry.feedback = Dictionary(uniqueKeysWithValues: failed.map { ($0.keyID.lowercased, $0.errors) })
                if let second = try? await provider.translate(retry) {
                    usage = usage + second.usage
                    let fixed = validate(second.drafts, request: retry)
                    for draft in fixed where draft.errors.isEmpty {
                        if let index = validated.firstIndex(where: { $0.keyID == draft.keyID }) { validated[index] = draft }
                    }
                }
            }
            return (request, .success(validated), usage)
        } catch {
            return (request, .failure(error), usage)
        }
    }

    func validate(_ drafts: [TranslationDraft], request: TranslationRequest) -> [ValidatedDraft] {
        request.items.map { item in
            guard let draft = drafts.first(where: { $0.keyID == item.keyID }) else {
                return ValidatedDraft(keyID: item.keyID, forms: [:], note: nil, errors: ["the model skipped this string"], warnings: [])
            }
            let result = TranslationValidator.validate(draft, item: item, targetLocale: request.targetLocale)
            return ValidatedDraft(keyID: item.keyID, forms: result.forms, note: draft.note, errors: result.errors, warnings: result.warnings)
        }
    }
}
