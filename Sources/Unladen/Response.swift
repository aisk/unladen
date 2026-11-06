/// The result of ``LanguageModel/generate(_:)``, or of a collected stream.
public struct ModelResponse: Hashable, Sendable {
    /// The assistant turn, replay tokens included: append it to the history
    /// as is.
    public var message: Message
    public var finishReason: FinishReason
    public var usage: Usage
    /// Request-side warnings (only under ``WarningPolicy/lenient``, or the
    /// kinds that are never errors) and response-side warnings (always
    /// reported, never thrown).
    public var warnings: [CallWarning]
    public var metadata: ResponseMetadata

    public init(
        message: Message,
        finishReason: FinishReason,
        usage: Usage = Usage(),
        warnings: [CallWarning] = [],
        metadata: ResponseMetadata = ResponseMetadata(),
    ) {
        self.message = message
        self.finishReason = finishReason
        self.usage = usage
        self.warnings = warnings
        self.metadata = metadata
    }

    /// The answer's text parts, joined.
    public var text: String { message.text }

    /// The reasoning text, joined; `nil` if there was none.
    public var reasoningText: String? {
        let parts = message.content.compactMap { if case .reasoning(let text, _) = $0 { text } else { nil } }
        return parts.isEmpty ? nil : parts.joined()
    }

    /// The model's tool calls, in order. Answer each with a ``ToolResult``.
    public var toolCalls: [ToolCall] { message.toolCalls }
}

/// Why the model stopped.
public struct FinishReason: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A natural end or a stop sequence.
        case stop
        /// The output-token limit.
        case length
        /// The model wants tool results.
        case toolCalls = "tool-calls"
        case contentFilter = "content-filter"
        case error
        case other
    }

    public var kind: Kind
    /// The provider's own value (`end_turn`, `tool_calls`, `MAX_TOKENS`…).
    public var raw: String?

    public init(_ kind: Kind, raw: String? = nil) {
        self.kind = kind
        self.raw = raw
    }
}

/// Token counts; `nil` means the provider did not report it.
public struct Usage: Hashable, Sendable {
    /// The whole prompt, cached tokens included.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    /// Prompt tokens read from the cache (part of ``inputTokens``).
    public var cachedInputTokens: Int?
    /// Prompt tokens written to the cache (part of ``inputTokens``).
    public var cacheWriteTokens: Int?
    /// Reasoning tokens (part of ``outputTokens``).
    public var reasoningTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// What the provider said about the response.
public struct ResponseMetadata: Hashable, Sendable {
    /// The provider's response id (`msg_…`, `resp_…`, `chatcmpl-…`).
    public var id: String?
    /// The model that answered, as the provider names it.
    public var model: String?
    /// Unix seconds, when the provider reports it.
    public var created: Int?

    public init(id: String? = nil, model: String? = nil, created: Int? = nil) {
        self.id = id
        self.model = model
        self.created = created
    }
}

/// A note that a request or response could not be carried exactly.
public struct CallWarning: Hashable, Sendable, CustomStringConvertible {
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public var description: String { rawValue }

        /// A response field Unladen does not model was ignored.
        public static let unknownField: Code = "unknown_field"
        /// Response content Unladen does not model (e.g. a provider's
        /// server-side tool blocks) was left out of the message.
        public static let opaqueContent: Code = "opaque_content"
        /// A request field the model or protocol cannot take was left out.
        public static let droppedField: Code = "dropped_field"
        /// Request content the model or protocol cannot take was left out.
        public static let droppedContent: Code = "dropped_content"
        /// Content was sent, but not exactly as given.
        public static let lossyConversion: Code = "lossy_conversion"
        /// A value the protocol does not know was ignored.
        public static let unsupportedValue: Code = "unsupported_value"
        /// The provider's stream did not follow its protocol.
        public static let malformedStream: Code = "malformed_stream"
        /// The request was rewritten to fit the model without losing its
        /// meaning (an effort sent as a thinking budget, a missing tool
        /// result filled in, a token limit lowered to the model's cap).
        /// Never an error.
        public static let adjusted: Code = "adjusted"
        /// Replay data from another system was left out of the history
        /// (see ``ReplayToken``). Never an error.
        public static let replayDataDropped: Code = "replay_data_dropped"
    }

    public var code: Code
    public var message: String
    /// Where in the provider's JSON, e.g. `messages[2].content[0]`; empty
    /// for the whole document.
    public var path: String

    public init(_ code: Code, _ message: String, path: String = "") {
        self.code = code
        self.message = message
        self.path = path
    }

    /// `true` for a dropped prompt-cache hint (`prompt_cache_key`,
    /// `cache_control`…), which only costs money, never correctness.
    public var isCacheHint: Bool {
        guard code == .droppedField || code == .droppedContent else { return false }
        let last = path.split(separator: ".").last.map(String.init) ?? path
        return CallWarning.cacheHintFields.contains(last)
    }

    static let cacheHintFields: Set<String> = ["prompt_cache_key", "prompt_cache_retention", "cache_control", "cachedContent"]

    /// Whether ``WarningPolicy/strict`` turns this request-side warning into
    /// an error: everything except cache hints, ``Code/adjusted`` and
    /// ``Code/replayDataDropped``.
    public var isEscalatedWhenStrict: Bool {
        !(isCacheHint || code == .adjusted || code == .replayDataDropped)
    }

    public var description: String {
        path.isEmpty ? "\(code): \(message)" : "\(code) at \(path): \(message)"
    }
}

/// What happens when a request cannot be sent exactly as asked.
public enum WarningPolicy: Hashable, Sendable {
    /// The default: a request-side warning that changes what the model
    /// sees (a dropped parameter or part, a lossy conversion) throws
    /// ``UnladenError/unsupported(_:)`` before anything is sent. Cache hints,
    /// ``CallWarning/Code/adjusted`` and ``CallWarning/Code/replayDataDropped``
    /// are only reported.
    case strict
    /// Send anyway; every warning is reported on ``ModelResponse/warnings``
    /// (and as ``StreamPart/warnings(_:)`` at the start of a stream).
    case lenient
}
