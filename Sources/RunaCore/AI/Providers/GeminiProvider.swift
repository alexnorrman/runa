import Foundation

/// Google Gemini through `generateContent` with a response schema.
public struct GeminiProvider: TranslationProvider {
    public let config: AIProviderConfig
    let apiKey: String
    let client: ProviderHTTP
    var baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    public init(config: AIProviderConfig, apiKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.apiKey = apiKey
        self.client = ProviderHTTP(http: http)
    }

    /// Gemini's schema dialect: upper-case types, no `additionalProperties`.
    static func geminiSchema(_ value: JSONValue) -> JSONValue {
        guard case .object(let members) = value else { return value }
        return .object(members.compactMap { name, member in
            switch name {
            case "additionalProperties": return nil
            case "type": return (name, .string(member.stringValue?.uppercased() ?? "STRING"))
            case "properties":
                guard case .object(let properties) = member else { return (name, member) }
                return (name, .object(properties.map { ($0.0, geminiSchema($0.1)) }))
            case "items": return (name, geminiSchema(member))
            default: return (name, member)
            }
        })
    }

    func body(for request: TranslationRequest) -> JSONValue {
        var parts: [JSONValue] = [.object([("text", .string(TranslationPrompt.user(for: request)))])]
        if config.sendImages {
            for image in request.images {
                parts.append(.object([("inlineData", .object([("mimeType", .string(image.mediaType)), ("data", .string(image.data.base64EncodedString()))]))]))
            }
        }
        return .object([
            ("systemInstruction", .object([("parts", .array([.object([("text", .string(TranslationPrompt.system(for: request)))])]))])),
            ("contents", .array([.object([("role", .string("user")), ("parts", .array(parts))])])),
            ("generationConfig", .object([
                ("responseMimeType", .string("application/json")),
                ("responseSchema", Self.geminiSchema(TranslationPrompt.schema)),
            ])),
        ])
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        let model = config.model.hasPrefix("models/") ? String(config.model.dropFirst(7)) : config.model
        let url = baseURL.appendingPathComponent("models/\(model):generateContent")
        let json = try await client.post(url, headers: ["x-goog-api-key": apiKey], body: body(for: request))
        if let reason = json["promptFeedback"]?["blockReason"]?.stringValue { throw TranslationError.refused(reason) }
        guard case .array(let candidates)? = json["candidates"], let first = candidates.first else {
            throw TranslationError.invalidResponse("no candidates")
        }
        switch first["finishReason"]?.stringValue {
        case "MAX_TOKENS": throw TranslationError.truncated
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST": throw TranslationError.refused(first["finishReason"]?.stringValue)
        default: break
        }
        var text = ""
        if case .array(let parts)? = first["content"]?["parts"] {
            for part in parts { text += part["text"]?.stringValue ?? "" }
        }
        let usage = TranslationUsage(inputTokens: ProviderHTTP.int(json["usageMetadata"]?["promptTokenCount"]),
                                     outputTokens: ProviderHTTP.int(json["usageMetadata"]?["candidatesTokenCount"]))
        return TranslationResponse(drafts: try TranslationPrompt.parse(text, request: request), usage: usage, model: json["modelVersion"]?.stringValue)
    }

    public func availableModels() async throws -> [String] {
        let json = try await client.get(baseURL.appendingPathComponent("models").appending(queryItems: [URLQueryItem(name: "pageSize", value: "200")]),
                                        headers: ["x-goog-api-key": apiKey])
        guard case .array(let models)? = json["models"] else { return [] }
        return models.compactMap { model -> String? in
            guard case .array(let methods)? = model["supportedGenerationMethods"],
                  methods.contains(.string("generateContent")),
                  let name = model["name"]?.stringValue
            else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
    }
}
