import HTTPTypes
import Testing
import Unladen

/// Anthropic Messages upstream: generate, stream, and replay of signed thinking.
@Suite struct AnthropicTests {
    static let thinkingReply = """
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-5-20250929",
     "content":[
       {"type":"thinking","thinking":"The user wants Paris weather.","signature":"sig-abc=="},
       {"type":"text","text":"Let me check."},
       {"type":"tool_use","id":"toolu_1","name":"get_weather","input":{"city":"Paris"}}
     ],
     "stop_reason":"tool_use","stop_sequence":null,
     "usage":{"input_tokens":20,"output_tokens":30}}
    """

    let weather = Tool(
        name: "get_weather",
        description: "Current weather for a city",
        inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
    )

    @Test func generateText() async throws {
        let provider = FakeProvider(.json("""
        {"id":"msg_0","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Bonjour!"}],
         "stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":2}}
        """))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")

        let response = try await model.generate(
            [.system("Answer in French."), .user("Hello")],
            settings: GenerationSettings(maxOutputTokens: 100, temperature: 0.5),
        )

        #expect(response.text == "Bonjour!")
        #expect(response.finishReason == FinishReason(.stop, raw: "end_turn"))
        #expect(response.usage.inputTokens == 5)
        #expect(response.metadata.id == "msg_0")
        #expect(response.message.role == .assistant)

        let request = try #require(provider.requests.first)
        #expect(request.path == "/v1/messages")
        #expect(request.headerFields[HTTPField.Name("x-api-key")!] == "sk-ant")
        let body = provider.lastBody
        #expect(body["system"] == "Answer in French.")
        #expect(body["max_tokens"] == 100)
        #expect(body["temperature"] == 0.5)
        #expect(body.at("messages[0].content") == "Hello")
    }

    @Test func toolCallWithSignedThinking() async throws {
        let provider = FakeProvider(.json(Self.thinkingReply))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")

        let response = try await model.generate(
            [.user("Weather in Paris?")],
            tools: [weather],
            settings: GenerationSettings(reasoning: .budget(2048)),
        )

        #expect(response.reasoningText == "The user wants Paris weather.")
        #expect(response.text == "Let me check.")
        #expect(response.finishReason.kind == .toolCalls)
        let call = try #require(response.toolCalls.first)
        #expect(call.id == "toolu_1")
        #expect(call.name == "get_weather")
        #expect(try call.parsedArguments() == ["city": "Paris"])

        // The reasoning part carries Anthropic's signature, opaquely.
        guard case .reasoning(_, let token?) = response.message.content.first else {
            Issue.record("expected signed reasoning first")
            return
        }
        #expect(token.system == "anthropic")
        #expect(token.hasSignedData)

        let body = provider.lastBody
        #expect(body.at("thinking.budget_tokens") == 2048)
        #expect(body.at("tools[0].name") == "get_weather")
        #expect(body.at("tools[0].input_schema.required[0]") == "city")
    }

    @Test func multiTurnReplaysSignature() async throws {
        let provider = FakeProvider(
            .json(Self.thinkingReply),
            .json("""
            {"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"18°C in Paris."}],
             "stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":60,"output_tokens":8}}
            """),
        )
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")
        let settings = GenerationSettings(reasoning: .budget(2048))

        var history: [Message] = [.user("Weather in Paris?")]
        let first = try await model.generate(history, tools: [weather], settings: settings)
        history.append(first.message)
        for call in first.toolCalls {
            history.append(.tool(ToolResult(call: call, json: ["temperature": 18])))
        }
        let second = try await model.generate(history, tools: [weather], settings: settings)
        #expect(second.text == "18°C in Paris.")

        // The assistant turn goes back with its signed thinking block intact.
        let body = provider.lastBody
        #expect(body.at("messages[1].role") == "assistant")
        #expect(body.at("messages[1].content[0]") == [
            "type": "thinking", "thinking": "The user wants Paris weather.", "signature": "sig-abc==",
        ])
        #expect(body.at("messages[1].content[2].type") == "tool_use")
        #expect(body.at("messages[1].content[2].id") == "toolu_1")
        #expect(body.at("messages[2].content[0].type") == "tool_result")
        #expect(body.at("messages[2].content[0].tool_use_id") == "toolu_1")
        #expect(body.at("messages[2].content[0].content") == #"{"temperature":18}"#)
    }

    @Test func streamThinkingTextAndParallelTools() async throws {
        let provider = FakeProvider(.sse(sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_s","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"stop_reason":null,"usage":{"input_tokens":12,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Two cities."}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-stream=="}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"both."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_a","name":"get_weather","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"Paris\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("content_block_start", #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_b","name":"get_weather","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Rome\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":3}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":40}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")

        let all = try await parts(model.stream([.user("Weather in Paris and Rome?")], tools: [weather]))

        #expect(all.first == .metadata(ResponseMetadata(id: "msg_s", model: "claude-sonnet-4-5")))
        #expect(all.text == "Checking both.")
        #expect(all.toolCalls.map(\.id) == ["toolu_a", "toolu_b"])
        #expect(all.toolCalls.map(\.arguments) == [#"{"city":"Paris"}"#, #"{"city":"Rome"}"#])
        #expect(all.finish?.kind == .toolCalls)
        let reasoningEnds = all.compactMap { if case .reasoningEnd(_, let token) = $0 { token } else { nil } }
        #expect(reasoningEnds.count == 1 && reasoningEnds[0].hasSignedData)
        #expect(provider.lastBody["stream"] == true)

        // The same parts, accumulated, give the message for the history,
        // with the streamed signature folded into the token.
        var accumulator = ResponseAccumulator()
        for part in all { accumulator.add(part) }
        let response = accumulator.response
        #expect(response.reasoningText == "Two cities.")
        #expect(response.toolCalls.count == 2)
        #expect(response.usage.outputTokens == 40)

        let provider2 = FakeProvider(.json(#"{"id":"m","type":"message","role":"assistant","model":"c","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#))
        let replay = try client(provider2).model("anthropic/claude-sonnet-4-5")
        _ = try await replay.generate([.user("Weather in Paris and Rome?"), response.message], tools: [weather])
        #expect(provider2.lastBody.at("messages[1].content[0].signature") == "sig-stream==")
    }
}
