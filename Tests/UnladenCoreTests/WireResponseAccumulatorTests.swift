import Testing
@_spi(Wire) import UnladenCore

/// What a stream cannot say (see ``WireResponseAccumulator``): the content
/// form, message-level keys, `null` bag entries, and argument whitespace.
private func normalized(_ response: WireResponse) -> WireResponse {
    var response = response
    response.message.contentForm = nil
    response.message.extra = [:]
    response.choiceExtra = JSONObject(response.choiceExtra.filter { !$0.value.isNull }.map { ($0.key, $0.value) })
    response.message.parts = response.message.parts.map { part in
        guard case .toolCall(var call) = part, let json = try? JSONValue(parsing: call.arguments) else { return part }
        call.arguments = json.description
        return .toolCall(call)
    }
    return response
}

@Suite struct WireResponseAccumulatorTests {
    @Test(arguments: [
        ("thinking.sse", "thinking_text.json"),
        ("web_search.sse", "web_search.json"),
    ])
    func anthropicStreamAccumulatesToTheReply(_ stream: String, _ body: String) throws {
        let (events, _) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/\(stream)"))
        var accumulator = WireResponseAccumulator()
        for event in events { accumulator.add(event) }
        #expect(accumulator.isFinished)
        #expect(accumulator.warnings.isEmpty)
        let reply = try AnthropicMessagesCodec.parseResponse(Fixtures.bytes("Anthropic/responses/\(body)")).value
        #expect(accumulator.response == reply, "Anthropic streams carry everything a reply has")
        // And so the client gets the same JSON either way.
        let viaStream = AnthropicMessagesCodec.encodeResponse(accumulator.response, defaults: anthropicDefaults)
        #expect(viaStream.json == AnthropicMessagesCodec.encodeResponse(reply, defaults: anthropicDefaults).json)
    }

    @Test func anthropicToolStreamMatchesModuloWhitespace() throws {
        let (events, _) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/parallel_tools.sse"))
        let accumulated = WireResponseAccumulator(events).response
        let reply = try AnthropicMessagesCodec.parseResponse(Fixtures.bytes("Anthropic/responses/tool_use.json")).value
        // The stream has one more (argument-less) call than the reply.
        var trimmed = accumulated
        #expect(trimmed.message.parts.popLast() == .toolCall(WireToolCall(id: "toolu_N", name: "list_issues", arguments: "{}")))
        #expect(normalized(trimmed) == normalized(reply))
    }

    @Test func chatStreamAccumulatesToTheReply() throws {
        let body = #"""
        {"id":"chatcmpl-1","object":"chat.completion","created":1741569952,"model":"gpt-4.1-2025-04-14","service_tier":"default","system_fingerprint":"fp_1","choices":[{"index":0,"message":{"role":"assistant","content":"Hello world","refusal":null},"logprobs":null,"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":2,"total_tokens":11,"prompt_tokens_details":{"cached_tokens":0,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0,"audio_tokens":0,"accepted_prediction_tokens":0,"rejected_prediction_tokens":0}}}
        """#
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/text_usage.sse"))
        let accumulated = WireResponseAccumulator(events).response
        let reply = try ChatCompletionsCodec.parseResponse(Array(body.utf8)).value
        #expect(normalized(accumulated) == normalized(reply))
    }

    @Test func chatToolStreamAccumulatesToTheReply() throws {
        let body = #"""
        {"id":"gen-1","provider":"OpenAI","model":"openai/gpt-4o","object":"chat.completion","created":1741570200,"choices":[{"index":0,"message":{"role":"assistant","content":null,"reasoning":"Two cities, two calls.","tool_calls":[{"id":"call_T","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Tokyo\"}"}},{"id":"call_O","type":"function","function":{"name":"get_weather","arguments":"{\"city\": \"Osaka\"}"}}]},"finish_reason":"tool_calls","native_finish_reason":"tool_calls","logprobs":null}],"usage":{"prompt_tokens":80,"completion_tokens":40,"total_tokens":120,"cost":0.00042,"prompt_tokens_details":{"cached_tokens":64},"completion_tokens_details":{"reasoning_tokens":8}}}
        """#
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/parallel_tools.sse"))
        let accumulated = WireResponseAccumulator(events).response
        let reply = try ChatCompletionsCodec.parseResponse(Array(body.utf8)).value
        #expect(normalized(accumulated) == normalized(reply))
        #expect(accumulated.choiceExtra == ["native_finish_reason": "tool_calls"])
    }

    @Test func errorsAndLateMetadata() {
        let events: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(id: "x", usage: WireUsage(inputTokens: 5), source: .gemini)),
            .textStart(id: "t", text: WireText("", extra: ["a": 1])),
            .textDelta(id: "t", delta: "Hi"),
            .textEnd(id: "t", text: WireText("", signature: "gsig", origin: "google", extra: ["b": 2])),
            .reasoningStart(id: "r", reasoning: WireReasoning(text: "", itemID: "rs_1", summaryIndex: 0, origin: "openai")),
            .reasoningDelta(id: "r", delta: "Sum"),
            .reasoningEnd(id: "r", reasoning: WireReasoning(text: "", encrypted: "enc")),
            .toolCall(id: "c", call: WireToolCall(id: "whole", name: "f", arguments: "{}")),
            .opaque(WireOpaque(protocol: .gemini, value: ["executableCode": [:]])),
            .textDelta(id: "nope", delta: "lost"),
            .error(WireStreamError(message: "boom")),
            .finish(WireFinish(reason: WireFinishReason(.error))),
            .ping,
        ]
        let accumulator = WireResponseAccumulator(events)
        let response = accumulator.response
        #expect(response.source == .gemini)
        #expect(response.usage == WireUsage(inputTokens: 5), "early usage stands without a final one")
        #expect(response.message.parts == [
            .text(WireText("Hi", signature: "gsig", origin: "google", extra: ["a": 1, "b": 2])),
            .reasoning(WireReasoning(text: "Sum", encrypted: "enc", itemID: "rs_1", summaryIndex: 0, origin: "openai")),
            .toolCall(WireToolCall(id: "whole", name: "f", arguments: "{}")),
            .opaque(WireOpaque(protocol: .gemini, value: ["executableCode": [:]])),
        ])
        #expect(accumulator.errors == [WireStreamError(message: "boom")])
        #expect(response.finishReason?.unified == .error)
        #expect(accumulator.warnings.count == 2, "orphan delta and event after finish")
    }
}
