import Testing
import Unladen

/// OpenAI Responses upstream: encrypted reasoning and item ids survive a
/// round trip through the history.
@Suite struct ResponsesTests {
    static let reasoningReply = """
    {"id":"resp_1","object":"response","created_at":1741290958,"status":"completed","model":"gpt-5-2025-08-07",
     "output":[
       {"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"Need the weather tool."}],
        "encrypted_content":"gAAAA-encrypted=="},
       {"id":"msg_1","type":"message","status":"completed","role":"assistant",
        "content":[{"type":"output_text","annotations":[],"text":"Checking."}]},
       {"id":"fc_1","type":"function_call","status":"completed","call_id":"call_1","name":"get_weather",
        "arguments":"{\\"city\\":\\"Paris\\"}"}
     ],
     "usage":{"input_tokens":30,"input_tokens_details":{"cached_tokens":16},"output_tokens":120,
              "output_tokens_details":{"reasoning_tokens":96},"total_tokens":150}}
    """

    let weather = Tool(name: "get_weather", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

    @Test func generateText() async throws {
        let provider = FakeProvider(.json("""
        {"id":"resp_0","object":"response","created_at":1,"status":"completed","model":"gpt-4.1",
         "output":[{"id":"msg_0","type":"message","status":"completed","role":"assistant",
                    "content":[{"type":"output_text","annotations":[],"text":"Hi there."}]}],
         "usage":{"input_tokens":3,"output_tokens":3,"total_tokens":6}}
        """))
        let model = try client(provider).model("openai/gpt-4.1")

        let response = try await model.generate("Hello", settings: GenerationSettings(maxOutputTokens: 50, temperature: 0.2))

        #expect(response.text == "Hi there.")
        #expect(response.finishReason.kind == .stop)
        #expect(response.metadata == ResponseMetadata(id: "resp_0", model: "gpt-4.1", created: 1))
        #expect(provider.requests.first?.path == "/v1/responses")
        #expect(provider.lastBody["max_output_tokens"] == 50)
        #expect(provider.lastBody["temperature"] == 0.2)
    }

    @Test func toolCallWithEncryptedReasoning() async throws {
        let provider = FakeProvider(.json(Self.reasoningReply))
        let model = try client(provider).model("openai/gpt-5")

        let response = try await model.generate(
            [.user("Weather in Paris?")], tools: [weather], toolChoice: .auto,
            settings: GenerationSettings(reasoning: ReasoningSettings(effort: .medium, visibility: .summary())),
        )

        #expect(response.reasoningText == "Need the weather tool.")
        #expect(response.toolCalls.map(\.id) == ["call_1"])
        #expect(response.usage.reasoningTokens == 96)
        #expect(response.usage.cachedInputTokens == 16)

        let body = provider.lastBody
        #expect(body.at("reasoning.effort") == "medium")
        #expect(body.at("reasoning.summary") == "auto")
        #expect(body["tool_choice"] == "auto")
        #expect(body.at("tools[0].name") == "get_weather")
    }

    @Test func multiTurnReplaysEncryptedReasoning() async throws {
        let provider = FakeProvider(
            .json(Self.reasoningReply),
            .json("""
            {"id":"resp_2","object":"response","created_at":2,"status":"completed","model":"gpt-5",
             "output":[{"id":"msg_2","type":"message","status":"completed","role":"assistant",
                        "content":[{"type":"output_text","annotations":[],"text":"18°C."}]}]}
            """),
        )
        let model = try client(provider).model("openai/gpt-5")
        // Ask for encrypted reasoning, through the escape hatch.
        let settings = GenerationSettings(providerOptions: ["responses": ["include": ["reasoning.encrypted_content"], "store": false]])

        var history: [Message] = [.user("Weather in Paris?")]
        let first = try await model.generate(history, tools: [weather], settings: settings)
        history.append(first.message)
        history.append(.tool(ToolResult(call: first.toolCalls[0], output: "18°C")))
        _ = try await model.generate(history, tools: [weather], settings: settings)

        let input = provider.lastBody["input"]
        #expect(input?.at("[1].type") == "reasoning")
        #expect(input?.at("[1].id") == "rs_1")
        #expect(input?.at("[1].encrypted_content") == "gAAAA-encrypted==")
        #expect(input?.at("[1].summary[0].text") == "Need the weather tool.")
        #expect(input?.at("[2].type") == "message")
        #expect(input?.at("[3].type") == "function_call")
        #expect(input?.at("[3].call_id") == "call_1")
        #expect(input?.at("[4].type") == "function_call_output")
        #expect(input?.at("[4].call_id") == "call_1")
        #expect(input?.at("[4].output") == "18°C")
        #expect(provider.lastBody["include"] == ["reasoning.encrypted_content"])
        #expect(provider.lastBody["store"] == false)
    }

    @Test func streamParallelToolCalls() async throws {
        let provider = FakeProvider(.sse(sse([
            ("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_s","object":"response","created_at":5,"status":"in_progress","model":"gpt-5","output":[]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"fc_a","type":"function_call","status":"in_progress","call_id":"call_a","name":"get_weather","arguments":""}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","sequence_number":2,"item_id":"fc_a","output_index":0,"delta":"{\"city\":\"Paris\"}"}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":3,"output_index":1,"item":{"id":"fc_b","type":"function_call","status":"in_progress","call_id":"call_b","name":"get_weather","arguments":""}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","sequence_number":4,"item_id":"fc_b","output_index":1,"delta":"{\"city\":\"Rome\"}"}"#),
            ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","sequence_number":5,"item_id":"fc_a","output_index":0,"arguments":"{\"city\":\"Paris\"}"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":6,"output_index":0,"item":{"id":"fc_a","type":"function_call","status":"completed","call_id":"call_a","name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}"#),
            ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","sequence_number":7,"item_id":"fc_b","output_index":1,"arguments":"{\"city\":\"Rome\"}"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","sequence_number":8,"output_index":1,"item":{"id":"fc_b","type":"function_call","status":"completed","call_id":"call_b","name":"get_weather","arguments":"{\"city\":\"Rome\"}"}}"#),
            ("response.completed", #"{"type":"response.completed","sequence_number":9,"response":{"id":"resp_s","object":"response","created_at":5,"status":"completed","model":"gpt-5","output":[{"id":"fc_a","type":"function_call","status":"completed","call_id":"call_a","name":"get_weather","arguments":"{\"city\":\"Paris\"}"},{"id":"fc_b","type":"function_call","status":"completed","call_id":"call_b","name":"get_weather","arguments":"{\"city\":\"Rome\"}"}],"usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30}}}"#),
        ])))
        let model = try client(provider).model("openai/gpt-5")

        let response = try await model.stream([.user("Paris and Rome?")], tools: [weather], settings: GenerationSettings(parallelToolCalls: true)).collect()

        #expect(response.toolCalls.map(\.id) == ["call_a", "call_b"])
        #expect(response.toolCalls.map(\.arguments) == [#"{"city":"Paris"}"#, #"{"city":"Rome"}"#])
        #expect(response.finishReason.kind == .toolCalls)
        #expect(response.usage.totalTokens == 30)
        #expect(provider.lastBody["parallel_tool_calls"] == true)
    }
}
