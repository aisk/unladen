/// A complete (non-streaming) model reply.
///
/// Only one candidate is modelled; decoders warn about and drop others.
@_spi(Wire) public struct WireResponse: Hashable, Sendable {
    /// The protocol this was decoded from; bags go back only to it.
    public var source: WireProtocol?
    public var id: String?
    public var model: String?
    /// Unix seconds (Chat `created`, Responses `created_at`).
    public var created: Int?
    /// The assistant turn: reasoning, text, refusal and tool-call parts.
    public var message: WireMessage
    public var finishReason: WireFinishReason?
    public var usage: WireUsage?
    /// Unknown keys of the candidate wrapper (Chat `choices[0]`, e.g.
    /// `logprobs`), and other keys that describe how the candidate finished
    /// (Anthropic `stop_sequence`, `stop_details`). Streams deliver these in
    /// ``WireFinish/extra``, so an accumulated stream lands them here too.
    public var choiceExtra: JSONObject
    /// Unknown top-level keys (e.g. `system_fingerprint`, `service_tier`).
    public var extra: JSONObject

    public init(
        message: WireMessage,
        id: String? = nil,
        model: String? = nil,
        created: Int? = nil,
        finishReason: WireFinishReason? = nil,
        usage: WireUsage? = nil,
        source: WireProtocol? = nil,
    ) {
        self.source = source
        self.id = id
        self.model = model
        self.created = created
        self.message = message
        self.finishReason = finishReason
        self.usage = usage
        self.choiceExtra = [:]
        self.extra = [:]
    }
}

/// Why the model stopped.
@_spi(Wire) public struct WireFinishReason: Hashable, Sendable {
    public enum Unified: String, Hashable, Sendable {
        case stop
        case length
        case toolCalls = "tool-calls"
        case contentFilter = "content-filter"
        case error
        case other
    }

    public var unified: Unified
    /// The provider's own value (`end_turn`, `tool_calls`, `MAX_TOKENS`…),
    /// written back verbatim when encoding to the source protocol.
    public var raw: String?

    public init(_ unified: Unified, raw: String? = nil) {
        self.unified = unified
        self.raw = raw
    }
}

/// Token counts. Every field is optional: `nil` means "not reported".
///
/// ``inputTokens`` counts the whole prompt *including* cached tokens
/// (OpenAI/Gemini convention); an Anthropic decoder must add
/// `cache_read_input_tokens` and `cache_creation_input_tokens` to it.
@_spi(Wire) public struct WireUsage: Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    /// Prompt tokens read from cache (subset of ``inputTokens``).
    public var cachedInputTokens: Int?
    /// Prompt tokens written to cache (subset of ``inputTokens``).
    public var cacheWriteTokens: Int?
    /// Reasoning tokens (subset of ``outputTokens``).
    public var reasoningTokens: Int?
    /// Unknown keys of the usage object.
    public var extra: JSONObject
    /// Unknown keys of the input-details object (Chat `prompt_tokens_details`).
    public var inputDetailsExtra: JSONObject?
    /// Unknown keys of the output-details object (Chat `completion_tokens_details`).
    public var outputDetailsExtra: JSONObject?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        extra: JSONObject = [:],
        inputDetailsExtra: JSONObject? = nil,
        outputDetailsExtra: JSONObject? = nil,
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.extra = extra
        self.inputDetailsExtra = inputDetailsExtra
        self.outputDetailsExtra = outputDetailsExtra
    }
}
