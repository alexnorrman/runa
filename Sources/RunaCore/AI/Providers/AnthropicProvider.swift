import Foundation

/// Claude through the Messages API. There is no official Swift SDK, so this uses raw HTTP.
///
/// - Structured output (`output_config.format`) guarantees the reply parses.
/// - Effort defaults to `medium`: UI strings are short and context-rich, and higher effort costs
///   more without improving them much.
/// - Server-side fallbacks (`fallbacks: "default"`) re-run a request on a recommended model if a
///   safety classifier declines it, instead of failing the batch.
public struct AnthropicProvider: TranslationProvider {
    public let config: AIProviderConfig
    let apiKey: String
    let client: ProviderHTTP
    var baseURL = URL(string: "https://api.anthropic.com/v1/")!

    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public init(config: AIProviderConfig, apiKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.apiKey = apiKey
        self.client = ProviderHTTP(http: http)
    }

    var headers: [String: String] {
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        if Self.fallbackModels.contains(config.model) { headers["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        return headers
    }

    func body(for request: TranslationRequest) -> JSONValue {
        var content: [JSONValue] = []
        if config.sendImages {
            for image in request.images {
                content.append(.object([
                    ("type", .string("image")),
                    ("source", .object([("type", .string("base64")), ("media_type", .string(image.mediaType)),
                                        ("data", .string(image.data.base64EncodedString()))])),
                ]))
            }
        }
        content.append(.object([("type", .string("text")), ("text", .string(TranslationPrompt.user(for: request)))]))
        var members: [(String, JSONValue)] = [
            ("model", .string(config.model)),
            ("max_tokens", .number(16000)),
            ("system", .array([.object([
                ("type", .string("text")),
                ("text", .string(TranslationPrompt.system(for: request))),
                ("cache_control", .object([("type", .string("ephemeral"))])),
            ])])),
            ("messages", .array([.object([("role", .string("user")), ("content", .array(content))])])),
            ("output_config", .object([
                ("effort", .string(config.effort ?? "medium")),
                ("format", .object([("type", .string("json_schema")), ("schema", TranslationPrompt.schema)])),
            ])),
        ]
        if Self.fallbackModels.contains(config.model) { members.append(("fallbacks", .string("default"))) }
        return .object(members)
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let json = try await client.post(baseURL.appendingPathComponent("messages"), headers: headers, body: body(for: request))
        switch json["stop_reason"]?.stringValue {
        case "refusal": throw TranslationError.refused(json["stop_details"]?["category"]?.stringValue)
        case "max_tokens": throw TranslationError.truncated
        default: break
        }
        guard case .array(let blocks)? = json["content"],
              let text = blocks.first(where: { $0["type"]?.stringValue == "text" })?["text"]?.stringValue
        else { throw TranslationError.invalidResponse("no text in the reply") }
        let usage = TranslationUsage(inputTokens: ProviderHTTP.int(json["usage"]?["input_tokens"]) + ProviderHTTP.int(json["usage"]?["cache_read_input_tokens"]),
                                     outputTokens: ProviderHTTP.int(json["usage"]?["output_tokens"]))
        return TranslationResponse(drafts: try TranslationPrompt.parse(text, request: request), usage: usage, model: json["model"]?.stringValue)
    }

    public func availableModels() async throws -> [String] {
        let json = try await client.get(baseURL.appendingPathComponent("models").appending(queryItems: [URLQueryItem(name: "limit", value: "100")]),
                                        headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"])
        guard case .array(let models)? = json["data"] else { return [] }
        return models.compactMap { $0["id"]?.stringValue }
    }

    /// USD per million tokens (input, output), for the cost estimate shown before a run.
    public static func price(for model: String) -> (input: Double, output: Double)? {
        switch model {
        case "claude-fable-5-1", "claude-fable-5": (10, 50)
        case "claude-opus-5-5": (4, 20)
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6": (5, 25)
        case "claude-sonnet-5-5", "claude-sonnet-5": (2, 10)
        case "claude-sonnet-4-6": (3, 15)
        case "claude-haiku-4-5": (1, 5)
        default: nil
        }
    }
}
