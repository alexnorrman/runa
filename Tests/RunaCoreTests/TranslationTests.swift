import Foundation
import Testing
@testable import RunaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records requests and replies with queued responses.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, String)]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? (500, "{}") : responses.removeFirst()
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func body(_ index: Int) throws -> JSONValue { try JSONValue.parse(requests[index].httpBody ?? Data()) }
}

func reply(_ translations: [(String, [(String, String)])]) -> String {
    let items = translations.map { id, forms in
        "{\"id\": \"\(id)\", \"forms\": [\(forms.map { "{\"category\": \"\($0.0)\", \"text\": \"\($0.1)\"}" }.joined(separator: ","))], \"note\": \"\"}"
    }
    return "{\"translations\": [\(items.joined(separator: ","))]}"
}

func jsonString(_ text: String) -> String {
    JSONValue.string(text).serialized(style: .xcode)
}

@Suite struct TranslationTests {
    var request: TranslationRequest {
        let snapshot = Sample.snapshot
        let greeting = snapshot[id: Sample.greetingID]!
        let cart = snapshot[id: Sample.cartID]!
        return TranslationRequest(projectName: "Demo", sourceLocale: "en", targetLocale: "pl", items: [
            TranslationItem(keyID: greeting.id, key: greeting.key, description: "Shown after sign in", source: greeting.translations["en"]!.forms,
                            requiredForms: [.other], placeholders: greeting.placeholders(sourceLocale: "en"),
                            figma: FigmaContext(url: "https://www.figma.com/design/X/App?node-id=1-2", fileKey: "X", nodeId: "1:2", pageName: "Home",
                                                frameName: "Welcome", width: 200, siblingTexts: ["Continue"])),
            TranslationItem(keyID: cart.id, key: cart.key, description: "", source: cart.translations["en"]!.forms,
                            requiredForms: PluralRules.requiredCategories(for: "pl"), placeholders: cart.placeholders(sourceLocale: "en")),
        ], glossary: [GlossaryTerm(term: "Runa")], styleGuide: "Informal tone.")
    }

    @Test func promptCarriesContext() {
        let user = TranslationPrompt.user(for: request)
        #expect(user.contains("[s1] key: greeting"))
        #expect(user.contains("description: Shown after sign in"))
        #expect(user.contains("design: Home / Welcome"))
        #expect(user.contains("design width: 200pt"))
        #expect(user.contains("nearby texts: \"Continue\""))
        #expect(user.contains("write forms: one, few, many, other"))
        #expect(user.contains("placeholders: {name} {place}"))
        let system = TranslationPrompt.system(for: request)
        #expect(system.contains("Polish (pl)"))
        #expect(system.contains("keep \"Runa\" untranslated"))
        #expect(system.contains("Informal tone."))
    }

    @Test func claudeRequestShape() async throws {
        let body = reply([("s1", [("other", "Cześć {name}, witaj w {place}!")])])
        let http = MockHTTP([(200, """
            {"model": "claude-opus-5-5", "stop_reason": "end_turn", "content": [{"type": "text", "text": \(jsonString(body))}],
             "usage": {"input_tokens": 900, "output_tokens": 120}}
            """)])
        let provider = AnthropicProvider(config: AIProviderConfig(kind: .anthropic, model: "claude-opus-5-5"), apiKey: "sk-test", http: http)
        let response = try await provider.translate(request)
        #expect(response.drafts.first?.forms[.other] == "Cześć {name}, witaj w {place}!")
        #expect(response.usage.inputTokens == 900)
        let sent = try http.body(0)
        #expect(sent["model"]?.stringValue == "claude-opus-5-5")
        #expect(sent["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(sent["output_config"]?["effort"]?.stringValue == "medium")
        #expect(sent["fallbacks"]?.stringValue == "default")
        #expect(sent["thinking"] == nil)
        #expect(http.requests[0].value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(http.requests[0].value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(http.requests[0].url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func claudeWithoutFallbackSupport() async throws {
        let http = MockHTTP([(200, #"{"stop_reason": "end_turn", "content": [{"type": "text", "text": "{\"translations\": []}"}]}"#)])
        let provider = AnthropicProvider(config: AIProviderConfig(kind: .anthropic, model: "claude-haiku-4-5"), apiKey: "k", http: http)
        _ = try await provider.translate(request)
        #expect(try http.body(0)["fallbacks"] == nil)
        #expect(http.requests[0].value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func claudeRefusalIsAnError() async throws {
        let http = MockHTTP([(200, #"{"stop_reason": "refusal", "stop_details": {"category": "cyber"}, "content": []}"#)])
        let provider = AnthropicProvider(config: AIProviderConfig(kind: .anthropic, model: "claude-opus-5-5"), apiKey: "k", http: http)
        await #expect(throws: TranslationError.refused("cyber")) { try await provider.translate(request) }
    }

    @Test func openAIRequestShape() async throws {
        let body = reply([("s1", [("other", "Hej {name}")])])
        let http = MockHTTP([(200, """
            {"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": \(jsonString(body))}]}],
             "usage": {"input_tokens": 10, "output_tokens": 5}}
            """)])
        let provider = OpenAIProvider(config: AIProviderConfig(kind: .openAI, model: "gpt-test"), apiKey: "sk", http: http)
        let response = try await provider.translate(request)
        #expect(response.drafts.count == 1)
        let sent = try http.body(0)
        #expect(sent["text"]?["format"]?["strict"]?.boolValue == true)
        #expect(sent["instructions"]?.stringValue?.contains("Polish") == true)
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk")
    }

    @Test func geminiSchemaDialect() async throws {
        let body = reply([("s1", [("other", "Hej {name}")])])
        let http = MockHTTP([(200, """
            {"candidates": [{"finishReason": "STOP", "content": {"parts": [{"text": \(jsonString(body))}]}}],
             "usageMetadata": {"promptTokenCount": 7, "candidatesTokenCount": 3}}
            """)])
        let provider = GeminiProvider(config: AIProviderConfig(kind: .gemini, model: "models/gemini-test"), apiKey: "g", http: http)
        let response = try await provider.translate(request)
        #expect(response.drafts.count == 1)
        #expect(http.requests[0].url?.path == "/v1beta/models/gemini-test:generateContent")
        let schema = try http.body(0)["generationConfig"]?["responseSchema"]
        #expect(schema?["type"]?.stringValue == "OBJECT")
        #expect(schema?["additionalProperties"] == nil)
    }

    @Test func compatibleFallsBackToJSONMode() async throws {
        let body = reply([("s1", [("other", "Hej {name}")])])
        let http = MockHTTP([
            (400, #"{"error": {"message": "response_format json_schema not supported"}}"#),
            (200, "{\"choices\": [{\"finish_reason\": \"stop\", \"message\": {\"content\": \(jsonString("```json\n" + body + "\n```"))}}]}"),
        ])
        let provider = OpenAICompatibleProvider(config: AIProviderConfig(kind: .openAICompatible, model: "llama", baseURL: "http://localhost:11434/v1",
                                                                         sendImages: false), apiKey: nil, http: http)
        let response = try await provider.translate(request)
        #expect(response.drafts.first?.forms[.other] == "Hej {name}")
        #expect(http.requests.count == 2)
        #expect(try http.body(1)["response_format"]?["type"]?.stringValue == "json_object")
        #expect(http.requests[0].url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test func validatorCatchesPlaceholderAndPluralProblems() {
        let item = request.items[1]
        let draft = TranslationDraft(keyID: item.keyID, forms: [.one: "\"{count:int} produkt\"", .few: "{n} produkty", .other: "{count:int} produktu"],
                                     note: nil)
        let result = TranslationValidator.validate(draft, item: item, targetLocale: "pl")
        #expect(result.forms[.one] == "{count:int} produkt", "wrapping quotes are removed")
        #expect(result.errors.contains("the many form is missing"))
        #expect(result.errors.contains { $0.contains("uses {n}") })

        let greeting = request.items[0]
        let missing = TranslationValidator.validate(TranslationDraft(keyID: greeting.keyID, forms: [.other: "Cześć {name}!"], note: nil),
                                                    item: greeting, targetLocale: "pl")
        #expect(missing.errors == ["the translation is missing {place}"])
    }

    @Test func runnerRetriesInvalidDraftsAndSavesMachineDrafts() async throws {
        let snapshot = Sample.snapshot
        // First reply drops a placeholder for "greeting"; the retry fixes it.
        let first = reply([
            ("s1", [("other", "Witaj!")]),
            ("s2", [("other", "Kasa")]),
        ])
        let second = reply([("s1", [("other", "Cześć {name}, witaj w {place}!")])])
        func wrap(_ body: String) -> String {
            "{\"stop_reason\": \"end_turn\", \"content\": [{\"type\": \"text\", \"text\": \(jsonString(body))}], \"usage\": {\"input_tokens\": 100, \"output_tokens\": 10}}"
        }
        let http = MockHTTP([(200, wrap(first)), (200, wrap(second))])
        let provider = AnthropicProvider(config: AIProviderConfig(kind: .anthropic, model: "claude-opus-5-5"), apiKey: "k", http: http)
        let job = TranslationRunner.Job(snapshot: snapshot, keyIDs: [Sample.greetingID, Sample.checkoutID, Sample.appNameID], locales: ["pl"],
                                        concurrency: 1)
        let plan = TranslationRunner.plan(job)
        #expect(plan.count == 1)
        #expect(plan[0].items.map(\.key) == ["greeting", "checkout.title"], "do-not-translate keys are skipped")

        let outcome = await TranslationRunner(provider: provider).run(job)
        #expect(outcome.failures.isEmpty)
        #expect(outcome.drafts[Sample.greetingID]?["pl"]?[.other] == "Cześć {name}, witaj w {place}!")
        #expect(outcome.drafts[Sample.checkoutID]?["pl"]?[.other] == "Kasa")
        #expect(outcome.usage.inputTokens == 200)
        let retryText = String(decoding: http.requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(retryText.contains("fix these problems"))
        #expect(outcome.changes().allSatisfy {
            if case .setValue(_, "pl", _, _, .machine) = $0 { return true }
            return false
        })
    }

    @Test func runnerReportsProviderErrorsPerKey() async {
        let http = MockHTTP([(401, #"{"error": {"message": "invalid x-api-key"}}"#)])
        let provider = AnthropicProvider(config: AIProviderConfig(kind: .anthropic, model: "claude-opus-5-5"), apiKey: "bad", http: http)
        let job = TranslationRunner.Job(snapshot: Sample.snapshot, keyIDs: [Sample.greetingID], locales: ["pl"])
        let outcome = await TranslationRunner(provider: provider).run(job)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures[0].reason == "The provider rejected the API key.")
    }

    @Test func estimateIsReasonable() {
        let job = TranslationRunner.Job(snapshot: Sample.snapshot, keyIDs: Sample.snapshot.keys.map(\.id), locales: ["sv", "pl"])
        let requests = TranslationRunner.plan(job)
        let estimate = TranslationRunner.estimate(requests)
        #expect(estimate.inputTokens > 500)
        #expect(estimate.outputTokens > 0)
    }
}
