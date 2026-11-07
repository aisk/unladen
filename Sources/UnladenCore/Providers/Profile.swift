/// What a model accepts and which named fixes its requests need: capability
/// data plus references to named transforms (``ProfileTransform``).
///
/// Every field is optional; `nil` means "no opinion", so Profiles merge
/// field by field (``merged(over:)``). A resolved Profile is the endpoint's
/// defaults with at most one model rule merged over it (see
/// ``Provider/profile(for:endpoint:)``). Data-only fields are applied by the
/// upstream call on every request; the procedural ones take effect through
/// the transforms named in ``transforms``.
public struct Profile: Hashable, Sendable {
    /// `max_tokens` sent to an Anthropic upstream when the request has none
    /// (Anthropic requires the field).
    public var defaultMaxOutputTokens: Int?
    /// The model's output cap; a larger request is lowered to it (warning).
    public var maxOutputTokens: Int?

    public var supportsReasoning: Bool?
    public var supportsTools: Bool?
    public var supportsImages: Bool?
    /// `false` is the same as listing `.temperature` in
    /// ``unsupportedParameters``.
    public var supportsTemperature: Bool?
    /// Request parameters the model rejects (OpenAI reasoning models:
    /// temperature, top_p…), or that its endpoint's protocol has no field
    /// for (Anthropic: seed, penalties, response_format). Removed by
    /// ``ProfileTransform/dropUnsupportedParams`` with a
    /// ``WireWarning/Code/unsupportedByModel`` warning, which a strict
    /// policy reports but does not escalate. Accumulates across merges
    /// (see ``merged(over:)``).
    public var unsupportedParameters: Set<SamplingParameter>?
    /// Parameters the model rejects while thinking is on (Anthropic:
    /// temperature, top_k). "On" means `enabled: true` or a positive budget;
    /// an effort alone does not switch Anthropic thinking on.
    public var unsupportedParametersWhileReasoning: Set<SamplingParameter>?

    /// How the model's reasoning depth is set, for
    /// ``ProfileTransform/mapReasoningEffort``.
    public var reasoningControl: ReasoningControl?
    /// Effort levels the model accepts, ascending. Others are clamped to the
    /// nearest (rounding up, e.g. `xhigh` → `max` on Claude 4.6).
    public var effortLevels: [String]?
    /// Effort level → thinking-token budget, both ways.
    public var effortBudgets: [String: Int]?

    /// The Chat spelling of the output-token limit.
    public var maxTokensField: MaxTokensField?
    /// The upstream rejects fields it does not know (Mistral, Gemini's
    /// OpenAI-compatible API): unknown-field bags are dropped with a warning
    /// instead of being written back, and so are fields only OpenAI's
    /// platform defines (`store`, `service_tier`, ...).
    public var strictUnknownFields: Bool?
    /// Whether the upstream honours prompt-cache breakpoints
    /// (`cache_control`) on Chat content parts and tools: OpenRouter and
    /// other relays serving Claude. `false` drops them with a cache-hint
    /// warning (never an error); `nil` writes them back only to a Chat
    /// client's own request, like an unknown field (dropped too when
    /// ``strictUnknownFields`` is set). Anthropic Messages always carries
    /// breakpoints; Responses and Gemini have none (caching there is
    /// automatic, or uses `cachedContent`).
    public var chatCacheControl: Bool?
    /// The most prompt-cache breakpoints one request may carry (Claude: 4).
    /// The excess is left out with a cache-hint warning, keeping the
    /// breakpoints on tools, instructions and leading system messages and
    /// then the newest ones (see `WireTransforms.limitCacheBreakpoints`).
    /// Set, it also marks a model that reads breakpoints in prompt order
    /// (tools, system, messages) and rejects a longer TTL after a shorter
    /// one: earlier TTLs are raised to match
    /// (`WireTransforms.raiseEarlierCacheTTLs`).
    public var maxCacheBreakpoints: Int?
    /// The model is always called through this protocol, whatever the
    /// caller prefers (e.g. Claude on OpenRouter through Messages, for cache
    /// breakpoints).
    public var forcedProtocol: APIProtocol?
    /// The model streams only, or never; the upstream call bridges with an
    /// accumulator or by replaying a reply as events.
    public var streaming: StreamingRequirement?

    /// Anthropic upstream takes unsigned thinking blocks (DeepSeek).
    /// Defaults to `true` when ``transforms`` contains
    /// ``ProfileTransform/ensureThinkingOnToolTurns``.
    public var acceptsUnsignedThinking: Bool?
    /// Gemini: the `thoughtSignature` to send on calls with none accepted
    /// (see `GeminiRequestOptions.missingSignatureFallback`).
    public var geminiMissingSignatureFallback: String?
    /// Gemini: `parameters` vs `parametersJsonSchema` for tool schemas.
    public var geminiSchemaKey: GeminiSchemaKey?

    /// Named transforms to apply. They always run in the registry's fixed
    /// order (``ProfileTransform`` declaration order), not list order.
    public var transforms: [ProfileTransform]?

    public init(
        defaultMaxOutputTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsReasoning: Bool? = nil,
        supportsTools: Bool? = nil,
        supportsImages: Bool? = nil,
        supportsTemperature: Bool? = nil,
        unsupportedParameters: Set<SamplingParameter>? = nil,
        unsupportedParametersWhileReasoning: Set<SamplingParameter>? = nil,
        reasoningControl: ReasoningControl? = nil,
        effortLevels: [String]? = nil,
        effortBudgets: [String: Int]? = nil,
        maxTokensField: MaxTokensField? = nil,
        strictUnknownFields: Bool? = nil,
        chatCacheControl: Bool? = nil,
        maxCacheBreakpoints: Int? = nil,
        forcedProtocol: APIProtocol? = nil,
        streaming: StreamingRequirement? = nil,
        acceptsUnsignedThinking: Bool? = nil,
        geminiMissingSignatureFallback: String? = nil,
        geminiSchemaKey: GeminiSchemaKey? = nil,
        transforms: [ProfileTransform]? = nil,
    ) {
        self.defaultMaxOutputTokens = defaultMaxOutputTokens
        self.maxOutputTokens = maxOutputTokens
        self.supportsReasoning = supportsReasoning
        self.supportsTools = supportsTools
        self.supportsImages = supportsImages
        self.supportsTemperature = supportsTemperature
        self.unsupportedParameters = unsupportedParameters
        self.unsupportedParametersWhileReasoning = unsupportedParametersWhileReasoning
        self.reasoningControl = reasoningControl
        self.effortLevels = effortLevels
        self.effortBudgets = effortBudgets
        self.maxTokensField = maxTokensField
        self.strictUnknownFields = strictUnknownFields
        self.chatCacheControl = chatCacheControl
        self.maxCacheBreakpoints = maxCacheBreakpoints
        self.forcedProtocol = forcedProtocol
        self.streaming = streaming
        self.acceptsUnsignedThinking = acceptsUnsignedThinking
        self.geminiMissingSignatureFallback = geminiMissingSignatureFallback
        self.geminiSchemaKey = geminiSchemaKey
        self.transforms = transforms
    }

    /// `self` over `base`: each non-nil field of `self` replaces `base`'s.
    /// Collections are replaced whole, not unioned (one level, simple),
    /// except ``unsupportedParameters``, which is the union of both: an
    /// endpoint declares its protocol's gaps and a model rule adds the
    /// model's own.
    public func merged(over base: Profile) -> Profile {
        Profile(
            defaultMaxOutputTokens: defaultMaxOutputTokens ?? base.defaultMaxOutputTokens,
            maxOutputTokens: maxOutputTokens ?? base.maxOutputTokens,
            supportsReasoning: supportsReasoning ?? base.supportsReasoning,
            supportsTools: supportsTools ?? base.supportsTools,
            supportsImages: supportsImages ?? base.supportsImages,
            supportsTemperature: supportsTemperature ?? base.supportsTemperature,
            unsupportedParameters: base.unsupportedParameters.map { $0.union(unsupportedParameters ?? []) } ?? unsupportedParameters,
            unsupportedParametersWhileReasoning: unsupportedParametersWhileReasoning ?? base.unsupportedParametersWhileReasoning,
            reasoningControl: reasoningControl ?? base.reasoningControl,
            effortLevels: effortLevels ?? base.effortLevels,
            effortBudgets: effortBudgets ?? base.effortBudgets,
            maxTokensField: maxTokensField ?? base.maxTokensField,
            strictUnknownFields: strictUnknownFields ?? base.strictUnknownFields,
            chatCacheControl: chatCacheControl ?? base.chatCacheControl,
            maxCacheBreakpoints: maxCacheBreakpoints ?? base.maxCacheBreakpoints,
            forcedProtocol: forcedProtocol ?? base.forcedProtocol,
            streaming: streaming ?? base.streaming,
            acceptsUnsignedThinking: acceptsUnsignedThinking ?? base.acceptsUnsignedThinking,
            geminiMissingSignatureFallback: geminiMissingSignatureFallback ?? base.geminiMissingSignatureFallback,
            geminiSchemaKey: geminiSchemaKey ?? base.geminiSchemaKey,
            transforms: transforms ?? base.transforms,
        )
    }

    /// The default effort ↔ budget table (Anthropic-sized budgets).
    public static let standardEffortBudgets: [String: Int] = [
        "minimal": 1024, "low": 4096, "medium": 10000, "high": 24000, "xhigh": 32000, "max": 32000,
    ]

    /// Effort names in ascending order, for clamping.
    public static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
}

extension Profile {
    /// ``ChatRequestOptions/cacheControl`` for this Profile: its
    /// ``chatCacheControl``, else `false` for an upstream that rejects
    /// unknown fields, else `nil` (same protocol only).
    var chatCacheControlOption: Bool? {
        chatCacheControl ?? (strictUnknownFields == true ? false : nil)
    }
}

/// A sampling or generation parameter a model may reject.
public enum SamplingParameter: String, Hashable, Sendable, CaseIterable {
    case temperature
    case topP = "top_p"
    case topK = "top_k"
    case frequencyPenalty = "frequency_penalty"
    case presencePenalty = "presence_penalty"
    case seed
    case stop
    /// Chat `n`, Gemini `candidateCount`.
    case candidateCount = "n"
    /// Structured output (`response_format`, Gemini `responseMimeType`…).
    case responseFormat = "response_format"
    /// The end-user id (OpenAI `user`).
    case user
    /// `parallel_tool_calls`. Only `false` is reported when dropped:
    /// parallel calls are what a model does without the setting.
    case parallelToolCalls = "parallel_tool_calls"
}

/// How a model's reasoning depth is controlled.
public enum ReasoningControl: String, Hashable, Sendable {
    /// An effort level (OpenAI `reasoning_effort`, Anthropic
    /// `output_config.effort` with adaptive thinking). Budgets become levels.
    case effort
    /// A thinking-token budget (Anthropic `budget_tokens` before Claude 4.6,
    /// Gemini 2.5 `thinkingBudget`). Levels become budgets.
    case budget
    /// Gemini 3 `thinkingLevel`: effort-style, with Gemini's level names.
    case thinkingLevel
    /// The model reasons but takes no control (or none at all): reasoning
    /// settings are dropped with a warning.
    case uncontrolled
}

/// The Chat Completions spelling of the output-token limit.
public enum MaxTokensField: String, Hashable, Sendable {
    case maxTokens = "max_tokens"
    case maxCompletionTokens = "max_completion_tokens"
}

/// The Gemini function-declaration schema key.
public enum GeminiSchemaKey: String, Hashable, Sendable {
    /// The OpenAPI-subset `parameters`.
    case parameters
    /// Full JSON Schema, `parametersJsonSchema`.
    case parametersJsonSchema
}

/// A model that can only be called one way.
public enum StreamingRequirement: String, Hashable, Sendable {
    case always
    case never
}

/// Which model ids a rule applies to. Matching ignores ASCII case.
public enum ModelMatch: Hashable, Sendable {
    case exact(String)
    case prefix(String)
    /// A glob: `*` matches any run of characters, `?` one character.
    case pattern(String)

    func matches(_ model: String) -> Bool {
        let model = model.lowercased()
        switch self {
        case .exact(let value): return model == value.lowercased()
        case .prefix(let value): return model.hasPrefix(value.lowercased())
        case .pattern(let value): return Glob.matches(Array(value.lowercased()), Array(model))
        }
    }
}

/// A model-specific Profile.
public struct ModelRule: Hashable, Sendable {
    public var match: ModelMatch
    public var profile: Profile

    public init(_ match: ModelMatch, _ profile: Profile) {
        self.match = match
        self.profile = profile
    }
}

enum Glob {
    static func matches(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0
        var star: Int?, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p
                mark = t
                p += 1
            } else if let s = star {
                p = s + 1
                mark += 1
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
