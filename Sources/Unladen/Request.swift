@_spi(Wire) import UnladenCore

/// Everything one model call sends: the conversation, the tools on offer,
/// and generation settings.
public struct ModelRequest: Hashable, Sendable {
    public var messages: [Message]
    public var tools: [Tool]
    public var toolChoice: ToolChoice?
    public var settings: GenerationSettings

    public init(
        messages: [Message],
        tools: [Tool] = [],
        toolChoice: ToolChoice? = nil,
        settings: GenerationSettings = GenerationSettings(),
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.settings = settings
    }
}

/// A function the model may call.
///
/// ```swift
/// let weather = Tool(
///     name: "get_weather",
///     description: "Current weather for a city",
///     inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
/// )
/// ```
public struct Tool: Hashable, Sendable {
    public var name: String
    public var description: String?
    /// JSON Schema of the arguments object.
    public var inputSchema: JSONValue
    /// Ask for strict schema adherence (OpenAI `strict`), where supported.
    public var strict: Bool?
    /// A prompt-cache breakpoint after this tool's definition (see
    /// ``CacheBreakpoint``): mark the last tool to cache them all.
    public var cache: CacheBreakpoint?
    /// Raw JSON merged into the tool's object in the request (Chat: the
    /// `{"type": "function", …}` envelope); see ``ProviderOptions``.
    public var providerOptions: ProviderOptions

    public init(
        name: String,
        description: String? = nil,
        inputSchema: JSONValue = ["type": "object"],
        strict: Bool? = nil,
        cache: CacheBreakpoint? = nil,
        providerOptions: ProviderOptions = [:],
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
        self.cache = cache
        self.providerOptions = providerOptions
    }
}

/// Whether and which tool the model must call.
public enum ToolChoice: Hashable, Sendable {
    /// The model decides (the providers' default).
    case auto
    /// No tool calls.
    case none
    /// At least one tool call, of the model's choosing.
    case required
    /// A call to this tool.
    case tool(String)
}

/// Generation parameters. Every field is optional: `nil` sends nothing and
/// leaves the provider's default.
///
/// A parameter the chosen model or protocol cannot take is a
/// ``CallWarning``, which is an error under the default
/// ``WarningPolicy/strict`` policy.
public struct GenerationSettings: Hashable, Sendable {
    /// Output-token limit. Anthropic requires one; the model's Profile
    /// supplies a default there.
    public var maxOutputTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var stopSequences: [String]?
    public var seed: Int?
    public var reasoning: ReasoningSettings?
    public var responseFormat: ResponseFormat?
    /// Allow several tool calls in one turn.
    public var parallelToolCalls: Bool?
    /// An end-user id for abuse monitoring (OpenAI `user`, Anthropic
    /// `metadata.user_id`).
    public var user: String?
    /// OpenAI `prompt_cache_key`. A cache hint: dropping it for other
    /// providers is never an error.
    public var promptCacheKey: String?
    /// Raw JSON merged into the request body; see ``ProviderOptions``.
    public var providerOptions: ProviderOptions

    public init(
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        stopSequences: [String]? = nil,
        seed: Int? = nil,
        reasoning: ReasoningSettings? = nil,
        responseFormat: ResponseFormat? = nil,
        parallelToolCalls: Bool? = nil,
        user: String? = nil,
        promptCacheKey: String? = nil,
        providerOptions: ProviderOptions = [:],
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.stopSequences = stopSequences
        self.seed = seed
        self.reasoning = reasoning
        self.responseFormat = responseFormat
        self.parallelToolCalls = parallelToolCalls
        self.user = user
        self.promptCacheKey = promptCacheKey
        self.providerOptions = providerOptions
    }
}

/// Reasoning ("thinking") settings. Set an ``effort`` or a
/// ``budgetTokens``; the model's Profile converts one into the other when
/// the model only understands the other.
public struct ReasoningSettings: Hashable, Sendable {
    /// Effort level. Clamped to the nearest level the model supports.
    public struct Effort: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        /// No reasoning, where the model allows switching it off.
        public static let none: Effort = "none"
        public static let minimal: Effort = "minimal"
        public static let low: Effort = "low"
        public static let medium: Effort = "medium"
        public static let high: Effort = "high"
        public static let xhigh: Effort = "xhigh"
        public static let max: Effort = "max"
    }

    /// Whether reasoning text comes back.
    public enum Visibility: Hashable, Sendable {
        /// No reasoning text (Gemini `includeThoughts: false`).
        case hidden
        /// A summary, at a provider-specific detail level (OpenAI
        /// Responses `auto`, `concise`, `detailed`; `nil` means `auto`).
        case summary(String? = nil)
        /// The full reasoning text, where the provider returns it.
        case full
    }

    /// Switch reasoning on or off explicitly (Anthropic `thinking`).
    public var enabled: Bool?
    public var effort: Effort?
    /// Thinking-token budget (Anthropic `budget_tokens`, Gemini `thinkingBudget`).
    public var budgetTokens: Int?
    public var visibility: Visibility?

    public init(enabled: Bool? = nil, effort: Effort? = nil, budgetTokens: Int? = nil, visibility: Visibility? = nil) {
        self.enabled = enabled
        self.effort = effort
        self.budgetTokens = budgetTokens
        self.visibility = visibility
    }

    public static func effort(_ effort: Effort) -> ReasoningSettings {
        ReasoningSettings(effort: effort)
    }

    public static func budget(_ tokens: Int) -> ReasoningSettings {
        ReasoningSettings(enabled: true, budgetTokens: tokens)
    }
}

/// The shape of the model's text output.
public enum ResponseFormat: Hashable, Sendable {
    case text
    /// Any JSON object (OpenAI `json_object`).
    case json
    /// JSON matching `schema`.
    case jsonSchema(JSONValue, name: String? = nil, description: String? = nil, strict: Bool? = nil)
}

/// Raw JSON for one provider or protocol, merged into the request body,
/// or into one message, part or tool of it: the escape hatch for
/// parameters Unladen does not model.
///
/// Keys are an endpoint system id (``Endpoint/system``: `"openai"`,
/// `"anthropic"`, `"gemini"`, `"deepseek"`, `"openrouter"`…) or a protocol
/// (``APIProtocol`` raw value: `"chat"`, `"responses"`, `"anthropic"`,
/// `"gemini"`). Entries for other systems and protocols are ignored, so
/// one request can carry options for every provider it might go to.
///
/// **Precedence.** After Unladen encoded the request for the chosen
/// endpoint, the protocol's entry and then the system's entry are deep-merged
/// into the top-level body, so the system entry wins over the protocol
/// entry and both win over what Unladen wrote: objects merge key by key,
/// anything else replaces, and `null` removes the key. Options bypass the
/// warning policy and the model's Profile; they are sent as given.
///
/// ```swift
/// settings.providerOptions = [
///     "responses": ["include": ["reasoning.encrypted_content"], "store": false],
///     "anthropic": ["metadata": ["user_id": "u-42"]],
/// ]
/// ```
///
/// **Messages, parts and tools.** ``Message/providerOptions``,
/// ``ContentPart/withProviderOptions(_:)`` and ``Tool/providerOptions``
/// take the same keys and precedence, and are merged the same way into the
/// object the target protocol writes for the message, part or tool, last
/// (after any ``CacheBreakpoint``). Where the target writes no object for it
/// (Chat reasoning and refusals are message fields; Anthropic's `system`
/// has no message), the options are dropped with a
/// ``CallWarning/Code/droppedField`` warning.
///
/// ```swift
/// let doc = ContentPart.file(.url("https://example.com/a.pdf", mediaType: "application/pdf"))
///     .withProviderOptions(["anthropic": ["citations": ["enabled": true]]])
/// ```
public struct ProviderOptions: Hashable, Sendable, ExpressibleByDictionaryLiteral {
    public var entries: [String: JSONObject]

    public init(_ entries: [String: JSONObject] = [:]) {
        self.entries = entries
    }

    public init(dictionaryLiteral elements: (String, JSONObject)...) {
        self.entries = Dictionary(elements, uniquingKeysWith: { _, last in last })
    }

    public subscript(key: String) -> JSONObject? {
        get { entries[key] }
        set { entries[key] = newValue }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The options for `protocol` with those for `system` merged over them,
    /// or `nil` if there are none.
    func resolved(protocol apiProtocol: APIProtocol, system: String) -> JSONObject? {
        var result: JSONObject?
        var keys = [apiProtocol.rawValue]
        if system != apiProtocol.rawValue { keys.append(system) }
        for key in keys {
            guard let entry = entries[key] else { continue }
            result = WirePatch.overlay(entry, on: result ?? [:])
        }
        return result
    }
}

/// Stored as one compact JSON text per key, so any `Encoder` keeps every
/// value (`null` included) and number literal exactly.
extension ProviderOptions: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let texts = try container.decode([String: String].self)
        var entries: [String: JSONObject] = [:]
        for (key, text) in texts {
            guard let object = (try? JSONValue(parsing: Array(text.utf8)))?.objectValue else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "provider options for `\(key)` are not a JSON object")
            }
            entries[key] = object
        }
        self.init(entries)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries.mapValues { String(decoding: JSONValue.object($0).encoded(), as: UTF8.self) })
    }
}
