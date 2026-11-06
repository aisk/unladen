import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

private let responseFixtures = (try? Fixtures.names("Anthropic/responses", extension: "json")) ?? []
private let streamFixtures = (try? Fixtures.names("Anthropic/streams", extension: "sse")) ?? []

@Suite struct AnthropicResponseTests {
    @Test func fixturesExist() {
        #expect(responseFixtures.count >= 3)
        #expect(streamFixtures.count >= 5)
    }

    @Test(arguments: responseFixtures)
    func sameProtocolRoundTrip(_ name: String) throws {
        let original = try Fixtures.json("Anthropic/responses/\(name)")
        let decoded = try AnthropicMessagesCodec.parseResponse(Fixtures.bytes("Anthropic/responses/\(name)"))
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        let encoded = AnthropicMessagesCodec.encodeResponse(decoded.value, defaults: anthropicDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == original.canonical)
        #expect(encoded.body == AnthropicMessagesCodec.encodeResponse(decoded.value, defaults: anthropicDefaults).body)
    }

    @Test func thinkingAndCacheUsage() throws {
        let response = try AnthropicMessagesCodec.parseResponse(Fixtures.bytes("Anthropic/responses/thinking_text.json")).value
        #expect(response.message.parts == [
            .reasoning(WireReasoning(text: "2 plus 2 is 4.", signature: "EqQBCkYIBxgCKkDsig==", origin: "anthropic")),
            .reasoning(WireReasoning(text: "", encrypted: "EmwKAhgBEgyredacted", origin: "anthropic")),
            .text(WireText("The answer is 4.")),
        ])
        #expect(response.finishReason == WireFinishReason(.stop, raw: "end_turn"))
        #expect(response.choiceExtra == ["stop_sequence": nil])
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 12 + 100 + 2048, "input tokens include cached ones")
        #expect(usage.cachedInputTokens == 2048)
        #expect(usage.cacheWriteTokens == 100)
        #expect(usage.outputTokens == 30)
        #expect(usage.extra.keys == ["cache_creation", "service_tier"])
    }

    @Test func originIsConfigurable() throws {
        let response = try AnthropicMessagesCodec.parseResponse(
            Fixtures.bytes("Anthropic/responses/thinking_text.json"), origin: "aws-bedrock",
        ).value
        guard case .reasoning(let reasoning) = response.message.parts[0] else {
            Issue.record("expected reasoning")
            return
        }
        #expect(reasoning.origin == "aws-bedrock")
        // A client of the gateway gets the signature only if the origin is trusted.
        let plain = AnthropicMessagesCodec.encodeResponse(response, defaults: anthropicDefaults)
        #expect(plain.json["content"]?[0] == ["type": "thinking", "thinking": "2 plus 2 is 4.", "signature": ""])
        #expect(plain.json["content"]?.arrayValue?.count == 2, "redacted data without a trusted origin is dropped")
        let trusting = AnthropicResponseDefaults(id: "x", model: "m", trustedReasoningOrigins: ["aws-bedrock"])
        #expect(AnthropicMessagesCodec.encodeResponse(response, defaults: trusting).json["content"]?[0]?["signature"] == "EqQBCkYIBxgCKkDsig==")
    }

    @Test func stopReasons() throws {
        func unified(_ raw: String) throws -> WireFinishReason.Unified? {
            let body = #"{"content":[],"stop_reason":"\#(raw)"}"#
            return try AnthropicMessagesCodec.parseResponse(Array(body.utf8)).value.finishReason?.unified
        }
        #expect(try unified("pause_turn") == .other)
        #expect(try unified("refusal") == .contentFilter)
        #expect(try unified("model_context_window_exceeded") == .length)
        #expect(try unified("stop_sequence") == .stop)
        func encoded(_ reason: WireFinishReason?) -> JSONValue? {
            let response = WireResponse(message: WireMessage(role: .assistant, parts: []), finishReason: reason, source: .chatCompletions)
            return AnthropicMessagesCodec.encodeResponse(response, defaults: anthropicDefaults).json["stop_reason"]
        }
        #expect(encoded(WireFinishReason(.toolCalls, raw: "tool_calls")) == "tool_use")
        #expect(encoded(WireFinishReason(.length, raw: "length")) == "max_tokens")
        #expect(encoded(WireFinishReason(.contentFilter, raw: "content_filter")) == "refusal")
        #expect(encoded(nil) == "end_turn")
    }

    @Test func crossProtocolReplyFromChat() throws {
        let chat = try ChatCompletionsCodec.parseResponse(Fixtures.bytes("Chat/responses/deepseek_reasoning.json")).value
        let encoded = AnthropicMessagesCodec.encodeResponse(chat, defaults: anthropicDefaults)
        let json = encoded.json
        #expect(json["content"] == [
            ["type": "thinking", "thinking": "2 plus 2 equals 4.", "signature": ""],
            ["type": "text", "text": "The answer is 4."],
        ])
        #expect(json["stop_reason"] == "end_turn")
        #expect(json["stop_sequence"] == .null)
        #expect(json["usage"] == ["input_tokens": 12, "cache_read_input_tokens": 0, "output_tokens": 30])
        #expect(json["system_fingerprint"] == nil)
        #expect(encoded.warnings.allSatisfy { $0.code == .droppedField })
    }

    @Test func errors() {
        #expect(throws: WireDecodingError(.missingField, path: "content")) {
            try AnthropicMessagesCodec.parseResponse(Array(#"{"id":"x"}"#.utf8))
        }
        #expect(throws: WireDecodingError(.typeMismatch(expected: "an array"), path: "content")) {
            try AnthropicMessagesCodec.parseResponse(Array(#"{"content":"x"}"#.utf8))
        }
    }
}

@Suite struct AnthropicStreamTests {
    @Test func textStream() throws {
        let (events, warnings) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/text.sse"))
        #expect(warnings.isEmpty, "\(warnings)")
        let early = WireUsage(
            inputTokens: 565, outputTokens: 1, cachedInputTokens: 0, cacheWriteTokens: 0, extra: ["service_tier": "standard"],
        )
        var final = early
        final.outputTokens = 15
        let expected: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(
                id: "msg_01Text", model: "claude-sonnet-4-5-20250929", usage: early, source: .anthropicMessages,
            )),
            .textStart(id: "text-0", text: WireText("")),
            .ping,
            .textDelta(id: "text-0", delta: "Hello"),
            .textDelta(id: "text-0", delta: " world"),
            .textEnd(id: "text-0", text: nil),
            .finish(WireFinish(reason: WireFinishReason(.stop, raw: "end_turn"), usage: final, extra: ["stop_sequence": nil])),
        ]
        #expect(events == expected)
    }

    @Test func thinkingWithSignatureDelta() throws {
        let (events, warnings) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/thinking.sse"))
        #expect(warnings.isEmpty)
        let content = Array(events.dropFirst().dropLast())
        #expect(content == [
            .reasoningStart(id: "reasoning-0", reasoning: WireReasoning(text: "", origin: "anthropic")),
            .reasoningDelta(id: "reasoning-0", delta: "2 plus 2"),
            .reasoningDelta(id: "reasoning-0", delta: " is 4."),
            .reasoningSignatureDelta(id: "reasoning-0", delta: "EqQBCkYIBxgCKkDsig=="),
            .reasoningEnd(id: "reasoning-0", reasoning: nil),
            .reasoningStart(id: "reasoning-1", reasoning: WireReasoning(text: "", encrypted: "EmwKAhgBEgyredacted", origin: "anthropic")),
            .reasoningEnd(id: "reasoning-1", reasoning: nil),
            .textStart(id: "text-2", text: WireText("")),
            .textDelta(id: "text-2", delta: "The answer is 4."),
            .textEnd(id: "text-2", text: nil),
        ])
    }

    @Test func parallelToolUse() throws {
        let (events, warnings) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/parallel_tools.sse"))
        #expect(warnings.isEmpty)
        let tool = { (id: String, name: String, arguments: String) in WireToolCall(id: id, name: name, arguments: arguments) }
        let content = Array(events.dropFirst(4).dropLast())
        #expect(content == [
            .toolInputStart(id: "tool-1", call: tool("toolu_T", "get_weather", "")),
            .toolInputDelta(id: "tool-1", delta: #"{"city":"#),
            .ping,
            .toolInputDelta(id: "tool-1", delta: #""Tokyo"}"#),
            .toolInputEnd(id: "tool-1"),
            .toolCall(id: "tool-1", call: tool("toolu_T", "get_weather", #"{"city":"Tokyo"}"#)),
            .toolInputStart(id: "tool-2", call: tool("toolu_O", "get_weather", "")),
            .toolInputDelta(id: "tool-2", delta: #"{"city":"Osaka"}"#),
            .toolInputEnd(id: "tool-2"),
            .toolCall(id: "tool-2", call: tool("toolu_O", "get_weather", #"{"city":"Osaka"}"#)),
            // No input at all: `{}`, as a non-streaming reply's `input` says.
            .toolInputStart(id: "tool-3", call: tool("toolu_N", "list_issues", "")),
            .toolInputDelta(id: "tool-3", delta: "{}"),
            .toolInputEnd(id: "tool-3"),
            .toolCall(id: "tool-3", call: tool("toolu_N", "list_issues", "{}")),
        ])
        guard case .finish(let finish)? = events.last else {
            Issue.record("expected finish")
            return
        }
        #expect(finish.reason == WireFinishReason(.toolCalls, raw: "tool_use"))
        #expect(finish.usage == WireUsage(inputTokens: 80, outputTokens: 40))
    }

    @Test func errorMidStream() throws {
        let (events, warnings) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/error.sse"))
        #expect(warnings.isEmpty, "an error event is a proper ending")
        #expect(Array(events.dropFirst()) == [
            .textStart(id: "text-0", text: WireText("")),
            .textDelta(id: "text-0", delta: "Partial"),
            .textEnd(id: "text-0", text: nil),
            .error(WireStreamError(
                message: "Overloaded", type: "overloaded_error", raw: ["type": "overloaded_error", "message": "Overloaded"],
            )),
            .finish(WireFinish(reason: WireFinishReason(.error), usage: WireUsage(inputTokens: 10, outputTokens: 1))),
        ])
    }

    @Test func serverToolsAndCitations() throws {
        let (events, warnings) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/web_search.sse"))
        #expect(warnings.isEmpty)
        guard case .opaque(let call) = events[1], case .opaque(let result) = events[2] else {
            Issue.record("expected opaque server blocks")
            return
        }
        #expect(call.value == ["type": "server_tool_use", "id": "srvtoolu_01", "name": "web_search", "input": ["query": "tech news today"]])
        #expect(result.value["type"] == "web_search_tool_result")
        #expect(events[3] == .textStart(id: "text-2", text: WireText("", extra: ["citations": []])))
        guard case .textEnd(_, let late?) = events[6] else {
            Issue.record("expected citations at the end of the text block")
            return
        }
        #expect(late.extra["citations"]?[0]?["cited_text"] == "Apple today announced")
    }

    @Test(arguments: streamFixtures)
    func decodedStreamsAreWellFormed(_ name: String) throws {
        let (events, _) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/\(name)"))
        #expect(checkEventSequence(events) == [])
    }

    @Test(arguments: streamFixtures)
    func decodeEncodeDecodeIsStable(_ name: String) throws {
        let (events, _) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/\(name)"))
        let (elements, encodeWarnings) = encodeAnthropicStream(events)
        #expect(encodeWarnings.isEmpty, "\(encodeWarnings)")
        #expect(checkAnthropicStream(elements) == [])
        let (again, _) = try decodeAnthropicStream(elements)
        #expect(again == events)
        let bytes = elements.flatMap { SSEWriter.encode($0) }
        #expect(encodeAnthropicStream(events).elements.flatMap { SSEWriter.encode($0) } == bytes)
    }

    @Test func encoderWritesTheExpectedFrames() {
        let events: [WireEvent] = [
            .ping,
            .responseMetadata(WireResponseMetadata(id: "msg_1", model: "claude", source: .chatCompletions)),
            .ping,
            .textStart(id: "t", text: WireText("")),
            .textDelta(id: "t", delta: "Hi"),
            .textEnd(id: "t", text: nil),
            .toolCall(id: "c", call: WireToolCall(id: "call_1", name: "f", arguments: "")),
            .finish(WireFinish(reason: WireFinishReason(.toolCalls, raw: "tool_calls"), usage: WireUsage(inputTokens: 3, outputTokens: 4, totalTokens: 7))),
        ]
        let (elements, warnings) = encodeAnthropicStream(events)
        #expect(warnings.isEmpty)
        #expect(checkAnthropicStream(elements) == [])
        let text = String(decoding: elements.flatMap { SSEWriter.encode($0) }, as: UTF8.self)
        let expected = [
            ": ping",
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":0,"output_tokens":0}}}"#, "",
            "event: ping", #"data: {"type":"ping"}"#, "",
            "event: content_block_start", #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, "",
            "event: content_block_delta", #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#, "",
            "event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#, "",
            "event: content_block_start", #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_1","name":"f","input":{}}}"#, "",
            "event: content_block_delta", #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#, "",
            "event: content_block_stop", #"data: {"type":"content_block_stop","index":1}"#, "",
            "event: message_delta", #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"input_tokens":3,"output_tokens":4}}"#, "",
            "event: message_stop", #"data: {"type":"message_stop"}"#, "", "",
        ].joined(separator: "\n")
        #expect(text == expected)
    }

    @Test func invalidJSONInStreamThrows() {
        var decoder = AnthropicMessagesStreamDecoder()
        #expect(throws: WireDecodingError.self) {
            try decoder.decode(SSEElement.event(SSEEvent(event: "message_start", data: "{not json")))
        }
    }

    @Test func streamWithoutMessageStopIsClosedWithAWarning() throws {
        var elements = try Fixtures.sse("Anthropic/streams/text.sse")
        elements.removeLast(3) // message_delta, message_stop… and the block's stop
        let (events, warnings) = try decodeAnthropicStream(elements)
        #expect(checkEventSequence(events) == [])
        #expect(warnings.map(\.code) == [.malformedStream])
    }
}
