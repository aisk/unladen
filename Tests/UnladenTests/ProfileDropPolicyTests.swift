import Testing
import Unladen

/// The strict policy and Profile-declared drops: a parameter a model's
/// Profile says it does not take is left out and reported, not thrown;
/// what a protocol or model cannot carry without a Profile saying so, and
/// content, still throws.
@Suite struct ProfileDropPolicyTests {
    /// One model per built-in preset.
    static let models = [
        "openai/gpt-5", "anthropic/claude-sonnet-5", "gemini/gemini-2.5-flash", "deepseek/deepseek-chat",
        "moonshot/kimi-k2-0905-preview", "openrouter/anthropic/claude-sonnet-4-5", "groq/llama-3.3-70b-versatile",
        "mistral/mistral-small-latest", "xai/grok-4", "together/meta-llama/Llama-3.3-70B-Instruct-Turbo", "ollama/llama3.2",
    ]

    /// Parameter settings a caller may send to any model.
    static let settings: [(String, GenerationSettings)] = [
        ("temperature", GenerationSettings(temperature: 0.5)),
        ("topP", GenerationSettings(topP: 0.9)),
        ("topK", GenerationSettings(topK: 40)),
        ("seed", GenerationSettings(seed: 7)),
        ("frequencyPenalty", GenerationSettings(frequencyPenalty: 0.1)),
        ("presencePenalty", GenerationSettings(presencePenalty: 0.1)),
        ("stopSequences", GenerationSettings(stopSequences: ["END"])),
        ("responseFormat json", GenerationSettings(responseFormat: .json)),
        ("responseFormat schema", GenerationSettings(responseFormat: .jsonSchema(["type": "object"], name: "out"))),
        ("parallelToolCalls", GenerationSettings(parallelToolCalls: true)),
        ("no parallelToolCalls", GenerationSettings(parallelToolCalls: false)),
        ("user", GenerationSettings(user: "user-1")),
        ("reasoning effort", GenerationSettings(reasoning: .effort(.medium))),
        ("reasoning budget", GenerationSettings(reasoning: .budget(2048))),
        ("everything", GenerationSettings(
            temperature: 0.5, topP: 0.9, topK: 40, frequencyPenalty: 0.1, presencePenalty: 0.1, stopSequences: ["END"],
            seed: 7, reasoning: .effort(.medium), responseFormat: .json, parallelToolCalls: true, user: "user-1",
        )),
    ]

    /// Presets whose Profile says how reasoning is controlled (or that the
    /// model takes no reasoning settings): a budget is converted or
    /// declared unsupported. Elsewhere an explicit budget that Chat cannot
    /// carry is an undeclared loss and still throws
    /// (``undeclaredProtocolLossStillThrows()``).
    static let declaresReasoning: Set<String> = [
        "openai/gpt-5", "anthropic/claude-sonnet-5", "gemini/gemini-2.5-flash", "moonshot/kimi-k2-0905-preview",
        "openrouter/anthropic/claude-sonnet-4-5", "xai/grok-4",
    ]

    static let cases: [(String, Int)] = models.flatMap { model in
        settings.indices.filter { settings[$0].0 != "reasoning budget" || declaresReasoning.contains(model) }.map { (model, $0) }
    }

    static let keys = [
        "openai", "anthropic", "gemini", "deepseek", "moonshot", "openrouter", "groq", "mistral", "xai", "together",
    ].reduce(into: [String: String]()) { $0[$1] = "key-\($1)" }

    /// A minimal complete reply in `apiProtocol`'s shape.
    static func reply(_ apiProtocol: APIProtocol) -> String {
        switch apiProtocol {
        case .chatCompletions:
            #"{"id":"c","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
        case .responses:
            #"{"id":"r","object":"response","created_at":1,"status":"completed","model":"m","output":[{"id":"m1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","annotations":[],"text":"ok"}]}]}"#
        case .anthropicMessages:
            #"{"id":"a","type":"message","role":"assistant","model":"m","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
        case .gemini:
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#
        }
    }

    static let tool = Tool(name: "get_weather", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

    func model(_ reference: String) throws -> (LanguageModel, FakeProvider) {
        let resolved = try ModelClient(transport: MockTransport { _, _ in fatalError() }, apiKeys: Self.keys, environment: [:]).model(reference)
        let fake = FakeProvider(.json(Self.reply(resolved.target.endpoint.apiProtocol)))
        let client = ModelClient(transport: fake.transport, apiKeys: Self.keys, environment: [:], warningPolicy: .strict)
        return (try client.model(reference), fake)
    }

    @Test(arguments: cases)
    func declaredDropsAreReportedNotThrown(_ reference: String, _ index: Int) async throws {
        let (name, settings) = Self.settings[index]
        let (model, provider) = try model(reference)
        do {
            let response = try await model.generate([.user("Weather in Paris?")], tools: [Self.tool], settings: settings)
            #expect(response.text == "ok")
            #expect(provider.requests.count == 1)
            let escalated = response.warnings.filter(\.isEscalatedWhenStrict)
            #expect(escalated.isEmpty, "\(reference) \(name): \(escalated)")
        } catch {
            Issue.record("\(reference) \(name): \(error)")
        }
    }

    /// Content is not a parameter: an image to a model that takes none
    /// still throws under strict.
    @Test func imageToATextOnlyModelStillThrows() async throws {
        var registry = ProviderRegistry.builtIn
        try registry.addModelRules([ModelRule(.exact("text-only"), Profile(supportsImages: false))], to: "together")
        let provider = FakeProvider(.json(Self.reply(.chatCompletions)))
        let client = ModelClient(transport: provider.transport, registry: registry, apiKeys: Self.keys, environment: [:])
        let model = try client.model("together/text-only")
        await #expect(throws: UnladenError.self) {
            _ = try await model.generate([.user([.text("What is this?"), .image(.url("https://example.com/a.png"))])])
        }
        #expect(provider.requests.isEmpty)
    }

    /// What no Profile declares stays an error: a protocol-level loss.
    @Test func undeclaredProtocolLossStillThrows() async throws {
        let provider = FakeProvider(.json(Self.reply(.chatCompletions)))
        let client = ModelClient(transport: provider.transport, apiKeys: Self.keys, environment: [:])
        let model = try client.model("together/meta-llama/Llama-3.3-70B-Instruct-Turbo")
        // Chat carries only an effort; an explicit budget is lost.
        await #expect(throws: UnladenError.self) {
            _ = try await model.generate("Hi", settings: GenerationSettings(reasoning: ReasoningSettings(effort: .low, budgetTokens: 100)))
        }
        #expect(provider.requests.isEmpty)
    }

    @Test func declaredDropHasItsOwnCode() async throws {
        let provider = FakeProvider(.json(Self.reply(.responses)))
        let client = ModelClient(transport: provider.transport, apiKeys: Self.keys, environment: [:])
        let response = try await client.model("openai/gpt-5").generate("Hi", settings: GenerationSettings(temperature: 0.2))
        let warning = try #require(response.warnings.first { $0.path == "temperature" })
        #expect(warning.code == .unsupportedByModel)
        #expect(!warning.isEscalatedWhenStrict)
        #expect(provider.lastBody["temperature"] == nil)
    }
}
