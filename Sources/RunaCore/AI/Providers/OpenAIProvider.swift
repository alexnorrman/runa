import Foundation

/// OpenAI through the Responses API with strict JSON-schema output.
public struct OpenAIProvider: TranslationProvider {
    public let config: AIProviderConfig
    let apiKey: String
    let client: ProviderHTTP
    var baseURL = URL(string: "https://api.openai.com/v1/")!

    public init(config: AIProviderConfig, apiKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.apiKey = apiKey
        self.client = ProviderHTTP(http: http)
    }

    func body(for request: TranslationRequest) -> JSONValue {
        var content: [JSONValue] = [.object([("type", .string("input_text")), ("text", .string(TranslationPrompt.user(for: request)))])]
        if config.sendImages {
            for image in request.images {
                content.append(.object([("type", .string("input_image")),
                                        ("image_url", .string("data:\(image.mediaType);base64,\(image.data.base64EncodedString())"))]))
            }
        }
        return .object([
            ("model", .string(config.model)),
            ("instructions", .string(TranslationPrompt.system(for: request))),
            ("input", .array([.object([("role", .string("user")), ("content", .array(content))])])),
            ("text", .object([("format", .object([
                ("type", .string("json_schema")), ("name", .string("translations")), ("strict", .bool(true)),
                ("schema", TranslationPrompt.schema),
            ]))])),
        ])
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let json = try await client.post(baseURL.appendingPathComponent("responses"), headers: ["Authorization": "Bearer \(apiKey)"],
                                         body: body(for: request))
        if json["status"]?.stringValue == "incomplete" { throw TranslationError.truncated }
        var text = ""
        if case .array(let output)? = json["output"] {
            for item in output where item["type"]?.stringValue == "message" {
                if case .array(let parts)? = item["content"] {
                    for part in parts {
                        if part["type"]?.stringValue == "refusal" { throw TranslationError.refused(part["refusal"]?.stringValue) }
                        if part["type"]?.stringValue == "output_text", let chunk = part["text"]?.stringValue { text += chunk }
                    }
                }
            }
        }
        guard !text.isEmpty else { throw TranslationError.invalidResponse("no text in the reply") }
        let usage = TranslationUsage(inputTokens: ProviderHTTP.int(json["usage"]?["input_tokens"]),
                                     outputTokens: ProviderHTTP.int(json["usage"]?["output_tokens"]))
        return TranslationResponse(drafts: try TranslationPrompt.parse(text, request: request), usage: usage, model: json["model"]?.stringValue)
    }

    public func availableModels() async throws -> [String] {
        let json = try await client.get(baseURL.appendingPathComponent("models"), headers: ["Authorization": "Bearer \(apiKey)"])
        guard case .array(let models)? = json["data"] else { return [] }
        return models.compactMap { $0["id"]?.stringValue }.sorted()
    }
}
