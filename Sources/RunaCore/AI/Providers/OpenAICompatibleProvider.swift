import Foundation

/// Any server that speaks OpenAI's Chat Completions API: Ollama and LM Studio on your Mac,
/// OpenRouter, Mistral, Groq and others. JSON-schema output is requested; servers that do not
/// support it fall back to plain JSON mode.
public struct OpenAICompatibleProvider: TranslationProvider {
    public let config: AIProviderConfig
    let apiKey: String?
    let client: ProviderHTTP

    public init(config: AIProviderConfig, apiKey: String?, http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.apiKey = apiKey
        self.client = ProviderHTTP(http: http)
    }

    var baseURL: URL {
        var base = config.baseURL ?? "http://localhost:11434/v1"
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base)!
    }

    var headers: [String: String] {
        guard let apiKey, !apiKey.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(apiKey)"]
    }

    func body(for request: TranslationRequest, schemaMode: Bool) -> JSONValue {
        var content: [JSONValue] = [.object([("type", .string("text")), ("text", .string(TranslationPrompt.user(for: request)))])]
        if config.sendImages {
            for image in request.images {
                content.append(.object([("type", .string("image_url")), ("image_url", .object([
                    ("url", .string("data:\(image.mediaType);base64,\(image.data.base64EncodedString())")),
                ]))]))
            }
        }
        let format: JSONValue = schemaMode
            ? .object([("type", .string("json_schema")), ("json_schema", .object([
                ("name", .string("translations")), ("strict", .bool(true)), ("schema", TranslationPrompt.schema),
            ]))])
            : .object([("type", .string("json_object"))])
        return .object([
            ("model", .string(config.model)),
            ("messages", .array([
                .object([("role", .string("system")), ("content", .string(TranslationPrompt.system(for: request)))]),
                .object([("role", .string("user")), ("content", .array(content))]),
            ])),
            ("response_format", format),
        ])
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let url = baseURL.appendingPathComponent("chat/completions")
        let json: JSONValue
        do {
            json = try await client.post(url, headers: headers, body: body(for: request, schemaMode: true))
        } catch TranslationError.http(400, _) {
            json = try await client.post(url, headers: headers, body: body(for: request, schemaMode: false))
        }
        guard case .array(let choices)? = json["choices"], let first = choices.first else {
            throw TranslationError.invalidResponse("no choices")
        }
        if first["finish_reason"]?.stringValue == "length" { throw TranslationError.truncated }
        guard let text = first["message"]?["content"]?.stringValue else { throw TranslationError.invalidResponse("no content") }
        let usage = TranslationUsage(inputTokens: ProviderHTTP.int(json["usage"]?["prompt_tokens"]),
                                     outputTokens: ProviderHTTP.int(json["usage"]?["completion_tokens"]))
        return TranslationResponse(drafts: try TranslationPrompt.parse(text, request: request), usage: usage, model: json["model"]?.stringValue)
    }

    public func availableModels() async throws -> [String] {
        let json = try await client.get(baseURL.appendingPathComponent("models"), headers: headers)
        guard case .array(let models)? = json["data"] else { return [] }
        return models.compactMap { $0["id"]?.stringValue }.sorted()
    }
}
