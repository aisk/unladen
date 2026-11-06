import Testing
@_spi(Wire) import UnladenCore

// Regression tests for the phase-3 acceptance review (gateway probes).
// Each test names its finding.

private func anthropicRequest(_ text: String) throws -> WireRequest {
    try AnthropicMessagesCodec.parseRequest(Array(text.utf8)).value
}

private func sse(_ name: String? = nil, _ data: String) -> SSEElement {
    .event(SSEEvent(event: name, data: data))
}

private func finishes(_ events: [WireEvent]) -> [WireFinish] {
    events.compactMap { if case .finish(let finish) = $0 { finish } else { nil } }
}

private func errors(_ events: [WireEvent]) -> [WireStreamError] {
    events.compactMap { if case .error(let error) = $0 { error } else { nil } }
}

// MARK: - #1 empty content arrays to a Chat upstream

@Suite struct EmptyFormAcrossProtocolsTests {
    @Test func toolOnlyAssistantTurnHasNullContentForChat() throws {
        let request = try anthropicRequest("""
        {"model":"m","max_tokens":10,"messages":[
          {"role":"user","content":[{"type":"text","text":"ls"}]},
          {"role":"assistant","content":[
            {"type":"thinking","thinking":"","signature":"sig"},
            {"type":"tool_use","id":"toolu_1","name":"ls","input":{}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[]}]}
        ]}
        """)
        let json = ChatCompletionsCodec.buildRequest(request).json
        let messages = try #require(json["messages"]?.arrayValue)
        let assistant = try #require(messages.first { $0["role"] == "assistant" })
        #expect(assistant["content"] == .null)
        #expect(assistant["reasoning_content"] == nil)
        let tool = try #require(messages.first { $0["role"] == "tool" })
        #expect(tool["content"] == "")
    }

    @Test func chatEmptyArraysStayForChat() throws {
        let request = try ChatCompletionsCodec.parseRequest(Array("""
        {"model":"m","messages":[{"role":"user","content":"x"},
          {"role":"assistant","content":[],"reasoning_content":"",
           "tool_calls":[{"id":"c","type":"function","function":{"name":"f","arguments":"{}"}}]}]}
        """.utf8)).value
        let assistant = try #require(ChatCompletionsCodec.buildRequest(request).json["messages"]?[1])
        #expect(assistant["content"] == .array([]))
        #expect(assistant["reasoning_content"] == "")
    }

    @Test func emptyToolResultArrayIsAStringForResponses() throws {
        let request = try anthropicRequest("""
        {"model":"m","max_tokens":10,"messages":[
          {"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"ls","input":{}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[]}]}
        ]}
        """)
        let input = try #require(ResponsesCodec.buildRequest(request).json["input"]?.arrayValue)
        let output = try #require(input.first { $0["type"] == "function_call_output" })
        #expect(output["output"] == "")
    }
}

// MARK: - #2 truncated upstream streams

/// What each client encoder makes of a decoded event stream.
private func clientRenderings(_ events: [WireEvent]) -> (chat: [SSEElement], anthropic: [SSEElement], responses: [SSEElement], gemini: [SSEElement]) {
    (encodeChatStream(events).elements, encodeAnthropicStream(events).elements,
     encodeResponsesStream(events).elements, encodeGeminiStream(events).elements)
}

private func expectFailed(_ events: [WireEvent], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(errors(events).count == 1, sourceLocation: sourceLocation)
    #expect(errors(events).first?.message.contains("ended early") == true, sourceLocation: sourceLocation)
    #expect(finishes(events).map(\.reason?.unified) == [.error], sourceLocation: sourceLocation)
    #expect(checkEventSequence(events) == [], sourceLocation: sourceLocation)

    let rendered = clientRenderings(events)
    // Chat: an error chunk and no finish_reason.
    let chat = rendered.chat.compactMap { element -> JSONValue? in
        guard case .event(let event) = element else { return nil }
        return try? JSONValue(parsing: event.data)
    }
    #expect(chat.contains { $0["error"] != nil }, sourceLocation: sourceLocation)
    #expect(!chat.contains { $0["choices"]?[0]?["finish_reason"]?.stringValue != nil }, sourceLocation: sourceLocation)
    // Anthropic: an error event and no message_stop.
    let anthropic = anthropicPayloads(rendered.anthropic).map(\.name)
    #expect(anthropic.contains("error"), sourceLocation: sourceLocation)
    #expect(!anthropic.contains("message_stop"), sourceLocation: sourceLocation)
    #expect(checkAnthropicStream(rendered.anthropic) == [], sourceLocation: sourceLocation)
    // Responses: response.failed.
    let names = responsesPayloads(rendered.responses).map(\.name)
    #expect(names.last == "response.failed", sourceLocation: sourceLocation)
    #expect(!names.contains("response.completed"), sourceLocation: sourceLocation)
    // Gemini: an error frame, no finishReason.
    let frames = geminiChunks(rendered.gemini)
    #expect(frames.last?["error"] != nil, sourceLocation: sourceLocation)
    #expect(!frames.contains { $0["candidates"]?[0]?["finishReason"] != nil }, sourceLocation: sourceLocation)
}

@Suite struct TruncatedStreamTests {
    @Test func anthropicWithoutMessageStop() throws {
        let decoded = try decodeAnthropicStream([
            sse("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"c","usage":{"input_tokens":3,"output_tokens":1}}}"#),
            sse("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            sse("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
        ])
        expectFailed(decoded.events)
    }

    @Test func anthropicStopReasonWithoutMessageStopIsClean() throws {
        let decoded = try decodeAnthropicStream([
            sse("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"c","usage":{"input_tokens":3,"output_tokens":1}}}"#),
            sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}"#),
        ])
        #expect(errors(decoded.events).isEmpty)
        #expect(finishes(decoded.events).map(\.reason?.raw) == ["end_turn"])
    }

    @Test func responsesWithoutCompleted() throws {
        let decoded = try decodeResponsesStream([
            sse(nil, #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","model":"g","status":"in_progress","output":[]}}"#),
            sse(nil, #"{"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
            sse(nil, #"{"type":"response.content_part.added","sequence_number":2,"output_index":0,"content_index":0,"item_id":"msg_1","part":{"type":"output_text","text":"","annotations":[]}}"#),
            sse(nil, #"{"type":"response.output_text.delta","sequence_number":3,"output_index":0,"content_index":0,"item_id":"msg_1","delta":"Hel"}"#),
        ])
        expectFailed(decoded.events)
    }

    @Test func geminiWithoutFinishReason() throws {
        let decoded = try decodeGeminiStream([
            sse(nil, #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]}}],"responseId":"r1","modelVersion":"g"}"#),
        ])
        expectFailed(decoded.events)
    }

    @Test func chatWithoutFinishReason() throws {
        let decoded = try decodeChatStream([
            sse(nil, #"{"id":"c1","object":"chat.completion.chunk","model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}"#),
        ])
        expectFailed(decoded.events)
    }

    @Test func chatFinishReasonWithoutDoneIsClean() throws {
        let decoded = try decodeChatStream([
            sse(nil, #"{"id":"c1","object":"chat.completion.chunk","model":"m","choices":[{"index":0,"delta":{"content":"Hi"}}]}"#),
            sse(nil, #"{"id":"c1","object":"chat.completion.chunk","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
        ])
        #expect(errors(decoded.events).isEmpty)
        #expect(finishes(decoded.events).map(\.reason?.raw) == ["stop"])
    }

    @Test func upstreamErrorIsNotReportedTwice() throws {
        let decoded = try decodeAnthropicStream([
            sse("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"c","usage":{"input_tokens":3}}}"#),
            sse("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
        ])
        #expect(errors(decoded.events).map(\.message) == ["Overloaded"])
    }
}

// MARK: - #3 gateway-minted Responses item ids

@Suite struct MintedResponsesItemIDTests {
    @Test func mintedIDsAreClearedFromClientHistory() throws {
        // An Anthropic upstream reply streamed to a Responses client.
        let encoded = encodeResponsesStream([
            .responseMetadata(WireResponseMetadata(id: "msg_01ToolUse", model: "claude", source: .anthropicMessages)),
            .textStart(id: "t", text: WireText("")),
            .textDelta(id: "t", delta: "Looking."),
            .textEnd(id: "t", text: nil),
            .toolInputStart(id: "c", call: WireToolCall(id: "toolu_1", name: "ls", arguments: "")),
            .toolInputDelta(id: "c", delta: "{}"),
            .toolInputEnd(id: "c"),
            .toolCall(id: "c", call: WireToolCall(id: "toolu_1", name: "ls", arguments: "{}")),
            .finish(WireFinish(reason: WireFinishReason(.toolCalls, raw: "tool_use"))),
        ], defaults: ResponsesResponseDefaults(id: "msg_01ToolUse", model: "claude", created: 1))
        let output = try #require(finalResponse(encoded.elements)?["output"]?.arrayValue)
        let ids = output.compactMap { $0["id"]?.stringValue }
        #expect(ids.count == 2)
        for id in ids { #expect(ResponsesItemID.isMinted(id), "\(id)") }

        // The client echoes them, plus a real upstream item.
        var input = output
        input.insert(["type": "message", "id": "msg_67ab01", "role": "assistant", "content": [["type": "output_text", "text": "Earlier."]]], at: 0)
        input.append(["type": "function_call_output", "call_id": "toolu_1", "output": "a.txt"])
        let request = try ResponsesCodec.parseRequest(JSONValue.object(["model": "gpt", "input": .array(input)])).value
        let built = ResponsesCodec.buildRequest(request).json
        let items = try #require(built["input"]?.arrayValue)
        #expect(items.map { $0["id"] } == ["msg_67ab01", nil, nil, nil])
    }
}

// MARK: - #4 empty Anthropic signatures

@Suite struct EmptySignatureTests {
    @Test func placeholderThinkingIsDroppedQuietlyForAnthropic() throws {
        let request = try anthropicRequest("""
        {"model":"m","max_tokens":10,"messages":[
          {"role":"user","content":"hi"},
          {"role":"assistant","content":[
            {"type":"thinking","thinking":"foreign thought","signature":""},
            {"type":"thinking","thinking":"real","signature":"EqQB"},
            {"type":"text","text":"Hello"}]},
          {"role":"user","content":"again"}
        ]}
        """)
        let built = AnthropicMessagesCodec.buildRequest(request)
        let content = try #require(built.json["messages"]?[1]?["content"]?.arrayValue)
        #expect(content == [
            ["type": "thinking", "thinking": "real", "signature": "EqQB"],
            ["type": "text", "text": "Hello"],
        ])
        #expect(built.warnings.isEmpty)
    }

    @Test func emptySignatureIsNotSignedDataElsewhere() throws {
        let request = try anthropicRequest("""
        {"model":"m","max_tokens":10,"messages":[
          {"role":"assistant","content":[{"type":"thinking","thinking":"t","signature":""},{"type":"text","text":"x"}]}]}
        """)
        guard case .reasoning(let reasoning)? = request.messages.first?.parts.first else {
            Issue.record("no reasoning")
            return
        }
        #expect(reasoning.signature == nil)
        let chat = ChatCompletionsCodec.buildRequest(request)
        #expect(!chat.warnings.contains { $0.message.contains("signature") })
    }
}

// MARK: - #5 whitespace-only text

@Suite struct WhitespaceTextTests {
    private func chatRequest() throws -> WireRequest {
        try ChatCompletionsCodec.parseRequest(Array("""
        {"model":"m","messages":[{"role":"user","content":"ls"},
          {"role":"assistant","content":"\\n","tool_calls":[{"id":"c","type":"function","function":{"name":"ls","arguments":"{}"}}]},
          {"role":"tool","tool_call_id":"c","content":"a.txt"},
          {"role":"user","content":" ok \\n"}]}
        """.utf8)).value
    }

    @Test func anthropicDropsWhitespaceOnlyText() throws {
        let messages = try #require(AnthropicMessagesCodec.buildRequest(chatRequest()).json["messages"]?.arrayValue)
        #expect(messages[1]["content"] == [["type": "tool_use", "id": "c", "name": "ls", "input": [:]]])
        // Real content keeps its whitespace.
        #expect(messages[2]["content"]?[1] == ["type": "text", "text": " ok \n"])
    }

    @Test func geminiDropsWhitespaceOnlyText() throws {
        let contents = try #require(GeminiCodec.buildRequest(chatRequest()).json["contents"]?.arrayValue)
        let modelParts = try #require(contents[1]["parts"]?.arrayValue)
        #expect(modelParts.count == 1)
        #expect(modelParts[0]["functionCall"] != nil)
        #expect(contents.last?["parts"]?.arrayValue?.last == ["text": " ok \n"])
    }
}

// MARK: - #6 reasoning effort to Anthropic

@Suite struct AnthropicEffortTests {
    private func built(_ effort: String, source: WireProtocol = .responses) -> WireEncoded {
        var request = WireRequest(model: "m", messages: [WireMessage(role: .user, parts: [.text(WireText("x"))])], source: source)
        request.reasoning = WireReasoningConfig(effort: effort)
        return AnthropicMessagesCodec.buildRequest(request)
    }

    @Test func effortsAreMapped() {
        for effort in ["low", "medium", "high", "xhigh", "max"] {
            let result = built(effort)
            #expect(result.json["output_config"] == ["effort": .string(effort)])
            #expect(result.warnings.isEmpty)
        }
        let minimal = built("minimal")
        #expect(minimal.json["output_config"] == ["effort": "low"])
        #expect(minimal.warnings.map(\.code) == [.lossyConversion])
        let none = built("none")
        #expect(none.json["output_config"] == nil)
        #expect(none.json["thinking"] == nil)
        #expect(none.warnings.map(\.code) == [.lossyConversion])
        let unknown = built("ultra")
        #expect(unknown.json["output_config"] == nil)
        #expect(unknown.warnings.map(\.code) == [.unsupportedValue])
    }

    @Test func sameProtocolEffortPassesThrough() {
        let result = built("turbo", source: .anthropicMessages)
        #expect(result.json["output_config"] == ["effort": "turbo"])
        #expect(result.warnings.isEmpty)
    }
}

// MARK: - #7 minor

@Suite struct MinorFindingTests {
    // 7a
    @Test func textOnlyBlockToolResultIsAStringForResponses() throws {
        let request = try anthropicRequest("""
        {"model":"m","max_tokens":10,"messages":[
          {"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"ls","input":{}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1",
            "content":[{"type":"text","text":"a.txt"},{"type":"text","text":"b.txt"}]}]}
        ]}
        """)
        let built = ResponsesCodec.buildRequest(request)
        let input = try #require(built.json["input"]?.arrayValue)
        let output = try #require(input.first { $0["type"] == "function_call_output" })
        #expect(output["output"] == "a.txt\nb.txt")
        #expect(built.warnings.map(\.code) == [.lossyConversion])
    }

    @Test func imageToolResultStaysAnArrayForResponses() throws {
        let request = try anthropicRequest("""
        {"model":"m","max_tokens":10,"messages":[
          {"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"shot","input":{}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[
            {"type":"text","text":"here"},
            {"type":"image","source":{"type":"url","url":"https://x/y.png"}}]}]}
        ]}
        """)
        let input = try #require(ResponsesCodec.buildRequest(request).json["input"]?.arrayValue)
        let output = try #require(input.first { $0["type"] == "function_call_output" })
        #expect(output["output"]?.arrayValue?.count == 2)
    }

    // 7b
    @Test func replyIDsWithoutResponseIDDifferAcrossResponses() throws {
        func ids(_ body: String) throws -> [String] {
            let response = try GeminiCodec.parseResponse(Array(body.utf8)).value
            return response.message.parts.compactMap { if case .toolCall(let call) = $0 { call.id } else { nil } }
        }
        let first = #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"ls","args":{"d":"a"}}},{"functionCall":{"name":"ls","args":{"d":"a"}}}]},"finishReason":"STOP"}]}"#
        let second = #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"ls","args":{"d":"b"}}}]},"finishReason":"STOP"}]}"#
        let a = try ids(first)
        let b = try ids(second)
        #expect(a.count == 2)
        #expect(Set(a + b).count == 3)
        #expect(try ids(first) == a, "deterministic")
        for id in a + b {
            #expect(GeminiToolID.isSynthesized(id))
            #expect(AnthropicToolID.isValid(id))
        }
        // The stream decoder agrees with the reply decoder.
        let stream = try decodeGeminiStream([sse(nil, first)])
        let streamed = stream.events.compactMap { if case .toolCall(_, let call) = $0 { call.id } else { nil } }
        #expect(streamed == a)
    }

    // 7c
    @Test func chatToolBlocksCloseWhenTextFollows() throws {
        let decoded = try decodeChatStream([
            sse(nil, #"{"id":"c","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","type":"function","function":{"name":"f","arguments":"{}"}}]}}]}"#),
            sse(nil, #"{"id":"c","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"g","arguments":"{}"}}]}}]}"#),
            sse(nil, #"{"id":"c","model":"m","choices":[{"index":0,"delta":{"content":"done"}}]}"#),
            sse(nil, #"{"id":"c","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#),
            sse(nil, "[DONE]"),
        ])
        #expect(checkEventSequence(decoded.events) == [])
        let firstText = try #require(decoded.events.firstIndex { if case .textStart = $0 { true } else { false } })
        let lastToolEnd = try #require(decoded.events.lastIndex { if case .toolInputEnd = $0 { true } else { false } })
        #expect(lastToolEnd < firstText)
    }
}
