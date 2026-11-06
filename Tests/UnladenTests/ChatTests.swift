import Testing
import Unladen

/// OpenAI Chat Completions upstream (DeepSeek): plain reasoning text, which
/// DeepSeek wants back as `reasoning_content` on tool turns.
@Suite struct ChatTests {
    let weather = Tool(name: "get_weather", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

    static let toolReply = """
    {"id":"chatcmpl-1","object":"chat.completion","created":1700000000,"model":"deepseek-reasoner",
     "choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
       "reasoning_content":"I should call the tool.",
       "tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\\"city\\":\\"Paris\\"}"}}]}}],
     "usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}
    """

    @Test func generateText() async throws {
        let provider = FakeProvider(.json("""
        {"id":"chatcmpl-0","object":"chat.completion","created":1,"model":"deepseek-chat",
         "choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Hello!"}}],
         "usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
        """))
        let model = try client(provider).model("deepseek/deepseek-chat")

        let response = try await model.generate(
            [.system("Be brief."), .user("Hi")],
            settings: GenerationSettings(maxOutputTokens: 64, stopSequences: ["END"], seed: 7),
        )

        #expect(response.text == "Hello!")
        #expect(response.usage == Usage(inputTokens: 3, outputTokens: 2, totalTokens: 5))
        #expect(provider.requests.first?.path == "/v1/chat/completions")
        let body = provider.lastBody
        #expect(body.at("messages[0]") == ["role": "system", "content": "Be brief."])
        #expect(body["max_tokens"] == 64)
        #expect(body["stop"] == ["END"])
        #expect(body["seed"] == 7)
    }

    @Test func toolCallAndReasoningReplay() async throws {
        let provider = FakeProvider(
            .json(Self.toolReply),
            .json(#"{"id":"chatcmpl-2","object":"chat.completion","created":2,"model":"deepseek-reasoner","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"18°C."}}]}"#),
        )
        let model = try client(provider).model("deepseek/deepseek-reasoner")

        var history: [Message] = [.user("Weather in Paris?")]
        let first = try await model.generate(history, tools: [weather])
        #expect(first.reasoningText == "I should call the tool.")
        #expect(first.toolCalls.first?.name == "get_weather")

        history.append(first.message)
        history.append(.tool(ToolResult(call: first.toolCalls[0], output: "18°C")))
        let second = try await model.generate(history, tools: [weather])
        #expect(second.text == "18°C.")

        let body = provider.lastBody
        #expect(body.at("messages[1].reasoning_content") == "I should call the tool.")
        #expect(body.at("messages[1].tool_calls[0].id") == "call_1")
        #expect(body.at("messages[2]") == ["role": "tool", "content": "18°C", "tool_call_id": "call_1"])
    }

    @Test func streamInterleavedParallelToolCalls() async throws {
        let chunk = { (delta: String, finish: String) in
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"deepseek-chat","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
        }
        let provider = FakeProvider(.sse(sse([
            chunk(#"{"role":"assistant","content":"On it."}"#, "null"),
            chunk(#"{"tool_calls":[{"index":0,"id":"call_p","type":"function","function":{"name":"get_weather","arguments":""}}]}"#, "null"),
            chunk(#"{"tool_calls":[{"index":1,"id":"call_r","type":"function","function":{"name":"get_weather","arguments":""}}]}"#, "null"),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}"#, "null"),
            chunk(#"{"tool_calls":[{"index":1,"function":{"arguments":"{\"city\":\"Rome\"}"}}]}"#, "null"),
            chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}"#, "null"),
            chunk("{}", #""tool_calls""#),
            "[DONE]",
        ])))
        let model = try client(provider).model("deepseek/deepseek-chat")

        let all = try await parts(model.stream([.user("Paris and Rome?")], tools: [weather]))

        #expect(all.text == "On it.")
        // Both inputs were open at once; each block keeps its own deltas.
        let starts = all.compactMap { if case .toolInputStart(let id, let callID, _) = $0 { (id, callID) } else { nil } }
        #expect(starts.map(\.1) == ["call_p", "call_r"])
        #expect(Set(all.toolCalls.map(\.arguments)) == [#"{"city":"Paris"}"#, #"{"city":"Rome"}"#])
        #expect(all.finish == FinishReason(.toolCalls, raw: "tool_calls"))
        #expect(provider.lastBody["stream"] == true)
    }
}
