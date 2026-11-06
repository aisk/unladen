/// A model call, as any of the four protocols can express it.
///
/// Presence is tracked: every generation parameter is optional and `nil`
/// means the client did not send it. Decoders never fill in defaults.
/// No gateway business (routing, sessions, keys) and no raw request bytes.
@_spi(Wire) public struct WireRequest: Hashable, Sendable {
    /// The protocol this was decoded from; `nil` if built in code.
    /// Unknown-field bags are written back only to the same protocol.
    public var source: WireProtocol?

    public var model: String
    /// Top-level system text: Anthropic `system`, Gemini
    /// `systemInstruction`, Responses `instructions`. Chat keeps its
    /// `system`/`developer` messages in ``messages`` instead.
    public var instructions: [WirePart]?
    /// How ``instructions`` was written (Anthropic `system` string vs blocks).
    public var instructionsForm: WireContentForm?
    /// Unknown keys of the instructions wrapper object (Gemini
    /// `systemInstruction` keys besides `parts`).
    public var instructionsExtra: JSONObject
    public var messages: [WireMessage]

    /// `nil`: absent; `[]`: sent as an empty array.
    public var tools: [WireTool]?
    public var toolChoice: WireToolChoice?
    public var parallelToolCalls: Bool?

    /// `max_tokens` / `max_completion_tokens` / `max_output_tokens` /
    /// `maxOutputTokens`; the spelling is in ``spellings``.
    public var maxOutputTokens: Int?
    /// Numbers keep their literal text (`0.70` stays `0.70`).
    public var temperature: JSONNumber?
    public var topP: JSONNumber?
    public var topK: JSONNumber?
    public var frequencyPenalty: JSONNumber?
    public var presencePenalty: JSONNumber?
    public var seed: Int?
    /// Chat `n`, Gemini `candidateCount`.
    public var candidateCount: Int?
    public var stop: WireStop?

    public var stream: Bool?
    public var streamOptions: WireStreamOptions?
    public var reasoning: WireReasoningConfig?
    public var responseFormat: WireResponseFormat?

    public var serviceTier: String?
    public var store: Bool?
    public var user: String?
    public var promptCacheKey: String?
    public var safetyIdentifier: String?
    /// Chat `verbosity`, Responses `text.verbosity`.
    public var verbosity: String?

    /// The client's spelling of fields with synonyms, so the same protocol
    /// writes them back as sent. Encoders honour it only when the target is
    /// ``source``; another protocol's spelling could be invalid for theirs.
    public var spellings: [WireSynonym: String]
    /// Unknown top-level keys, in decode order.
    public var extra: JSONObject

    public init(model: String, messages: [WireMessage], source: WireProtocol? = nil) {
        self.source = source
        self.model = model
        self.messages = messages
        self.instructionsExtra = [:]
        self.spellings = [:]
        self.extra = [:]
    }
}

/// Fields that one protocol spells in more than one way.
@_spi(Wire) public enum WireSynonym: String, Hashable, Sendable {
    /// Chat: `max_tokens` or `max_completion_tokens`.
    case maxOutputTokens
    /// Chat: `reasoning_effort` (OpenAI) or `reasoning` object (OpenRouter).
    case reasoning
}

/// A tool offered to the model.
@_spi(Wire) public enum WireTool: Hashable, Sendable {
    case function(WireFunctionTool)
    /// A provider tool or a type the model does not know (web search, custom).
    case opaque(WireOpaque)
}

@_spi(Wire) public struct WireFunctionTool: Hashable, Sendable {
    public var name: String
    public var description: String?
    /// JSON Schema of the arguments.
    public var parameters: JSONValue?
    public var strict: Bool?
    /// Unknown keys of the function definition (the object with `name`).
    public var extra: JSONObject
    /// Unknown keys of a protocol's wrapper object around it (Chat's
    /// `{"type":"function","function":{…}}`).
    public var envelopeExtra: JSONObject

    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue? = nil,
        strict: Bool? = nil,
        extra: JSONObject = [:],
        envelopeExtra: JSONObject = [:],
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
        self.extra = extra
        self.envelopeExtra = envelopeExtra
    }
}

@_spi(Wire) public enum WireToolChoice: Hashable, Sendable {
    case auto
    case none
    /// Must call some tool (Chat `required`, Anthropic `any`, Gemini `ANY`).
    case required
    /// Must call this function.
    case function(String)
    case opaque(WireOpaque)
}

@_spi(Wire) public enum WireStop: Hashable, Sendable {
    /// A bare string (Chat allows it).
    case single(String)
    case multiple([String])

    public var sequences: [String] {
        switch self {
        case .single(let value): [value]
        case .multiple(let values): values
        }
    }
}

@_spi(Wire) public struct WireStreamOptions: Hashable, Sendable {
    public var includeUsage: Bool?
    public var extra: JSONObject

    public init(includeUsage: Bool? = nil, extra: JSONObject = [:]) {
        self.includeUsage = includeUsage
        self.extra = extra
    }
}

/// Reasoning ("thinking") configuration, the union of the four protocols'.
@_spi(Wire) public struct WireReasoningConfig: Hashable, Sendable {
    /// `none`, `minimal`, `low`, `medium`, `high`, … as the client sent it.
    public var effort: String?
    /// Anthropic `budget_tokens`, Gemini `thinkingBudget`, OpenRouter `max_tokens`.
    public var budgetTokens: Int?
    /// Anthropic `thinking.type` enabled/disabled, OpenRouter `enabled`.
    public var enabled: Bool?
    /// Whether reasoning text should be returned: Gemini
    /// `thinkingConfig.includeThoughts`, OpenRouter `!exclude`.
    public var visible: Bool?
    /// Responses `reasoning.summary`.
    public var summary: String?
    /// Unknown keys of the reasoning object, when it was an object.
    public var extra: JSONObject

    public init(
        effort: String? = nil,
        budgetTokens: Int? = nil,
        enabled: Bool? = nil,
        visible: Bool? = nil,
        summary: String? = nil,
        extra: JSONObject = [:],
    ) {
        self.effort = effort
        self.budgetTokens = budgetTokens
        self.enabled = enabled
        self.visible = visible
        self.summary = summary
        self.extra = extra
    }
}

/// Structured-output request.
@_spi(Wire) public struct WireResponseFormat: Hashable, Sendable {
    public struct Kind: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public static let text: Kind = "text"
        public static let jsonObject: Kind = "json_object"
        public static let jsonSchema: Kind = "json_schema"
    }

    public var kind: Kind
    public var name: String?
    public var description: String?
    public var schema: JSONValue?
    public var strict: Bool?
    /// Unknown keys of the schema object (Chat `json_schema`).
    public var extra: JSONObject

    public init(
        kind: Kind,
        name: String? = nil,
        description: String? = nil,
        schema: JSONValue? = nil,
        strict: Bool? = nil,
        extra: JSONObject = [:],
    ) {
        self.kind = kind
        self.name = name
        self.description = description
        self.schema = schema
        self.strict = strict
        self.extra = extra
    }
}
