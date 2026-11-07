/// The closed registry of named request fixes a Profile can reference.
///
/// Each is a `WireRequest → WireRequest` function (plus warnings), applied
/// after decoding and before encoding, on same-protocol and cross-protocol
/// requests alike. They run in declaration order whatever order a Profile
/// lists them in, and each is a no-op for target protocols it does not
/// concern (noted per case).
public enum ProfileTransform: String, Hashable, Sendable, CaseIterable {
    /// Codex `custom` tools (free-form input, e.g. `apply_patch`) become
    /// function tools taking `{"input": string}`, with their history calls
    /// and outputs to match; the reply is mapped back to `custom_tool_call`s
    /// by ``CustomToolReplyMapper``. Not for Responses targets.
    case customToolsToFunctions
    /// `developer` messages become `system` messages.
    case developerToSystem
    /// Every tool call gets a result: an unanswered call gets a synthetic
    /// "interrupted" error result; results answering no open call (or a
    /// call answered already) are dropped.
    case pairToolCalls
    /// Reasoning fidelity data from systems the endpoint does not trust is
    /// stripped (the text stays); Chat `reasoning_details` (bags, and the
    /// parts decoded from them) become reasoning text. For upstreams that reject others' reasoning (Kimi).
    case stripForeignReasoning
    /// Each assistant turn with tool calls, or continuing after tool results,
    /// gets reasoning text (`" "` if it had none), which the Chat encoder
    /// writes as `reasoning_content` (DeepSeek thinking mode requires it).
    /// Chat targets only.
    case replayReasoningContent
    /// The Anthropic twin of ``replayReasoningContent``: tool turns get a
    /// thinking block, and `redacted_thinking` the upstream cannot read
    /// becomes one (DeepSeek's Anthropic API). Anthropic targets only.
    case ensureThinkingOnToolTurns
    /// Content made only of text parts is written as a plain string, for
    /// compatible servers that reject part arrays. Chat targets only.
    case flattenTextParts
    /// Effort ↔ budget conversion per ``Profile/reasoningControl`` and
    /// ``Profile/effortBudgets``; effort levels clamped to
    /// ``Profile/effortLevels``.
    case mapReasoningEffort
    /// Removes parameters, tools, reasoning settings and images the model
    /// does not support, per the Profile's capability data.
    case dropUnsupportedParams
    /// Tool call ids that are not exactly nine ASCII letters and digits
    /// (`toolu_…`, `call_…`) are rewritten, with the results answering
    /// them, to nine-character ids derived from a hash of the original
    /// (collisions resolved deterministically); valid ids are kept. The
    /// same history always gets the same ids. Mistral rejects any other
    /// id; its own reply ids are valid everywhere, so replies need no
    /// mapping back.
    case mistralToolIDs
}

/// What a transform needs to know about its target.
@_spi(Wire) public struct WireTransformContext: Sendable {
    public var target: WireProtocol
    public var endpoint: Endpoint
    public var profile: Profile

    public init(target: WireProtocol, endpoint: Endpoint, profile: Profile) {
        self.target = target
        self.endpoint = endpoint
        self.profile = profile
    }
}

/// What applying transforms produced besides the request.
@_spi(Wire) public struct WireTransformOutcome: Sendable {
    public var warnings: [WireWarning] = []
    /// Names of custom tools turned into functions; feed them to a
    /// ``CustomToolReplyMapper`` for the reply.
    public var customTools: Set<String> = []

    public init() {}
}

extension ProfileTransform {
    /// Applies this transform to `request`.
    @_spi(Wire) public func apply(
        to request: inout WireRequest,
        context: WireTransformContext,
        outcome: inout WireTransformOutcome,
    ) {
        switch self {
        case .customToolsToFunctions:
            guard context.target != .responses else { return }
            outcome.customTools.formUnion(WireTransforms.customToolsToFunctions(&request, warnings: &outcome.warnings))
        case .developerToSystem:
            WireTransforms.developerToSystem(&request)
        case .pairToolCalls:
            WireTransforms.pairToolCalls(&request, warnings: &outcome.warnings)
        case .stripForeignReasoning:
            WireTransforms.stripForeignReasoning(&request, trusted: context.endpoint.trustedOrigins, warnings: &outcome.warnings)
        case .replayReasoningContent:
            guard context.target == .chatCompletions else { return }
            WireTransforms.replayReasoningContent(&request)
        case .ensureThinkingOnToolTurns:
            guard context.target == .anthropicMessages else { return }
            WireTransforms.ensureThinkingOnToolTurns(&request)
        case .flattenTextParts:
            guard context.target == .chatCompletions else { return }
            WireTransforms.flattenTextParts(&request, warnings: &outcome.warnings)
        case .mapReasoningEffort:
            WireTransforms.mapReasoningEffort(&request, profile: context.profile, warnings: &outcome.warnings)
        case .dropUnsupportedParams:
            WireTransforms.dropUnsupportedParams(&request, profile: context.profile, warnings: &outcome.warnings)
        case .mistralToolIDs:
            WireTransforms.mistralToolIDs(&request)
        }
    }

    /// Applies `names` in registry order (each at most once).
    @_spi(Wire) public static func apply(
        _ names: some Sequence<ProfileTransform>,
        to request: inout WireRequest,
        context: WireTransformContext,
    ) -> WireTransformOutcome {
        let wanted = Set(names)
        var outcome = WireTransformOutcome()
        for name in allCases where wanted.contains(name) {
            name.apply(to: &request, context: context, outcome: &outcome)
        }
        return outcome
    }
}
