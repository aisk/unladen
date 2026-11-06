import Testing
@_spi(Wire) import UnladenCore

private let responseFixtures = (try? Fixtures.names("Chat/responses", extension: "json")) ?? []
private let streamFixtures = (try? Fixtures.names("Chat/streams", extension: "sse")) ?? []

@Suite struct ChatResponseTests {
    @Test(arguments: responseFixtures)
    func sameProtocolRoundTrip(_ name: String) throws {
        let original = try Fixtures.json("Chat/responses/\(name)")
        let decoded = try ChatCompletionsCodec.parseResponse(Fixtures.bytes("Chat/responses/\(name)"))
        let encoded = ChatCompletionsCodec.encodeResponse(decoded.value, defaults: testDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == original.canonical)
        #expect(encoded.body == ChatCompletionsCodec.encodeResponse(decoded.value, defaults: testDefaults).body)
    }

    @Test func reasoningAndUsage() throws {
        let response = try ChatCompletionsCodec.parseResponse(Fixtures.bytes("Chat/responses/deepseek_reasoning.json")).value
        #expect(response.message.parts == [
            .reasoning(WireReasoning(text: "2 plus 2 equals 4.", sourceKey: "reasoning_content")),
            .text(WireText("The answer is 4.")),
        ])
        #expect(response.finishReason == WireFinishReason(.stop, raw: "stop"))
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 12)
        #expect(usage.outputTokens == 30)
        #expect(usage.cachedInputTokens == 0)
        #expect(usage.reasoningTokens == 22)
        #expect(usage.extra == ["prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 12])
        #expect(response.extra == ["system_fingerprint": "fp_5417b77867_prod0225"])
    }

    @Test func toolCallsResponse() throws {
        let response = try ChatCompletionsCodec.parseResponse(Fixtures.bytes("Chat/responses/tool_calls.json")).value
        #expect(response.finishReason?.unified == .toolCalls)
        #expect(response.message.contentForm == .null)
        #expect(response.message.parts.count == 2)
    }

    @Test func crossProtocolResponseUsesChatSpellings() {
        var response = WireResponse(
            message: WireMessage(role: .assistant, parts: [
                .reasoning(WireReasoning(text: "think", signature: "s", origin: "anthropic")),
                .text(WireText("Hi")),
                .text(WireText(" there")),
            ]),
            id: "msg_1", model: "claude", finishReason: WireFinishReason(.length, raw: "max_tokens"),
            usage: WireUsage(inputTokens: 10, outputTokens: 5, cachedInputTokens: 4),
            source: .anthropicMessages,
        )
        response.extra = ["stop_sequence": nil, "container": ["id": "c"]]
        let encoded = ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults)
        let expected: JSONValue = [
            "id": "msg_1", "object": "chat.completion", "created": 1_700_000_000, "model": "claude",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": "Hi there", "reasoning_content": "think"],
                "finish_reason": "length",
            ]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15, "prompt_tokens_details": ["cached_tokens": 4]],
        ]
        #expect(encoded.json == expected)
        #expect(encoded.warnings.map(\.code) == [.lossyConversion, .droppedContent, .droppedField])
    }

    @Test func errors() {
        #expect(throws: WireDecodingError(.missingField, path: "choices")) {
            try ChatCompletionsCodec.parseResponse(Array(#"{"id":"x"}"#.utf8))
        }
        #expect(throws: WireDecodingError(.missingField, path: "choices[0].message")) {
            try ChatCompletionsCodec.parseResponse(Array(#"{"choices":[{"index":0}]}"#.utf8))
        }
    }
}

@Suite struct ChatStreamTests {
    @Test func textStreamWithUsage() throws {
        let (events, warnings) = try decodeChatStream(Fixtures.sse("Chat/streams/text_usage.sse"))
        #expect(warnings.isEmpty, "\(warnings)")
        let expected: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(
                id: "chatcmpl-1", model: "gpt-4.1-2025-04-14", created: 1_741_569_952,
                extra: ["service_tier": "default", "system_fingerprint": "fp_1"], source: .chatCompletions,
            )),
            .textStart(id: "text-0"),
            .textDelta(id: "text-0", delta: "Hello"),
            .textDelta(id: "text-0", delta: " world"),
            .textEnd(id: "text-0"),
            .finish(WireFinish(
                reason: WireFinishReason(.stop, raw: "stop"),
                usage: WireUsage(
                    inputTokens: 9, outputTokens: 2, totalTokens: 11, cachedInputTokens: 0, reasoningTokens: 0,
                    inputDetailsExtra: ["audio_tokens": 0],
                    outputDetailsExtra: ["audio_tokens": 0, "accepted_prediction_tokens": 0, "rejected_prediction_tokens": 0],
                ),
            )),
        ]
        #expect(events == expected)
    }

    @Test func reasoningContentStream() throws {
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/reasoning_content.sse"))
        let content = events.filter {
            if case .responseMetadata = $0 { return false }
            if case .finish = $0 { return false }
            return true
        }
        #expect(content == [
            .reasoningStart(id: "reasoning-0", reasoning: WireReasoning(text: "", sourceKey: "reasoning_content")),
            .reasoningDelta(id: "reasoning-0", delta: "Let me"),
            .reasoningDelta(id: "reasoning-0", delta: " think."),
            .ping,
            .reasoningEnd(id: "reasoning-0", reasoning: nil),
            .textStart(id: "text-1"),
            .textDelta(id: "text-1", delta: "4"),
            .textEnd(id: "text-1"),
        ])
        guard case .finish(let finish)? = events.last else {
            Issue.record("expected finish")
            return
        }
        #expect(finish.usage?.reasoningTokens == 22)
        #expect(finish.usage?.extra == ["prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 12])
    }

    @Test func interleavedParallelToolCalls() throws {
        let (events, warnings) = try decodeChatStream(Fixtures.sse("Chat/streams/parallel_tools.sse"))
        #expect(warnings.map(\.message) == ["stream choice field `native_finish_reason` is not carried"])
        let tokyo = WireToolCall(id: "call_T", name: "get_weather", arguments: "")
        let osaka = WireToolCall(id: "call_O", name: "get_weather", arguments: "")
        var tokyoDone = tokyo
        tokyoDone.arguments = #"{"city":"Tokyo"}"#
        var osakaDone = osaka
        osakaDone.arguments = #"{"city":"Osaka"}"#
        let expected: [WireEvent] = [
            .ping,
            .responseMetadata(WireResponseMetadata(
                id: "gen-1", model: "openai/gpt-4o", created: 1_741_570_200, extra: ["provider": "OpenAI"], source: .chatCompletions,
            )),
            .reasoningStart(id: "reasoning-0", reasoning: WireReasoning(text: "", sourceKey: "reasoning")),
            .reasoningDelta(id: "reasoning-0", delta: "Two cities"),
            .reasoningDelta(id: "reasoning-0", delta: ", two calls."),
            .reasoningEnd(id: "reasoning-0", reasoning: nil),
            .toolInputStart(id: "tool-1", call: tokyo),
            .toolInputStart(id: "tool-2", call: osaka),
            .toolInputDelta(id: "tool-1", delta: #"{"city":"#),
            .toolInputDelta(id: "tool-2", delta: #"{"city":"#),
            .ping,
            .toolInputDelta(id: "tool-1", delta: #""Tokyo"}"#),
            .toolInputDelta(id: "tool-2", delta: #""Osaka"}"#),
            .toolInputEnd(id: "tool-1"),
            .toolCall(id: "tool-1", call: tokyoDone),
            .toolInputEnd(id: "tool-2"),
            .toolCall(id: "tool-2", call: osakaDone),
            .finish(WireFinish(
                reason: WireFinishReason(.toolCalls, raw: "tool_calls"),
                usage: WireUsage(
                    inputTokens: 80, outputTokens: 40, totalTokens: 120, cachedInputTokens: 64, reasoningTokens: 8,
                    extra: ["cost": 0.00042], inputDetailsExtra: [:], outputDetailsExtra: [:],
                ),
            )),
        ]
        #expect(events == expected)
    }

    @Test func refusalThenErrorWithoutDone() throws {
        let (events, warnings) = try decodeChatStream(Fixtures.sse("Chat/streams/refusal_error.sse"))
        #expect(Array(events.dropFirst()) == [
            .refusalStart(id: "refusal-0"),
            .refusalDelta(id: "refusal-0", delta: "I can't"),
            .refusalDelta(id: "refusal-0", delta: " help with that."),
            .refusalEnd(id: "refusal-0"),
            .error(WireStreamError(
                message: "Upstream overloaded", type: "server_error", code: "529",
                raw: ["message": "Upstream overloaded", "type": "server_error", "code": 529],
            )),
            .finish(WireFinish(reason: WireFinishReason(.error))),
        ])
        #expect(warnings.map(\.code) == [.malformedStream])
    }

    @Test(arguments: streamFixtures)
    func decodedStreamsAreWellFormed(_ name: String) throws {
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/\(name)"))
        #expect(checkEventSequence(events) == [])
    }

    @Test(arguments: streamFixtures)
    func decodeEncodeDecodeIsStable(_ name: String) throws {
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/\(name)"))
        let (elements, encodeWarnings) = encodeChatStream(events)
        #expect(encodeWarnings.isEmpty, "\(encodeWarnings)")
        #expect(checkChatStream(elements) == [])
        let (again, _) = try decodeChatStream(elements)
        #expect(again == events)
        // Deterministic bytes.
        let bytes = elements.flatMap { SSEWriter.encode($0) }
        #expect(encodeChatStream(events).elements.flatMap { SSEWriter.encode($0) } == bytes)
    }

    @Test func encoderAssignsContiguousIndicesAndDone() throws {
        let call = WireToolCall(id: nil, name: "f", arguments: "")
        let events: [WireEvent] = [
            .toolInputStart(id: "a", call: call),
            .toolInputStart(id: "b", call: call),
            .toolInputDelta(id: "b", delta: "{}"),
            .toolInputDelta(id: "a", delta: "{\"x\":1}"),
            .toolInputEnd(id: "a"),
            .toolInputEnd(id: "b"),
            .toolCall(id: "c", call: WireToolCall(id: "whole", name: "g", arguments: "{}")),
            .ping,
            .finish(WireFinish(reason: WireFinishReason(.toolCalls))),
        ]
        let (elements, _) = encodeChatStream(events, includeUsage: false)
        #expect(checkChatStream(elements) == [])
        let text = String(decoding: elements.flatMap { SSEWriter.encode($0) }, as: UTF8.self)
        let header = #"{"id":"chatcmpl-default","object":"chat.completion.chunk","created":1700000000,"model":"default-model","choices":[{"index":0,"delta":"#
        let expected = [
            #"data: \#(header){"role":"assistant","content":""},"finish_reason":null}]}"#, "",
            #"data: \#(header){"tool_calls":[{"index":0,"id":"call_0","type":"function","function":{"name":"f","arguments":""}}]},"finish_reason":null}]}"#, "",
            #"data: \#(header){"tool_calls":[{"index":1,"id":"call_1","type":"function","function":{"name":"f","arguments":""}}]},"finish_reason":null}]}"#, "",
            #"data: \#(header){"tool_calls":[{"index":1,"function":{"arguments":"{}"}}]},"finish_reason":null}]}"#, "",
            #"data: \#(header){"tool_calls":[{"index":0,"function":{"arguments":"{\"x\":1}"}}]},"finish_reason":null}]}"#, "",
            #"data: \#(header){"tool_calls":[{"index":2,"id":"whole","type":"function","function":{"name":"g","arguments":"{}"}}]},"finish_reason":null}]}"#, "",
            ": ping",
            #"data: \#(header){},"finish_reason":"tool_calls"}]}"#, "",
            "data: [DONE]", "", "",
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    @Test func toolCallWithoutNameIsHeldUntilNamed() throws {
        let chunks = [
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"arguments":"{\"a\""}}]}}]}"#,
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"f","arguments":":1}"}}]}}]}"#,
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c2","function":{"name":"g","arguments":"{}"}}]}}]}"#,
            #"{"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ]
        let (events, _) = try decodeChatStream(chunks.map { .event(SSEEvent(data: $0)) } + [.event(SSEEvent(data: "[DONE]"))])
        #expect(checkEventSequence(events) == [])
        let calls = events.compactMap { event -> WireToolCall? in
            if case .toolCall(_, let call) = event { return call }
            return nil
        }
        #expect(calls == [
            WireToolCall(id: "c1", name: "f", arguments: #"{"a":1}"#),
            WireToolCall(id: "c2", name: "g", arguments: "{}"),
        ])
    }

    @Test func invalidJSONInStreamThrows() {
        var decoder = ChatCompletionsStreamDecoder()
        #expect(throws: WireDecodingError.self) {
            try decoder.decode(SSEElement.event(SSEEvent(data: "{not json")))
        }
    }

    @Test func asyncAdapterMatchesSyncDecoder() async throws {
        let elements = try Fixtures.sse("Chat/streams/parallel_tools.sse")
        let stream = AsyncStream<SSEElement> { continuation in
            for element in elements { continuation.yield(element) }
            continuation.finish()
        }
        var events: [WireEvent] = []
        for try await event in stream.wireEvents(ChatCompletionsStreamDecoder()) {
            events.append(event)
        }
        #expect(events == (try decodeChatStream(elements)).events)
    }
}
