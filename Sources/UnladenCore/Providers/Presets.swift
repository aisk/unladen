/// The built-in provider catalog, as data.
///
/// Model rules cover current flagship families by id prefix, not every
/// model; anything unmatched gets its endpoint's defaults. Register your own
/// rules or providers on a ``ProviderRegistry`` copy to extend or override.
public enum Presets {
    public static var all: [Provider] {
        [
            openAI, chatGPT, anthropic, gemini, antigravity, deepSeek, moonshot, moonshotChina, kimiCode, kimiCodeChina,
            zai, zaiCoding, zhipu, zhipuCoding, miniMax, miniMaxChina, stepPlan, stepPlanChina, arkCoding, bailianTokenPlan,
            openRouter, openCodeZen, openCodeGo, kilo, groq, mistral, xAI, together, nvidia, modelScope, siliconFlow,
            siliconFlowGlobal, ollama,
        ]
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

    /// An Antigravity subscription, signed in with Google, through Google's
    /// Code Assist backend: Gemini's API inside an envelope of its own,
    /// which the gateway adds and removes (UnladenServer's
    /// `CodeAssistTransport`). Gemini, Claude and gpt-oss models, by
    /// Antigravity's own ids. Not an API Google offers to other apps.
    public static let antigravity = declaringProtocolGaps(Provider(
        id: "antigravity",
        endpoints: [
            Endpoint(system: "antigravity", apiProtocol: .gemini, baseURL: "https://daily-cloudcode-pa.googleapis.com",
                     auth: .bearer,
                     defaults: Profile(
                        supportsReasoning: true, supportsTools: true, supportsImages: true,
                        reasoningControl: .budget, effortBudgets: Profile.standardEffortBudgets, streaming: .always,
                        geminiMissingSignatureFallback: GeminiRequestOptions.skipSignatureValidator, geminiSchemaKey: .parameters,
                        transforms: base,
                     )),
        ],
        models: [
            ModelRule(.prefix("gemini-3"), Profile(reasoningControl: .thinkingLevel, effortLevels: ["minimal", "low", "medium", "high"])),
            ModelRule(.prefix("gemini-pro-agent"), Profile(reasoningControl: .thinkingLevel, effortLevels: ["low", "high"])),
            ModelRule(.prefix("gpt-oss"), Profile(supportsReasoning: false)),
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

    // MARK: - Vendors' own APIs

    /// One of a vendor's endpoints: the protocol's usual credentials, the
    /// transforms every preset gets, and `profile` over them. Chat
    /// endpoints send `max_tokens`, which these vendors document (OpenAI's
    /// own Chat API is the one that wants `max_completion_tokens`).
    static func endpoint(
        _ system: String, _ apiProtocol: APIProtocol, _ address: String, _ profile: Profile = Profile(),
        headers: [String: String] = [:], sessionHeader: String? = nil,
    ) -> Endpoint {
        var defaults = Profile(transforms: base)
        if apiProtocol == .chatCompletions { defaults.maxTokensField = .maxTokens }
        return Endpoint(
            system: system, apiProtocol: apiProtocol, baseURL: address, auth: apiProtocol == .anthropicMessages ? .anthropic() : .bearer,
            headers: headers, defaults: profile.merged(over: defaults), sessionHeader: sessionHeader,
        )
    }

    /// A provider of `endpoints`, in order of preference.
    static func vendor(
        _ id: String, environment: [String] = [], servesWithoutKey: Bool = false, _ endpoints: [Endpoint], models: [ModelRule] = [],
    ) -> Provider {
        declaringProtocolGaps(Provider(
            id: id, apiKeyEnvironmentVariables: environment, servesWithoutKey: servesWithoutKey, endpoints: endpoints, models: models,
        ))
    }

    /// Kimi's pay-as-you-go API (`moonshot`) and its China site's.
    public static let moonshot = kimi("moonshot", root: "https://api.moonshot.ai", anthropic: "https://api.moonshot.ai/anthropic",
                                      environment: ["MOONSHOT_API_KEY"])
    public static let moonshotChina = kimi("moonshot-cn", root: "https://api.moonshot.cn", anthropic: "https://api.moonshot.cn/anthropic")

    /// A Kimi Code membership's own endpoints, keyed at its console: the
    /// membership's key is not taken by the pay-as-you-go API.
    public static let kimiCode = kimi("kimi-code", root: "https://api.kimi.ai/coding", anthropic: "https://api.kimi.ai/coding")
    public static let kimiCodeChina = kimi("kimi-code-cn", root: "https://api.kimi.com/coding", anthropic: "https://api.kimi.com/coding")

    static func kimi(_ id: String, root: String, anthropic: String, environment: [String] = []) -> Provider {
        vendor(id, environment: environment, [
            // Kimi turns away other vendors' reasoning_details.
            endpoint("moonshot", .chatCompletions, root + "/v1", Profile(transforms: base + [.stripForeignReasoning, .replayReasoningContent])),
            endpoint("moonshot", .anthropicMessages, anthropic, Profile(acceptsUnsignedThinking: true)),
        ], models: [
            ModelRule(.prefix("kimi-k2"), Profile(supportsReasoning: true, supportsTools: true, reasoningControl: .uncontrolled)),
        ])
    }

    /// Z.ai's and Zhipu's (open.bigmodel.cn) pay-as-you-go APIs, and their
    /// GLM Coding Plans. A plan's key is told it has no balance at the
    /// pay-as-you-go Chat endpoint: the plan has one of its own, and serves
    /// the Responses API too. Both take Anthropic messages at one address.
    public static let zai = glm("zai", host: "https://api.z.ai", coding: false, environment: ["ZAI_API_KEY"])
    public static let zaiCoding = glm("zai-coding", host: "https://api.z.ai", coding: true)
    public static let zhipu = glm("zhipu", host: "https://open.bigmodel.cn", coding: false, environment: ["ZHIPUAI_API_KEY"])
    public static let zhipuCoding = glm("zhipu-coding", host: "https://open.bigmodel.cn", coding: true)

    static func glm(_ id: String, host: String, coding: Bool, environment: [String] = []) -> Provider {
        let chat = endpoint("zhipu", .chatCompletions, host + (coding ? "/api/coding/paas/v4" : "/api/paas/v4"))
        let responses = endpoint("zhipu", .responses, host + "/api/v1")
        let anthropic = endpoint("zhipu", .anthropicMessages, host + "/api/anthropic", Profile(acceptsUnsignedThinking: true))
        return vendor(id, environment: environment, coding ? [chat, responses, anthropic] : [chat, anthropic], models: [
            ModelRule(.prefix("glm-"), Profile(supportsReasoning: true, supportsTools: true, reasoningControl: .uncontrolled)),
        ])
    }

    /// MiniMax, international and China. Its Chat API puts a model's
    /// thinking in the text between `<think>` tags, so Messages comes first.
    public static let miniMax = miniMax("minimax", host: "https://api.minimax.io", environment: ["MINIMAX_API_KEY"])
    public static let miniMaxChina = miniMax("minimax-cn", host: "https://api.minimaxi.com")

    static func miniMax(_ id: String, host: String, environment: [String] = []) -> Provider {
        vendor(id, environment: environment, [
            endpoint("minimax", .anthropicMessages, host + "/anthropic", Profile(acceptsUnsignedThinking: true)),
            endpoint("minimax", .chatCompletions, host + "/v1"),
        ])
    }

    /// StepFun's Step Plan, international and China: served at its own
    /// endpoints, its key refused at the pay-as-you-go ones.
    public static let stepPlan = vendor("step-plan", [
        endpoint("stepfun", .chatCompletions, "https://api.stepfun.ai/step_plan/v1"),
        endpoint("stepfun", .anthropicMessages, "https://api.stepfun.ai/step_plan"),
    ])
    public static let stepPlanChina = vendor("step-plan-cn", [
        endpoint("stepfun", .chatCompletions, "https://api.stepfun.com/step_plan/v1"),
        endpoint("stepfun", .anthropicMessages, "https://api.stepfun.com/step_plan"),
    ])

    /// Volcengine Ark's Coding Plan, with a key of its own; pay as you go
    /// (`/api/v3`) bills apart. Its paths are versioned already.
    public static let arkCoding = vendor("ark-coding", [
        endpoint("volcengine", .chatCompletions, "https://ark.cn-beijing.volces.com/api/coding/v3"),
        endpoint("volcengine", .responses, "https://ark.cn-beijing.volces.com/api/coding/v3"),
        endpoint("volcengine", .anthropicMessages, "https://ark.cn-beijing.volces.com/api/coding"),
    ])

    /// Alibaba Cloud Bailian's Token Plan: its own `sk-sp-` keys, taken
    /// only at its own host.
    public static let bailianTokenPlan = vendor("bailian-token-plan", [
        endpoint("dashscope", .chatCompletions, "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"),
        endpoint("dashscope", .anthropicMessages, "https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic"),
    ])

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

    /// OpenCode Zen, pay as you go with an OpenCode key. Its free models
    /// are for OpenCode alone, and are turned away from other clients.
    public static let openCodeZen = openCode("opencode-zen", root: "https://opencode.ai/inference")

    /// OpenCode Go, a subscription to open coding models, for coding
    /// agents that name themselves and each conversation.
    public static let openCodeGo = openCode("opencode-go", root: "https://opencode.ai/inference/go")

    /// OpenCode's gateway: it routes and caches by the conversation named
    /// in `x-opencode-session`, and Go refuses a request without one.
    static func openCode(_ id: String, root: String) -> Provider {
        func at(_ apiProtocol: APIProtocol, _ address: String) -> Endpoint {
            endpoint("opencode", apiProtocol, address, headers: ["user-agent": "unladen"], sessionHeader: "x-opencode-session")
        }
        return vendor(id, [
            at(.chatCompletions, root + "/openai/v1"), at(.responses, root + "/openai/v1"), at(.anthropicMessages, root + "/anthropic"),
        ])
    }

    /// Kilo Code's gateway, OpenRouter's API: its free models (`…:free`,
    /// `kilo-auto/free`) answer anyone, a limited number of requests an
    /// hour from one address; a Kilo key reaches the rest.
    public static let kilo = vendor("kilo", servesWithoutKey: true, [endpoint("kilo", .chatCompletions, "https://api.kilo.ai/api/openrouter")])

    public static let groq = vendor("groq", environment: ["GROQ_API_KEY"], [
        endpoint("groq", .chatCompletions, "https://api.groq.com/openai/v1", Profile(transforms: base + [.flattenTextParts])),
    ])

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

    public static let together = vendor("together", environment: ["TOGETHER_API_KEY"], [
        endpoint("together", .chatCompletions, "https://api.together.xyz/v1"),
    ])

    /// NVIDIA's hosted NIM models, free to try with a developer key.
    public static let nvidia = vendor("nvidia", environment: ["NVIDIA_API_KEY"], [
        endpoint("nvidia", .chatCompletions, "https://integrate.api.nvidia.com/v1"),
    ])

    /// ModelScope's API-Inference, with a ModelScope access token: a
    /// number of free calls a day.
    public static let modelScope = vendor("modelscope", environment: ["MODELSCOPE_API_KEY"], [
        endpoint("modelscope", .chatCompletions, "https://api-inference.modelscope.cn/v1"),
        endpoint("modelscope", .responses, "https://api-inference.modelscope.cn/v1"),
    ])

    /// SiliconFlow, China and international: separate accounts and keys,
    /// some models free.
    public static let siliconFlow = vendor("siliconflow", environment: ["SILICONFLOW_API_KEY"], [
        endpoint("siliconflow", .chatCompletions, "https://api.siliconflow.cn/v1"),
    ])
    public static let siliconFlowGlobal = vendor("siliconflow-global", [
        endpoint("siliconflow", .chatCompletions, "https://api.siliconflow.com/v1"),
    ])

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
