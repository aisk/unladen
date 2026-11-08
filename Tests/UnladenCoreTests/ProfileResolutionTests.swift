import Testing
@_spi(Wire) import UnladenCore

@Suite struct ProfileResolutionTests {
    static let chat = Endpoint(
        system: "lab", apiProtocol: .chatCompletions, baseURL: "https://lab.example/v1",
        defaults: Profile(defaultMaxOutputTokens: 1000, supportsTools: true, transforms: [.pairToolCalls]),
    )
    static let messages = Endpoint(system: "lab", apiProtocol: .anthropicMessages, baseURL: "https://lab.example")

    @Test func exactBeatsLongestPrefixBeatsPattern() throws {
        let provider = Provider(id: "lab", endpoints: [Self.chat], models: [
            ModelRule(.pattern("m-*"), Profile(maxOutputTokens: 1)),
            ModelRule(.prefix("m-"), Profile(maxOutputTokens: 2)),
            ModelRule(.prefix("m-large"), Profile(maxOutputTokens: 3)),
            ModelRule(.exact("m-large-2"), Profile(maxOutputTokens: 4)),
            ModelRule(.pattern("x-*-mini"), Profile(maxOutputTokens: 5)),
            ModelRule(.pattern("x-*"), Profile(maxOutputTokens: 6)),
        ])
        #expect(provider.rule(for: "m-large-2")?.profile.maxOutputTokens == 4)
        #expect(provider.rule(for: "M-LARGE-2")?.profile.maxOutputTokens == 4)
        #expect(provider.rule(for: "m-large-3")?.profile.maxOutputTokens == 3)
        #expect(provider.rule(for: "m-small")?.profile.maxOutputTokens == 2)
        // Patterns: first match in declaration order.
        #expect(provider.rule(for: "x-a-mini")?.profile.maxOutputTokens == 5)
        #expect(provider.rule(for: "x-a-max")?.profile.maxOutputTokens == 6)
        #expect(provider.rule(for: "other") == nil)
    }

    @Test func modelRuleMergesOverEndpointDefaults() throws {
        let provider = Provider(id: "lab", endpoints: [Self.chat], models: [
            ModelRule(.prefix("m-"), Profile(defaultMaxOutputTokens: 2000, supportsTools: false)),
        ])
        let resolved = try provider.resolve(model: "m-1")
        #expect(resolved.profile.defaultMaxOutputTokens == 2000)
        #expect(resolved.profile.supportsTools == false)
        // Unset in the rule: the endpoint's value stands.
        #expect(resolved.profile.transforms == [.pairToolCalls])
        // No rule: endpoint defaults alone.
        #expect(try provider.resolve(model: "z").profile == Self.chat.defaults)
    }

    @Test func endpointChoice() throws {
        let provider = Provider(id: "lab", endpoints: [Self.chat, Self.messages], models: [
            ModelRule(.prefix("claude-"), Profile(forcedProtocol: .anthropicMessages)),
            ModelRule(.prefix("gemini-"), Profile(forcedProtocol: .gemini)),
        ])
        #expect(try provider.resolve(model: "m").endpoint.apiProtocol == .chatCompletions)
        #expect(try provider.resolve(model: "m", preferring: .anthropicMessages).endpoint.apiProtocol == .anthropicMessages)
        #expect(try provider.resolve(model: "m", preferring: .responses).endpoint.apiProtocol == .chatCompletions)
        #expect(try provider.resolve(model: "claude-x", preferring: .chatCompletions).endpoint.apiProtocol == .anthropicMessages)
        #expect(throws: ModelReferenceError.forcedProtocolUnavailable(provider: "lab", model: "gemini-1", .gemini)) {
            try provider.resolve(model: "gemini-1")
        }
    }

    @Test func parsesReferencesWithNestedSlashes() throws {
        let registry = ProviderRegistry.builtIn
        let claude = try registry.resolve("anthropic/claude-opus-4-6")
        #expect(claude.provider == "anthropic")
        #expect(claude.model == "claude-opus-4-6")
        #expect(claude.endpoint.apiProtocol == .anthropicMessages)
        #expect(claude.profile.effortLevels == ["low", "medium", "high", "max"])
        #expect(claude.profile.reasoningControl == .effort)

        let routed = try registry.resolve("openrouter/anthropic/claude-sonnet-4-6", preferring: .chatCompletions)
        #expect(routed.provider == "openrouter")
        #expect(routed.model == "anthropic/claude-sonnet-4-6")
        #expect(routed.endpoint.apiProtocol == .anthropicMessages)
        #expect(routed.endpoint.baseURL == "https://openrouter.ai/api")

        let other = try registry.resolve("openrouter/meta-llama/llama-4-maverick", preferring: .chatCompletions)
        #expect(other.model == "meta-llama/llama-4-maverick")
        #expect(other.endpoint.apiProtocol == .chatCompletions)

        let o3 = try registry.resolve("openai/o3-mini")
        #expect(o3.endpoint.apiProtocol == .responses)
        #expect(o3.profile.unsupportedParameters?.contains(.temperature) == true)
        #expect(try registry.resolve("openai/gpt-5.1-codex").profile.effortLevels?.first == "none")

        #expect(throws: ModelReferenceError.malformed("gpt-4o")) { try registry.resolve("gpt-4o") }
        #expect(throws: ModelReferenceError.malformed("openai/")) { try registry.resolve("openai/") }
        #expect(throws: ModelReferenceError.unknownProvider("nope")) { try registry.resolve("nope/m") }
    }

    @Test func presetsAreWellFormed() throws {
        let ids = Set(Presets.all.map(\.id))
        #expect(ids == ["openai", "chatgpt", "anthropic", "gemini", "deepseek", "moonshot", "openrouter", "groq", "mistral", "xai", "together", "ollama"])
        for provider in Presets.all {
            #expect(!provider.endpoints.isEmpty)
            for endpoint in provider.endpoints {
                #expect(BaseURL(endpoint.baseURL) != nil, "\(provider.id): \(endpoint.baseURL)")
                #expect(endpoint.trustedOrigins.contains(endpoint.system))
            }
        }
        #expect(Presets.ollama.endpoints.allSatisfy { $0.auth == .none })
        #expect(try ProviderRegistry.builtIn.resolve("moonshot/kimi-k2-thinking").profile.reasoningControl == .uncontrolled)
        #expect(try ProviderRegistry.builtIn.resolve("deepseek/deepseek-chat", preferring: .anthropicMessages).endpoint.trustedOrigins
            == ["deepseek", "anthropic"])
    }

    @Test func runtimeRegistrationIsAValue() throws {
        var registry = ProviderRegistry.builtIn
        registry.register(Provider(id: "lab", endpoints: [Self.chat]))
        try registry.addModelRules([ModelRule(.prefix("claude-opus-4-6"), Profile(maxOutputTokens: 777))], to: "anthropic")
        #expect(try registry.resolve("lab/anything").endpoint.baseURL == "https://lab.example/v1")
        // A user's rule wins over a preset's prefix of the same length; the
        // rest of the preset Profile (endpoint defaults) still applies.
        let opus = try registry.resolve("anthropic/claude-opus-4-6")
        #expect(opus.profile.maxOutputTokens == 777)
        #expect(opus.profile.transforms?.contains(.pairToolCalls) == true)
        // The built-in catalog is untouched.
        #expect(ProviderRegistry.builtIn["lab"] == nil)
        #expect(try ProviderRegistry.builtIn.resolve("anthropic/claude-opus-4-6").profile.maxOutputTokens == 128_000)
        #expect(throws: ModelReferenceError.unknownProvider("x")) { try registry.addModelRules([], to: "x") }
    }

    @Test func mergeReplacesOnlySetFields() {
        let base = Profile(maxOutputTokens: 10, effortLevels: ["low"], transforms: [.pairToolCalls])
        let merged = Profile(effortLevels: ["high"], streaming: .always).merged(over: base)
        #expect(merged == Profile(maxOutputTokens: 10, effortLevels: ["high"], streaming: .always, transforms: [.pairToolCalls]))
    }
}
