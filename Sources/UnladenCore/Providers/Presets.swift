/// The built-in provider catalog, as data.
///
/// Model rules cover current flagship families by id prefix, not every
/// model; anything unmatched gets its endpoint's defaults. Register your own
/// rules or providers on a ``ProviderRegistry`` copy to extend or override.
public enum Presets {
    public static var all: [Provider] {
        [openAI, chatGPT, anthropic, gemini, deepSeek, moonshot, openRouter, groq, mistral, xAI, together, ollama]
    }

    // MARK: - Shared profiles

    /// Every upstream gets its tool exchanges mended.
    static let base: [ProfileTransform] = [.pairToolCalls, .customToolsToFunctions, .mapReasoningEffort, .dropUnsupportedParams]

    // Parameters each protocol has no field for, declared on every preset
    // endpoint of that protocol: left out with an `unsupported_by_model`
    // warning (reported, not an error under a strict policy) instead of
    // being dropped by the encoder as a loss.

    /// Chat Completions: no `top_k`.
    static let chatGaps: Set<SamplingParameter> = [.topK]
    /// Responses: no seed, stop, top_k, penalties or `n`.
    static let responsesGaps: Set<SamplingParameter> = [.seed, .stop, .topK, .frequencyPenalty, .presencePenalty, .candidateCount]
    /// Anthropic Messages: no seed, penalties, `n` or `response_format`.
    static let anthropicGaps: Set<SamplingParameter> = [.seed, .frequencyPenalty, .presencePenalty, .candidateCount, .responseFormat]
    /// Gemini: no `user`, no way to forbid parallel calls.
    static let geminiGaps: Set<SamplingParameter> = [.user, .parallelToolCalls]

    /// The gaps of `apiProtocol`.
    static func gaps(of apiProtocol: APIProtocol) -> Set<SamplingParameter> {
        switch apiProtocol {
        case .chatCompletions: chatGaps
        case .responses: responsesGaps
        case .anthropicMessages: anthropicGaps
        case .gemini: geminiGaps
        }
    }

    /// An endpoint for a provider the user describes (a relay, a local
    /// server): the transforms every preset endpoint gets and its
    /// protocol's gaps, nothing vendor-specific.
    @_spi(Wire) public static func customEndpoint(
        system: String, apiProtocol: APIProtocol, baseURL: String, auth: EndpointAuth, headers: [String: String] = [:],
    ) -> Endpoint {
        Endpoint(
            system: system, apiProtocol: apiProtocol, baseURL: baseURL, auth: auth, headers: headers,
            defaults: Profile(unsupportedParameters: gaps(of: apiProtocol), transforms: base),
        )
    }

    /// `provider` with each endpoint's defaults declaring its protocol's gaps.
    static func declaringProtocolGaps(_ provider: Provider) -> Provider {
        var provider = provider
        for i in provider.endpoints.indices {
            let gaps = Profile(unsupportedParameters: gaps(of: provider.endpoints[i].apiProtocol))
            provider.endpoints[i].defaults = provider.endpoints[i].defaults.merged(over: gaps)
        }
        return provider
    }

    /// Claude models before 4.6: budget thinking. Up to four cache
    /// breakpoints, honoured in Chat requests too (relays such as
    /// OpenRouter pass `cache_control` on to Claude).
    static let claudeDefaults = Profile(
        defaultMaxOutputTokens: 16000,
        maxOutputTokens: 64000,
        supportsReasoning: true,
        supportsTools: true,
        supportsImages: true,
        unsupportedParametersWhileReasoning: [.temperature, .topK],
        reasoningControl: .budget,
        effortBudgets: Profile.standardEffortBudgets,
        chatCacheControl: true,
        maxCacheBreakpoints: 4,
    )

    /// Claude model rules, keyed by the id the endpoint uses (`prefix` is
    /// `""` for Anthropic, `"anthropic/"` on OpenRouter).
    static func claudeRules(prefix: String, forcing forced: APIProtocol? = nil) -> [ModelRule] {
        let fourSix = Profile(
            maxOutputTokens: 128_000, reasoningControl: .effort, effortLevels: ["low", "medium", "high", "max"],
            forcedProtocol: forced,
        )
        // Claude 4.7 and later: adaptive thinking only, no sampling params.
        let current = Profile(
            maxOutputTokens: 128_000,
            unsupportedParameters: [.temperature, .topP, .topK],
            reasoningControl: .effort,
            effortLevels: ["low", "medium", "high", "xhigh", "max"],
            forcedProtocol: forced,
        )
        return [
            ModelRule(.prefix(prefix + "claude-"), claudeDefaults.merged(over: Profile(forcedProtocol: forced))),
            ModelRule(.prefix(prefix + "claude-opus-4-5"), Profile(
                maxOutputTokens: 64000, effortLevels: ["low", "medium", "high"], forcedProtocol: forced,
            ).merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-opus-4-6"), fourSix.merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-sonnet-4-6"), fourSix.merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-opus-4-7"), current.merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-opus-4-8"), current.merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-opus-5"), current.merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-sonnet-5"), current.merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-haiku-5"), current.merged(over: claudeDefaults)),
            ModelRule(.prefix(prefix + "claude-fable-5"), current.merged(over: claudeDefaults)),
        ]
    }

    /// OpenAI reasoning families.
    static func openAIRules(prefix: String) -> [ModelRule] {
        let reasoning = Profile(
            supportsReasoning: true,
            unsupportedParameters: [.temperature, .topP, .presencePenalty, .frequencyPenalty],
            reasoningControl: .effort,
        )
        return [
            ModelRule(.prefix(prefix + "gpt-5"), Profile(effortLevels: ["minimal", "low", "medium", "high"]).merged(over: reasoning)),
            // The ChatGPT model (`gpt-5-chat-latest`): no reasoning, sampling
            // parameters as usual.
            ModelRule(.prefix(prefix + "gpt-5-chat"), Profile(supportsReasoning: false)),
            ModelRule(.prefix(prefix + "gpt-5.1"), Profile(effortLevels: ["none", "low", "medium", "high"]).merged(over: reasoning)),
            ModelRule(.prefix(prefix + "gpt-5.2"), Profile(effortLevels: ["none", "low", "medium", "high", "xhigh"]).merged(over: reasoning)),
            ModelRule(.prefix(prefix + "o1"), Profile(effortLevels: ["low", "medium", "high"]).merged(over: reasoning)),
            ModelRule(.prefix(prefix + "o3"), Profile(effortLevels: ["low", "medium", "high"]).merged(over: reasoning)),
            ModelRule(.prefix(prefix + "o4"), Profile(effortLevels: ["low", "medium", "high"]).merged(over: reasoning)),
        ]
    }

    // MARK: - Providers

    public static let openAI = declaringProtocolGaps(Provider(
        id: "openai",
        apiKeyEnvironmentVariables: ["OPENAI_API_KEY"],
        endpoints: [
            Endpoint(system: "openai", apiProtocol: .responses, baseURL: "https://api.openai.com/v1",
                     forwardedHeaders: ["openai-organization", "openai-project"], defaults: Profile(transforms: base)),
            Endpoint(system: "openai", apiProtocol: .chatCompletions, baseURL: "https://api.openai.com/v1",
                     forwardedHeaders: ["openai-organization", "openai-project"],
                     defaults: Profile(maxTokensField: .maxCompletionTokens, transforms: base)),
        ],
        models: openAIRules(prefix: ""),
    ))

    /// A ChatGPT plan used through OpenAI's API, as OpenAI's "Sign in with
    /// ChatGPT" lets an app on the user's own machine: no API key, but the
    /// signed-in account's access token. Streamed, and fitted by
    /// ``ProfileTransform/chatgptSubscription``; the plan's usage limit is
    /// shared with ChatGPT itself.
    public static let chatGPT = declaringProtocolGaps(Provider(
        id: "chatgpt",
        endpoints: [
            Endpoint(system: "openai", apiProtocol: .responses, baseURL: "https://api.openai.com/v1",
                     defaults: Profile(unsupportedParameters: [.temperature, .topP, .user], streaming: .always,
                                       transforms: base + [.chatgptSubscription])),
        ],
        models: openAIRules(prefix: ""),
    ))

    public static let anthropic = declaringProtocolGaps(Provider(
        id: "anthropic",
        apiKeyEnvironmentVariables: ["ANTHROPIC_API_KEY"],
        endpoints: [
            Endpoint(system: "anthropic", apiProtocol: .anthropicMessages, baseURL: "https://api.anthropic.com",
                     auth: .anthropic(), forwardedHeaders: ["anthropic-beta", "anthropic-version"],
                     defaults: Profile(transforms: base).merged(over: claudeDefaults)),
        ],
        models: claudeRules(prefix: ""),
    ))

    public static let gemini = declaringProtocolGaps(Provider(
        id: "gemini",
        apiKeyEnvironmentVariables: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        endpoints: [
            Endpoint(system: "gemini", apiProtocol: .gemini, baseURL: "https://generativelanguage.googleapis.com",
                     auth: .googleAPIKey,
                     defaults: Profile(
                        supportsReasoning: true, supportsTools: true, supportsImages: true,
                        reasoningControl: .budget, effortBudgets: Profile.standardEffortBudgets, transforms: base,
                     )),
        ],
        models: [
            ModelRule(.prefix("gemini-3"), Profile(
                reasoningControl: .thinkingLevel,
                effortLevels: ["minimal", "low", "medium", "high"],
                geminiMissingSignatureFallback: GeminiRequestOptions.skipSignatureValidator,
            )),
            ModelRule(.prefix("gemini-3-pro"), Profile(
                reasoningControl: .thinkingLevel,
                effortLevels: ["low", "high"],
                geminiMissingSignatureFallback: GeminiRequestOptions.skipSignatureValidator,
            )),
        ],
    ))

    public static let deepSeek = declaringProtocolGaps(Provider(
        id: "deepseek",
        apiKeyEnvironmentVariables: ["DEEPSEEK_API_KEY"],
        endpoints: [
            Endpoint(system: "deepseek", apiProtocol: .chatCompletions, baseURL: "https://api.deepseek.com/v1",
                     defaults: Profile(
                        defaultMaxOutputTokens: 8192, maxTokensField: .maxTokens,
                        transforms: base + [.replayReasoningContent, .developerToSystem],
                     )),
            // Takes Claude's signed thinking, its own, and unsigned thinking;
            // effort only through output_config.effort (low/high/max).
            Endpoint(system: "deepseek", apiProtocol: .anthropicMessages, baseURL: "https://api.deepseek.com/anthropic",
                     auth: .anthropic(), trustedOrigins: ["deepseek", "anthropic"],
                     defaults: Profile(
                        defaultMaxOutputTokens: 8192, reasoningControl: .effort, effortLevels: ["low", "high", "max"],
                        acceptsUnsignedThinking: true, transforms: base + [.ensureThinkingOnToolTurns],
                     )),
        ],
    ))

    public static let moonshot = declaringProtocolGaps(Provider(
        id: "moonshot",
        apiKeyEnvironmentVariables: ["MOONSHOT_API_KEY"],
        endpoints: [
            // Kimi turns away other vendors' reasoning_details.
            Endpoint(system: "moonshot", apiProtocol: .chatCompletions, baseURL: "https://api.moonshot.ai/v1",
                     defaults: Profile(maxTokensField: .maxTokens, transforms: base + [.stripForeignReasoning, .replayReasoningContent])),
            Endpoint(system: "moonshot", apiProtocol: .anthropicMessages, baseURL: "https://api.moonshot.ai/anthropic",
                     auth: .anthropic(), defaults: Profile(acceptsUnsignedThinking: true, transforms: base)),
        ],
        models: [
            ModelRule(.prefix("kimi-k2"), Profile(supportsReasoning: true, supportsTools: true, reasoningControl: .uncontrolled)),
        ],
    ))

    public static let openRouter = declaringProtocolGaps(Provider(
        id: "openrouter",
        apiKeyEnvironmentVariables: ["OPENROUTER_API_KEY"],
        endpoints: [
            Endpoint(system: "openrouter", apiProtocol: .chatCompletions, baseURL: "https://openrouter.ai/api/v1",
                     forwardedHeaders: ["http-referer", "x-title"], defaults: Profile(transforms: base)),
            Endpoint(system: "openrouter", apiProtocol: .anthropicMessages, baseURL: "https://openrouter.ai/api",
                     auth: .bearer, forwardedHeaders: ["http-referer", "x-title", "anthropic-beta"],
                     defaults: Profile(defaultMaxOutputTokens: 16000, transforms: base)),
        ],
        // Claude goes through Messages, which keeps cache breakpoints.
        models: claudeRules(prefix: "anthropic/", forcing: .anthropicMessages) + openAIRules(prefix: "openai/"),
    ))

    public static let groq = declaringProtocolGaps(Provider(
        id: "groq",
        apiKeyEnvironmentVariables: ["GROQ_API_KEY"],
        endpoints: [
            Endpoint(system: "groq", apiProtocol: .chatCompletions, baseURL: "https://api.groq.com/openai/v1",
                     defaults: Profile(transforms: base + [.flattenTextParts])),
        ],
    ))

    public static let mistral = declaringProtocolGaps(Provider(
        id: "mistral",
        apiKeyEnvironmentVariables: ["MISTRAL_API_KEY"],
        endpoints: [
            // 422 extra_forbidden on any field it does not know.
            Endpoint(system: "mistral", apiProtocol: .chatCompletions, baseURL: "https://api.mistral.ai/v1",
                     defaults: Profile(maxTokensField: .maxTokens, strictUnknownFields: true, chatStreamUsage: false, transforms: base + [.mistralToolIDs])),
        ],
    ))

    public static let xAI = declaringProtocolGaps(Provider(
        id: "xai",
        apiKeyEnvironmentVariables: ["XAI_API_KEY"],
        endpoints: [
            Endpoint(system: "xai", apiProtocol: .responses, baseURL: "https://api.x.ai/v1", defaults: Profile(transforms: base)),
            Endpoint(system: "xai", apiProtocol: .chatCompletions, baseURL: "https://api.x.ai/v1", defaults: Profile(transforms: base)),
        ],
        models: [
            // Grok 4 reasons always and takes no effort, penalties or stop.
            ModelRule(.prefix("grok-4"), Profile(
                supportsReasoning: true,
                unsupportedParameters: [.presencePenalty, .frequencyPenalty, .stop],
                reasoningControl: .uncontrolled,
            )),
        ],
    ))

    public static let together = declaringProtocolGaps(Provider(
        id: "together",
        apiKeyEnvironmentVariables: ["TOGETHER_API_KEY"],
        endpoints: [
            Endpoint(system: "together", apiProtocol: .chatCompletions, baseURL: "https://api.together.xyz/v1",
                     defaults: Profile(transforms: base)),
        ],
    ))

    public static let ollama = declaringProtocolGaps(Provider(
        id: "ollama",
        endpoints: [
            Endpoint(system: "ollama", apiProtocol: .chatCompletions, baseURL: "http://localhost:11434/v1",
                     auth: .none, defaults: Profile(transforms: base + [.flattenTextParts])),
            Endpoint(system: "ollama", apiProtocol: .anthropicMessages, baseURL: "http://localhost:11434",
                     auth: .none, defaults: Profile(acceptsUnsignedThinking: true, transforms: base)),
        ],
    ))
}
