import HTTPTypes
import Testing
import Unladen

/// Warning policy, cross-vendor fallback, provider options, keys, errors
/// and cancellation.
@Suite struct PolicyTests {
    static let anthropicThinking = AnthropicTests.thinkingReply
    static let anthropicOK = #"{"id":"m","type":"message","role":"assistant","model":"claude","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
    static let responsesOK = #"{"id":"resp","object":"response","created_at":1,"status":"completed","model":"gpt-5","output":[{"id":"msg","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","annotations":[],"text":"ok"}]}]}"#
    let weather = Tool(name: "get_weather", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

    // MARK: Warning policy

    @Test func strictPolicyRejectsBeforeSending() async throws {
        let provider = FakeProvider(.json(Self.anthropicOK))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")
        let settings = GenerationSettings(frequencyPenalty: 0.5) // Anthropic has none

        await #expect {
            _ = try await model.generate("Hi", settings: settings)
        } throws: { error in
            guard case UnladenError.unsupported(let warnings) = error else { return false }
            return warnings.map(\.code) == [.droppedField] && warnings[0].path == "frequency_penalty"
        }
        // The stream reports the same, from its first `next()`.
        await #expect(throws: UnladenError.self) {
            for try await _ in model.stream("Hi", settings: settings) {}
        }
        #expect(provider.requests.isEmpty)
    }

    @Test func lenientPolicyReportsWarnings() async throws {
        let provider = FakeProvider(.json(Self.anthropicOK), .sse(sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"c","content":[],"usage":{"input_tokens":1,"output_tokens":0}}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":0}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])))
        let model = try client(provider, policy: .lenient).model("anthropic/claude-sonnet-4-5")
        let settings = GenerationSettings(frequencyPenalty: 0.5)

        let response = try await model.generate("Hi", settings: settings)
        #expect(response.text == "ok")
        #expect(response.warnings.contains { $0.code == .droppedField && $0.path == "frequency_penalty" })
        #expect(provider.lastBody["frequency_penalty"] == nil)

        let all = try await parts(model.stream("Hi", settings: settings))
        guard case .warnings(let warnings)? = all.first else {
            Issue.record("request warnings come first")
            return
        }
        #expect(warnings.map(\.path) == ["frequency_penalty"])
    }

    @Test func cacheHintsAndAdjustmentsAreNeverErrors() async throws {
        let provider = FakeProvider(.json(Self.anthropicOK))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")

        // `prompt_cache_key` is OpenAI's; an effort becomes a thinking budget.
        let response = try await model.generate("Hi", settings: GenerationSettings(reasoning: .effort(.high), promptCacheKey: "user-42"))

        #expect(response.warnings.contains { $0.isCacheHint && $0.path == "prompt_cache_key" })
        #expect(response.warnings.contains { $0.code == .adjusted })
        #expect(provider.lastBody.at("thinking.budget_tokens") == 24000)
    }

    @Test func responseSideWarningsAreReportedNotThrown() async throws {
        // A field Unladen does not model, in the reply.
        let provider = FakeProvider(.json(#"{"id":"m","type":"message","role":"assistant","model":"c","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1},"brand_new_field":1}"#))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")

        let response = try await model.generate("Hi")
        #expect(response.text == "ok")
        #expect(response.warnings.contains { $0.code == .unknownField })
    }

    // MARK: Cross-vendor fallback

    @Test func anthropicHistoryFallsBackToOpenAI() async throws {
        let anthropic = FakeProvider(.json(Self.anthropicThinking))
        let openAI = FakeProvider(.json(Self.responsesOK))
        let primary = try client(anthropic).model("anthropic/claude-sonnet-4-5")
        let fallback = try client(openAI).model("openai/gpt-5")

        var history: [Message] = [.user("Weather in Paris?")]
        let first = try await primary.generate(history, tools: [weather])
        history.append(first.message)
        history.append(.tool(ToolResult(call: first.toolCalls[0], output: "18°C")))

        // Strict policy, yet no error: foreign replay data is expected to go.
        let second = try await fallback.generate(history, tools: [weather])
        #expect(second.text == "ok")
        #expect(second.warnings.contains { $0.code == .replayDataDropped && $0.path == "messages[1]" })

        let input = openAI.lastBody["input"]
        let types = input?.arrayValue?.compactMap { $0["type"]?.stringValue ?? $0["role"]?.stringValue }
        #expect(types == ["message", "message", "function_call", "function_call_output"])
        #expect(!openAI.lastBody.description.contains("sig-abc=="))
        #expect(openAI.lastBody.description.contains("Let me check."))
    }

    @Test func trustedSystemKeepsSignature() async throws {
        // DeepSeek's Anthropic endpoint trusts Claude's signatures.
        let anthropic = FakeProvider(.json(Self.anthropicThinking))
        let deepSeek = FakeProvider(.json(Self.anthropicOK))
        let first = try await client(anthropic).model("anthropic/claude-sonnet-4-5").generate([.user("Weather?")], tools: [weather])
        let model = try client(deepSeek).model("deepseek/deepseek-chat", preferring: .anthropicMessages)

        let response = try await model.generate([.user("Weather?"), first.message, .tool(ToolResult(call: first.toolCalls[0], output: "18°C"))], tools: [weather])

        #expect(!response.warnings.contains { $0.code == .replayDataDropped })
        #expect(deepSeek.lastBody.at("messages[1].content[0].signature") == "sig-abc==")
    }

    // MARK: Provider options

    @Test func providerOptionsReachTheBody() async throws {
        let provider = FakeProvider(.json(Self.anthropicOK))
        let model = try client(provider).model("deepseek/deepseek-chat", preferring: .anthropicMessages)
        let settings = GenerationSettings(
            temperature: 0.5,
            user: "u-1",
            providerOptions: [
                "anthropic": ["temperature": 0.9, "metadata": ["tier": "a"], "top_k": 5],
                "deepseek": ["metadata": ["tier": "b"], "top_k": nil],
                "openai": ["service_tier": "flex"],
            ],
        )

        _ = try await model.generate("Hi", settings: settings)

        let body = provider.lastBody
        #expect(body["temperature"] == 0.9) // options win over settings
        #expect(body["metadata"] == ["user_id": "u-1", "tier": "b"]) // deep merge; system over protocol
        #expect(body["top_k"] == nil) // `null` removes
        #expect(body["service_tier"] == nil) // other systems' options are ignored
    }

    // MARK: API keys

    @Test func apiKeysExplicitThenEnvironment() async throws {
        let provider = FakeProvider(.json(Self.anthropicOK), .json(Self.anthropicOK))
        let environment = ["ANTHROPIC_API_KEY": "from-env"]

        let fromEnv = ModelClient(transport: provider.transport, environment: environment)
        _ = try await fromEnv.model("anthropic/claude-sonnet-4-5").generate("Hi")
        let explicit = ModelClient(transport: provider.transport, apiKeys: ["anthropic": "explicit"], environment: environment)
        _ = try await explicit.model("anthropic/claude-sonnet-4-5").generate("Hi")

        let keys = provider.requests.map { $0.headerFields[HTTPField.Name("x-api-key")!] }
        #expect(keys == ["from-env", "explicit"])

        let none = ModelClient(transport: provider.transport, environment: [:])
        #expect {
            _ = try none.model("anthropic/claude-sonnet-4-5")
        } throws: { error in
            guard case UnladenError.missingAPIKey("anthropic", ["ANTHROPIC_API_KEY"]) = error else { return false }
            return true
        }
        // Local servers need none.
        _ = try none.model("ollama/llama3.2")
    }

    @Test func invalidModelReferences() {
        let client = ModelClient(transport: FakeProvider().transport, environment: [:])
        #expect(throws: UnladenError.self) { try client.model("no-slash") }
        #expect {
            _ = try client.model("nobody/model")
        } throws: { error in
            guard case UnladenError.invalidModelReference(_, .unknownProvider("nobody")) = error else { return false }
            return true
        }
    }

    // MARK: Errors

    @Test func rateLimitMapsToHTTPError() async throws {
        let body = #"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}"#
        let headers: HTTPFields = [.retryAfter: "7", HTTPField.Name("request-id")!: "req_123"]
        let provider = FakeProvider(
            FakeProvider.Reply(status: .tooManyRequests, headers: headers, body: body),
            FakeProvider.Reply(status: .tooManyRequests, headers: headers, body: body),
        )
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")

        for attempt in 0..<2 {
            do {
                if attempt == 0 {
                    _ = try await model.generate("Hi")
                } else {
                    for try await _ in model.stream("Hi") {}
                }
                Issue.record("expected an error")
            } catch UnladenError.http(let error) {
                #expect(error.statusCode == 429)
                #expect(error.retryAfter == "7")
                #expect(error.retryAfterSeconds == 7)
                #expect(error.requestID == "req_123")
                #expect(error.providerMessage == "Slow down")
                #expect(error.isRetryable)
                #expect(error.body == body)
            }
        }
    }

    @Test func streamErrorEvent() async throws {
        let provider = FakeProvider(.sse(sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"c","content":[],"usage":{"input_tokens":1,"output_tokens":0}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
            ("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
        ])))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")

        var received: [StreamPart] = []
        do {
            for try await part in model.stream("Hi") { received.append(part) }
            Issue.record("expected an error")
        } catch UnladenError.stream(let error) {
            #expect(error.message == "Overloaded")
            #expect(error.type == "overloaded_error")
        }
        #expect(received.text == "Hel")
    }

    // MARK: Cancellation

    @Test func cancellingTheTaskCancelsTheStream() async throws {
        let (chunks, upstream) = AsyncStream<ArraySlice<UInt8>>.makeStream()
        upstream.yield(Array(sse([
            ("message_start", #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"c","content":[],"usage":{"input_tokens":1,"output_tokens":0}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Once upon"}}"#),
        ]).utf8)[...])
        // …and then the upstream goes quiet, never finishing.
        let transport = MockTransport { _, _ in
            HTTPTransportResponse(response: HTTPResponse(status: .ok), body: HTTPResponseBody(chunks))
        }
        let model = try ModelClient(transport: transport, apiKeys: ["anthropic": "k"]).model("anthropic/claude-sonnet-4-5")

        let (firstDelta, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            for try await part in model.stream("Tell a long story") {
                if case .textDelta = part { signal.yield() }
            }
        }
        for await _ in firstDelta { break }
        task.cancel()

        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        upstream.finish()
    }
}
