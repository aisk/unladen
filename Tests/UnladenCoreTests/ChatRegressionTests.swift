import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

// Regression tests for the phase-2 acceptance review. Each names its finding.

private func parse(_ text: String) throws -> WireDecoded<WireRequest> {
    try ChatCompletionsCodec.parseRequest(Array(text.utf8))
}

private func events(_ chunks: [String], done: Bool = true) throws -> (events: [WireEvent], warnings: [WireWarning]) {
    var elements = chunks.map { SSEElement.event(SSEEvent(data: $0)) }
    if done { elements.append(.event(SSEEvent(data: "[DONE]"))) }
    return try decodeChatStream(elements)
}

private func toolCalls(_ events: [WireEvent]) -> [WireToolCall] {
    events.compactMap {
        if case .toolCall(_, let call) = $0 { return call }
        return nil
    }
}

@Suite struct ChatSpellingTests {
    // #1: another protocol's spelling must not leak into Chat output.
    @Test func foreignSpellingsAreIgnored() {
        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .assistant, parts: [
                .reasoning(WireReasoning(text: "r", sourceKey: "reasoning")),
                .text(WireText("a")),
                .refusal(WireRefusal("no")),
            ], contentForm: .parts),
        ], source: .responses)
        request.reasoning = WireReasoningConfig(effort: "high")
        request.spellings = [.reasoning: "reasoning", .maxOutputTokens: "max_tokens"]
        request.maxOutputTokens = 10
        let json = ChatCompletionsCodec.buildRequest(request).json
        #expect(json["reasoning_effort"] == "high")
        #expect(json["reasoning"] == nil)
        #expect(json["max_completion_tokens"] == 10)
        #expect(json["max_tokens"] == nil)
        let message = json["messages"]?[0]
        #expect(message?["reasoning_content"] == "r")
        #expect(message?["reasoning"] == nil)
        // A refusal without a Chat sourceKey goes to the field, valid everywhere.
        #expect(message?["refusal"] == "no")
        #expect(message?["content"] == [["type": "text", "text": "a"]])
    }

    @Test func sameProtocolSpellingsAreKept() throws {
        let text = #"{"model":"m","messages":[],"max_tokens":5,"reasoning":{"effort":"low","exclude":true}}"#
        let request = try parse(text).value
        #expect(request.reasoning == WireReasoningConfig(effort: "low", visible: false))
        #expect(ChatCompletionsCodec.buildRequest(request).json == (try JSONValue(parsing: text)))
    }

    // #15: OpenRouter `exclude` maps to `visible`, which Chat's
    // `reasoning_effort` cannot carry.
    @Test func visibleNeedsTheReasoningObject() {
        var request = WireRequest(model: "m", messages: [])
        request.reasoning = WireReasoningConfig(effort: "low", visible: true)
        let built = ChatCompletionsCodec.buildRequest(request)
        #expect(built.json["reasoning_effort"] == "low")
        #expect(built.warnings.map(\.code) == [.droppedField])
    }
}

@Suite struct ChatRefusalPlacementTests {
    // #7: a top-level refusal beside a content array stays top-level.
    @Test func fieldRefusalBesideContentArrayRoundTrips() throws {
        let text = #"{"model":"m","messages":[{"role":"assistant","content":[{"type":"text","text":"a"}],"refusal":"no"},{"role":"assistant","content":[{"type":"refusal","refusal":"part"}]}]}"#
        let request = try parse(text).value
        #expect(request.messages[0].parts.last == .refusal(WireRefusal("no", sourceKey: "refusal")))
        #expect(request.messages[1].parts == [.refusal(WireRefusal("part"))])
        #expect(ChatCompletionsCodec.buildRequest(request).json == (try JSONValue(parsing: text)))
    }
}

@Suite struct ChatToolIDTests {
    // #3: ids are never invented by encoders; Chat decoders synthesize
    // position-based ids for non-conforming input and mark them.
    @Test func requestCallWithoutIDGetsSynthesizedID() throws {
        let decoded = try parse(#"{"model":"m","messages":[{"role":"user","content":"x"},{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"f","arguments":"{}"}}]}]}"#)
        #expect(decoded.value.messages[1].parts == [.toolCall(WireToolCall(id: "call_m1_0", idSynthesized: true, name: "f", arguments: "{}"))])
        #expect(decoded.warnings.map(\.code) == [.lossyConversion])
        let built = ChatCompletionsCodec.buildRequest(decoded.value).json
        #expect(built["messages"]?[1]?["tool_calls"]?[0]?["id"] == "call_m1_0")
    }

    @Test func streamCallWithoutIDGetsSynthesizedID() throws {
        let (decoded, warnings) = try events([
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"f","arguments":"{}"}}]}}]}"#,
        ])
        #expect(toolCalls(decoded) == [WireToolCall(id: "call_tool-0", idSynthesized: true, name: "f", arguments: "{}")])
        #expect(warnings.map(\.code) == [.malformedStream])
    }

    @Test func encodersKeepTheGivenID() throws {
        var encoder = ChatCompletionsStreamEncoder(defaults: testDefaults, includeUsage: false)
        let out = encoder.encode(.toolCall(id: "b", call: WireToolCall(id: "abc", idSynthesized: true, name: "f", arguments: "{}")))
        guard case .event(let event)? = out.last else {
            Issue.record("expected an event")
            return
        }
        #expect(try JSONValue(parsing: event.data)["choices"]?[0]?["delta"]?["tool_calls"]?[0]?["id"] == "abc")
    }
}

@Suite struct ChatWireModelEncodingTests {
    // #5: instructions form and bag.
    @Test func instructionsUseTheirFormAndDropForeignBags() {
        var request = WireRequest(model: "m", messages: [], source: .gemini)
        request.instructions = [.text(WireText("Be brief."))]
        request.instructionsForm = .parts
        request.instructionsExtra = ["role": "system"]
        let built = ChatCompletionsCodec.buildRequest(request)
        #expect(built.json["messages"] == [["role": "system", "content": [["type": "text", "text": "Be brief."]]]])
        #expect(built.warnings.map(\.path) == ["instructions.role"])
    }

    // #6: role-less items keep only what Chat can say.
    @Test func roleLessItems() {
        let request = WireRequest(model: "m", messages: [
            WireMessage(role: .item, parts: [.opaque(WireOpaque(protocol: .responses, value: ["type": "item_reference", "id": "x"]))]),
            WireMessage(role: .item, parts: [.toolResult(WireToolResult(
                callID: "c", content: [.text(WireText("out"))], itemType: "custom_tool_call_output", itemID: "ctco_1",
            ))]),
        ], source: .responses)
        let built = ChatCompletionsCodec.buildRequest(request)
        #expect(built.json["messages"] == [["role": "tool", "content": "out", "tool_call_id": "c"]])
        #expect(built.warnings.map(\.code) == [.droppedContent, .lossyConversion])
    }

    // #11: a reply without a finish reason says "stop", as streams do; the
    // same protocol's `null` comes back as `null`.
    @Test func missingFinishReason() throws {
        let foreign = WireResponse(message: WireMessage(role: .assistant, parts: [.text(WireText("a"))]), source: .gemini)
        #expect(ChatCompletionsCodec.encodeResponse(foreign, defaults: testDefaults).json["choices"]?[0]?["finish_reason"] == "stop")

        let text = #"{"id":"i","object":"chat.completion","created":1,"model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"a"},"finish_reason":null}]}"#
        let same = try ChatCompletionsCodec.parseResponse(Array(text.utf8))
        let encoded = ChatCompletionsCodec.encodeResponse(same.value, defaults: testDefaults)
        #expect(encoded.json == (try JSONValue(parsing: text)))
        #expect(encoded.warnings.isEmpty)
    }

    // #12: `cache_write_tokens` is not an OpenAI field.
    @Test func cacheWriteTokensOnlyForChatSources() {
        let usage = WireUsage(inputTokens: 10, outputTokens: 1, cacheWriteTokens: 4)
        func details(_ source: WireProtocol) -> JSONValue? {
            let response = WireResponse(message: WireMessage(role: .assistant, parts: []), usage: usage, source: source)
            return ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults).json["usage"]?["prompt_tokens_details"]
        }
        #expect(details(.anthropicMessages) == nil)
        #expect(details(.chatCompletions) == ["cache_write_tokens": 4])
    }
}

@Suite struct ChatStreamRegressionTests {
    // #10: a Chat opaque tool call is re-encoded as a tool_calls fragment.
    @Test func opaqueToolCallIsStreamed() throws {
        let custom: JSONValue = ["id": "ct", "type": "custom", "custom": ["name": "sh", "input": "ls"]]
        let events: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(id: "x", source: .chatCompletions)),
            .opaque(WireOpaque(protocol: .chatCompletions, value: custom, slot: "tool_calls")),
            .toolCall(id: "t", call: WireToolCall(id: "c", name: "f", arguments: "{}")),
            .finish(WireFinish(reason: WireFinishReason(.toolCalls, raw: "tool_calls"))),
        ]
        let (elements, warnings) = encodeChatStream(events)
        #expect(warnings.isEmpty)
        #expect(checkChatStream(elements) == [])
        let fragments = elements.compactMap { element -> JSONValue? in
            guard case .event(let event) = element, let json = try? JSONValue(parsing: event.data) else { return nil }
            return json["choices"]?[0]?["delta"]?["tool_calls"]?[0]
        }
        #expect(fragments == [
            ["id": "ct", "type": "custom", "custom": ["name": "sh", "input": "ls"], "index": 0],
            ["index": 1, "id": "c", "type": "function", "function": ["name": "f", "arguments": "{}"]],
        ])
    }

    // Cross-protocol re-encode: an Anthropic-sourced stream to a Chat client.
    @Test func foreignStreamReencode() throws {
        let call = WireToolCall(id: "toolu_1", name: "get", arguments: "", signature: "sig", origin: "google")
        var done = call
        done.arguments = #"{"a":1}"#
        let source: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(
                id: "msg_1", model: "claude", usage: WireUsage(inputTokens: 5),
                extra: ["type": "message"], source: .anthropicMessages,
            )),
            .ping,
            .reasoningStart(id: "r", reasoning: WireReasoning(text: "", sourceKey: "reasoning")),
            .reasoningDelta(id: "r", delta: "think"),
            .reasoningSignatureDelta(id: "r", delta: "SIG"),
            .reasoningEnd(id: "r", reasoning: nil),
            .textStart(id: "t", text: WireText("", itemID: "msg_1", origin: "anthropic")),
            .textDelta(id: "t", delta: "Hi"),
            .textEnd(id: "t", text: WireText("", signature: "gsig", origin: "google")),
            .toolInputStart(id: "u", call: call),
            .toolInputDelta(id: "u", delta: #"{"a":1}"#),
            .toolInputEnd(id: "u"),
            .toolCall(id: "u", call: done),
            .finish(WireFinish(
                reason: WireFinishReason(.toolCalls, raw: "tool_use"),
                usage: WireUsage(inputTokens: 5, outputTokens: 7, cacheWriteTokens: 2, extra: ["service_tier": "standard"]),
                extra: ["stop_sequence": "x"],
            )),
        ]
        let (elements, warnings) = encodeChatStream(source)
        #expect(checkChatStream(elements) == [])
        #expect(warnings.map(\.code) == [.droppedField, .droppedContent, .droppedContent, .droppedContent, .droppedField])

        let (decoded, _) = try decodeChatStream(elements)
        #expect(checkEventSequence(decoded) == [])
        let expected: [WireEvent] = [
            .ping,
            .responseMetadata(WireResponseMetadata(id: "msg_1", model: "claude", created: 1_700_000_000, source: .chatCompletions)),
            .reasoningStart(id: "reasoning-0", reasoning: WireReasoning(text: "", sourceKey: "reasoning_content")),
            .reasoningDelta(id: "reasoning-0", delta: "think"),
            .reasoningEnd(id: "reasoning-0", reasoning: nil),
            .textStart(id: "text-1", text: WireText("")),
            .textDelta(id: "text-1", delta: "Hi"),
            .textEnd(id: "text-1", text: nil),
            .toolInputStart(id: "tool-2", call: WireToolCall(id: "toolu_1", name: "get", arguments: "")),
            .toolInputDelta(id: "tool-2", delta: #"{"a":1}"#),
            .toolInputEnd(id: "tool-2"),
            .toolCall(id: "tool-2", call: WireToolCall(id: "toolu_1", name: "get", arguments: #"{"a":1}"#)),
            .finish(WireFinish(
                reason: WireFinishReason(.toolCalls, raw: "tool_calls"),
                usage: WireUsage(inputTokens: 5, outputTokens: 7, totalTokens: 12),
            )),
        ]
        #expect(decoded == expected)
    }

    @Test func contentAfterFinishReasonIsKeptWithAWarning() throws {
        let (decoded, warnings) = try events([
            #"{"id":"x","choices":[{"index":0,"delta":{"content":"a"},"finish_reason":"stop"}]}"#,
            #"{"id":"x","choices":[{"index":0,"delta":{"content":"b"}}]}"#,
        ])
        #expect(checkEventSequence(decoded) == [])
        let deltas = decoded.compactMap { event -> String? in
            if case .textDelta(_, let delta) = event { return delta }
            return nil
        }
        #expect(deltas == ["a", "b"])
        #expect(warnings.map(\.message) == ["content after finish_reason"])
        guard case .finish(let finish)? = decoded.last else {
            Issue.record("expected finish")
            return
        }
        #expect(finish.reason?.raw == "stop")
    }

    @Test func toolFragmentsWithoutIndexUseTheirPosition() throws {
        // A relay that never sends `index`: each delta carries one fragment,
        // a new id starts a new call, id-less fragments continue the last.
        let (decoded, _) = try events([
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"id":"a","function":{"name":"f","arguments":"{\"x\":"}}]}}]}"#,
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"function":{"arguments":"1}"}}]}}]}"#,
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"id":"b","function":{"name":"g","arguments":"{}"}}]}}]}"#,
            #"{"id":"x","choices":[{"index":0,"delta":{"tool_calls":[{"id":"c","function":{"name":"h","arguments":"{}"}},{"id":"d","function":{"name":"i","arguments":"{}"}}]}}]}"#,
        ])
        #expect(checkEventSequence(decoded) == [])
        #expect(toolCalls(decoded).map(\.id) == ["a", "b", "c", "d"])
        #expect(toolCalls(decoded).first?.arguments == #"{"x":1}"#)
    }

    @Test func otherChoiceIndicesAreIgnored() throws {
        let (decoded, warnings) = try events([
            #"{"id":"x","choices":[{"index":0,"delta":{"content":"a"}}]}"#,
            #"{"id":"x","choices":[{"index":2,"delta":{"content":"other"}}]}"#,
            #"{"id":"x","choices":[{"index":1,"delta":{"content":"other"}},{"index":0,"delta":{"content":"b"},"finish_reason":"stop"}]}"#,
        ])
        let text = decoded.compactMap { event -> String? in
            if case .textDelta(_, let delta) = event { return delta }
            return nil
        }
        #expect(text == ["a", "b"])
        #expect(warnings.map(\.code) == [.droppedContent])
    }

    // #9: the async adapter stops after a decode error.
    @Test func wireEventSequenceEndsAfterAThrow() async throws {
        let stream = AsyncStream<SSEElement> { continuation in
            continuation.yield(.event(SSEEvent(data: "{bad")))
            continuation.yield(.event(SSEEvent(data: #"{"id":"x","choices":[]}"#)))
            continuation.finish()
        }
        var iterator = stream.wireEvents(ChatCompletionsStreamDecoder()).makeAsyncIterator()
        await #expect(throws: WireDecodingError.self) { try await iterator.next() }
        #expect(try await iterator.next() == nil)
    }
}
