import Foundation

public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic
    case openAI = "openai"
    case gemini
    case openAICompatible = "openai-compatible"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Claude (Anthropic)"
        case .openAI: "OpenAI"
        case .gemini: "Gemini (Google)"
        case .openAICompatible: "OpenAI-compatible (Ollama, LM Studio, OpenRouter…)"
        }
    }

    /// A sensible model to start with. Users pick from the provider's live model list.
    public var defaultModel: String? {
        switch self {
        case .anthropic: "claude-opus-5-5"
        default: nil
        }
    }

    public var needsAPIKey: Bool { self != .openAICompatible }
    public var needsBaseURL: Bool { self == .openAICompatible }
}

public struct AIProviderConfig: Codable, Sendable, Hashable {
    public var kind: AIProviderKind
    public var model: String
    /// OpenAI-compatible servers: for example `http://localhost:11434/v1` for Ollama.
    public var baseURL: String?
    /// Claude: `low`, `medium` or `high`. Translation of UI strings rarely needs more than medium.
    public var effort: String?
    /// Send Figma screenshots to models that can see. OpenAI-compatible servers default to off.
    public var sendImages: Bool

    public init(kind: AIProviderKind, model: String, baseURL: String? = nil, effort: String? = nil, sendImages: Bool = true) {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
        self.effort = effort
        self.sendImages = sendImages
    }
}

/// One key to translate into one target locale.
public struct TranslationItem: Sendable, Hashable {
    public var keyID: UUID
    public var key: String
    public var description: String
    /// Source text per plural form (`.other` only for plain keys).
    public var source: [PluralCategory: String]
    /// Forms the target locale needs.
    public var requiredForms: [PluralCategory]
    public var placeholders: [Placeholder]
    /// Translations in other locales, for consistency.
    public var otherLocales: [LocaleCode: String]
    /// The current target text, if retranslating.
    public var current: [PluralCategory: String]?
    /// Where it appears in the design: "Checkout / Summary", the path and nearby texts.
    public var figma: FigmaContext?
    /// Index into the request's images, when a screenshot shows this key.
    public var imageIndex: Int?

    public init(keyID: UUID, key: String, description: String, source: [PluralCategory: String], requiredForms: [PluralCategory],
                placeholders: [Placeholder], otherLocales: [LocaleCode: String] = [:], current: [PluralCategory: String]? = nil,
                figma: FigmaContext? = nil, imageIndex: Int? = nil)
    {
        self.keyID = keyID
        self.key = key
        self.description = description
        self.source = source
        self.requiredForms = requiredForms
        self.placeholders = placeholders
        self.otherLocales = otherLocales
        self.current = current
        self.figma = figma
        self.imageIndex = imageIndex
    }
}

public struct GlossaryTerm: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var term: String
    /// Empty means "do not translate".
    public var translations: [LocaleCode: String]
    public var note: String

    public init(term: String, translations: [LocaleCode: String] = [:], note: String = "") {
        self.term = term
        self.translations = translations
        self.note = note
    }
}

public struct TranslationImage: Sendable, Hashable {
    public var data: Data
    public var mediaType: String
    public var caption: String

    public init(data: Data, mediaType: String = "image/png", caption: String) {
        self.data = data
        self.mediaType = mediaType
        self.caption = caption
    }
}

public struct TranslationRequest: Sendable {
    public var projectName: String
    public var sourceLocale: LocaleCode
    public var targetLocale: LocaleCode
    public var items: [TranslationItem]
    public var glossary: [GlossaryTerm]
    /// Tone and conventions for the target language, such as "Use informal du".
    public var styleGuide: String
    public var images: [TranslationImage]
    /// Errors from a previous attempt, so the model can fix them.
    public var feedback: [String: [String]]

    public init(projectName: String, sourceLocale: LocaleCode, targetLocale: LocaleCode, items: [TranslationItem], glossary: [GlossaryTerm] = [],
                styleGuide: String = "", images: [TranslationImage] = [], feedback: [String: [String]] = [:])
    {
        self.projectName = projectName
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.items = items
        self.glossary = glossary
        self.styleGuide = styleGuide
        self.images = images
        self.feedback = feedback
    }
}

public struct TranslationDraft: Sendable, Hashable {
    public var keyID: UUID
    public var forms: [PluralCategory: String]
    /// A short remark from the model about an ambiguity, shown to the reviewer.
    public var note: String?
}

public struct TranslationUsage: Sendable, Hashable {
    public var inputTokens = 0
    public var outputTokens = 0

    public static func + (lhs: TranslationUsage, rhs: TranslationUsage) -> TranslationUsage {
        TranslationUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

public struct TranslationResponse: Sendable {
    public var drafts: [TranslationDraft]
    public var usage: TranslationUsage
    /// The model that actually answered (it can differ after a server-side fallback).
    public var model: String?
}

public enum TranslationError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidConfiguration(String)
    case http(Int, String)
    case refused(String?)
    case truncated
    case invalidResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an API key in Settings → AI."
        case .invalidConfiguration(let message): message
        case .http(401, _), .http(403, _): "The provider rejected the API key."
        case .http(429, _): "The provider is rate limiting requests. Try again in a minute."
        case .http(let status, let message): "The provider returned \(status): \(message)"
        case .refused(let category): "The model declined to translate this batch\(category.map { " (\($0))" } ?? "")."
        case .truncated: "The response was cut off. Try fewer keys at a time."
        case .invalidResponse(let message): "The model's answer could not be read: \(message)"
        case .network(let message): "Network error: \(message)"
        }
    }
}

/// A model that drafts translations. Every provider shares the prompt and output schema in
/// `TranslationPrompt`; each adapter only maps them onto its API.
public protocol TranslationProvider: Sendable {
    var config: AIProviderConfig { get }
    func translate(_ request: TranslationRequest) async throws -> TranslationResponse
    /// Model ids the key can use, newest first where the API says so.
    func availableModels() async throws -> [String]
}

public enum TranslationProviders {
    public static func make(_ config: AIProviderConfig, apiKey: String?, http: HTTPClient = URLSessionHTTPClient()) throws -> any TranslationProvider {
        if config.kind.needsAPIKey, (apiKey ?? "").isEmpty { throw TranslationError.missingAPIKey }
        switch config.kind {
        case .anthropic: return AnthropicProvider(config: config, apiKey: apiKey ?? "", http: http)
        case .openAI: return OpenAIProvider(config: config, apiKey: apiKey ?? "", http: http)
        case .gemini: return GeminiProvider(config: config, apiKey: apiKey ?? "", http: http)
        case .openAICompatible:
            guard let base = config.baseURL, URL(string: base) != nil else {
                throw TranslationError.invalidConfiguration("Set the server address, for example http://localhost:11434/v1")
            }
            return OpenAICompatibleProvider(config: config, apiKey: apiKey, http: http)
        }
    }
}
