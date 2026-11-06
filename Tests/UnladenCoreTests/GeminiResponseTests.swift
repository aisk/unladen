import Testing
@_spi(Wire) import UnladenCore

private let responseFixtures = (try? Fixtures.names("Gemini/responses", extension: "json")) ?? []
private let streamFixtures = (try? Fixtures.names("Gemini/streams", extension: "sse")) ?? []

@Suite struct GeminiResponseTests {
    @Test func fixturesExist() {
        #expect(responseFixtures.count >= 4)
        #expect(streamFixtures.count >= 5)
    }

    @Test(arguments: responseFixtures)
    func sameProtocolRoundTrip(_ name: String) throws {
        let original = try Fixtures.json("Gemini/responses/\(name)")
        let decoded = try GeminiCodec.parseResponse(Fixtures.bytes("Gemini/responses/\(name)"))
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        let encoded = GeminiCodec.encodeResponse(decoded.value, defaults: geminiDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == original.canonical)
        #expect(encoded.body == GeminiCodec.encodeResponse(decoded.value, defaults: geminiDefaults).body)
    }

    @Test func thoughtsAndUsage() throws {
        let response = try GeminiCodec.parseResponse(Fixtures.bytes("Gemini/responses/thoughts.json")).value
        #expect(response.message.parts == [
            .reasoning(WireReasoning(text: "**Planning**\nI will add the numbers.", signature: "sigThought==", origin: "gemini")),
            .text(WireText("2 + 2 = 4.")),
        ])
        #expect(response.finishReason == WireFinishReason(.stop, raw: "STOP"))
        #expect(response.id == "resp-R1")
        #expect(response.model == "gemini-2.5-flash")
        let usage = try #require(response.usage)
        #expect(usage.inputTokens == 12)
        #expect(usage.cachedInputTokens == 4)
        #expect(usage.outputTokens == 7 + 40, "candidates exclude thoughts; wire output includes them")
        #expect(usage.reasoningTokens == 40)
        #expect(usage.totalTokens == 59)
    }

    @Test func parallelCallsGetReplyScopedIds() throws {
        let response = try GeminiCodec.parseResponse(Fixtures.bytes("Gemini/responses/parallel_tools.json")).value
        #expect(response.message.parts == [
            .text(WireText("Checking both.")),
            .toolCall(WireToolCall(
                id: "unladen_gc_resp-P1_0", idSynthesized: true, name: "get_weather", arguments: #"{"city":"Paris"}"#,
                signature: "sigCallFirst==", origin: "gemini",
            )),
            .toolCall(WireToolCall(id: "unladen_gc_resp-P1_1", idSynthesized: true, name: "get_time", arguments: #"{"tz":"Europe/Paris"}"#)),
        ])
        #expect(response.finishReason == WireFinishReason(.toolCalls, raw: "STOP"))
    }

    @Test func blockedPrompt() throws {
        let response = try GeminiCodec.parseResponse(Fixtures.bytes("Gemini/responses/blocked.json")).value
        #expect(response.message.parts.isEmpty)
        #expect(response.finishReason == WireFinishReason(.contentFilter))
        #expect(response.choiceExtra["promptFeedback"]?["blockReason"] == "SAFETY")
        // Another protocol's client sees a content filter.
        let chat = ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults)
        #expect(chat.json["choices"]?[0]?["finish_reason"] == "content_filter")
    }

    @Test func finishReasons() throws {
        func unified(_ raw: String) throws -> WireFinishReason.Unified? {
            let body = #"{"candidates":[{"content":{"parts":[{"text":"x"}],"role":"model"},"finishReason":"\#(raw)"}]}"#
            return try GeminiCodec.parseResponse(Array(body.utf8)).value.finishReason?.unified
        }
        #expect(try unified("MAX_TOKENS") == .length)
        #expect(try unified("RECITATION") == .contentFilter)
        #expect(try unified("MALFORMED_FUNCTION_CALL") == .error)
        #expect(try unified("LANGUAGE") == .other)
        func encoded(_ reason: WireFinishReason?) -> JSONValue? {
            let response = WireResponse(message: WireMessage(role: .assistant, parts: []), finishReason: reason, source: .chatCompletions)
            return GeminiCodec.encodeResponse(response, defaults: geminiDefaults).json["candidates"]?[0]?["finishReason"]
        }
        #expect(encoded(WireFinishReason(.toolCalls, raw: "tool_calls")) == "STOP")
        #expect(encoded(WireFinishReason(.length, raw: "length")) == "MAX_TOKENS")
        #expect(encoded(WireFinishReason(.contentFilter, raw: "content_filter")) == "SAFETY")
        #expect(encoded(nil) == "STOP")
    }

    @Test func crossProtocolReplyFromAnthropic() throws {
        let claude = try AnthropicMessagesCodec.parseResponse(Fixtures.bytes("Anthropic/responses/thinking_text.json")).value
        let encoded = GeminiCodec.encodeResponse(claude, defaults: geminiDefaults)
        let json = encoded.json
        #expect(json["candidates"]?[0]?["content"]?["parts"] == [
            ["text": "2 plus 2 is 4.", "thought": true],
            ["text": "The answer is 4."],
        ])
        #expect(json["candidates"]?[0]?["finishReason"] == "STOP")
        #expect(json["usageMetadata"]?["promptTokenCount"] == 2160)
        #expect(json["usageMetadata"]?["candidatesTokenCount"] == 30)
        #expect(json["usageMetadata"]?["totalTokenCount"] == 2190)
        #expect(json["responseId"] == "msg_01Thinking")
        #expect(encoded.warnings.filter { $0.code != .droppedField }.map(\.code) == [.droppedContent, .droppedContent], "signature, redacted data")
    }

    @Test func errors() {
        #expect(throws: WireDecodingError(.typeMismatch(expected: "an array"), path: "candidates")) {
            try GeminiCodec.parseResponse(Array(#"{"candidates":{}}"#.utf8))
        }
    }
}

@Suite struct GeminiStreamTests {
    @Test(arguments: streamFixtures)
    func decodeEncodeDecodeIsStable(_ name: String) throws {
        let (events, warnings) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/\(name)"))
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(checkEventSequence(events) == [])
        let (elements, encodeWarnings) = encodeGeminiStream(events)
        #expect(encodeWarnings.isEmpty, "\(encodeWarnings)")
        #expect(checkGeminiStream(elements) == [])
        let (again, _) = try decodeGeminiStream(elements)
        #expect(again == events)
        #expect(encodeGeminiStream(again).elements == elements)
    }

    @Test(arguments: ["text", "thoughts", "parallel_tools"])
    func accumulatedStreamEqualsParsedReply(_ name: String) throws {
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/\(name).sse"))
        let accumulator = WireResponseAccumulator(events)
        #expect(accumulator.warnings.isEmpty)
        let reply = try GeminiCodec.parseResponse(Fixtures.bytes("Gemini/responses/\(name).json")).value
        #expect(accumulator.response == reply)
    }

    @Test func thoughtSignatureOnEmptyPartEndsTheBlock() throws {
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/thoughts.sse"))
        #expect(Array(events.dropFirst().dropLast()) == [
            .reasoningStart(id: "reasoning-0", reasoning: WireReasoning(text: "", origin: "gemini")),
            .reasoningDelta(id: "reasoning-0", delta: "**Planning**\n"),
            .reasoningDelta(id: "reasoning-0", delta: "I will add the numbers."),
            .reasoningEnd(id: "reasoning-0", reasoning: WireReasoning(text: "", signature: "sigThought==", origin: "gemini")),
            .textStart(id: "text-1", text: WireText("")),
            .textDelta(id: "text-1", delta: "2 + 2 = 4."),
            .textEnd(id: "text-1", text: nil),
        ])
        // Re-encoded, the signature is again on an empty thought part.
        let parts = geminiParts(encodeGeminiStream(events).elements)
        #expect(parts[2] == ["text": "", "thought": true, "thoughtSignature": "sigThought=="])
    }

    @Test func parallelCallsArriveWhole() throws {
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/parallel_tools.sse"))
        let calls = events.compactMap { event -> WireToolCall? in
            if case .toolCall(_, let call) = event { return call }
            return nil
        }
        #expect(calls.map(\.id) == ["unladen_gc_resp-P1_0", "unladen_gc_resp-P1_1"])
        #expect(calls.map(\.signature) == ["sigCallFirst==", nil])
        guard case .finish(let finish)? = events.last else {
            Issue.record("expected a finish")
            return
        }
        #expect(finish.reason == WireFinishReason(.toolCalls, raw: "STOP"))
        // Back to a Gemini client: whole calls, no invented ids, signature on the first.
        let (elements, _) = encodeGeminiStream(events)
        let parts = geminiParts(elements)
        #expect(parts[1] == ["functionCall": ["name": "get_weather", "args": ["city": "Paris"]], "thoughtSignature": "sigCallFirst=="])
        #expect(parts[2] == ["functionCall": ["name": "get_time", "args": ["tz": "Europe/Paris"]]])
        let last = try #require(geminiChunks(elements).last)
        #expect(last["usageMetadata"] == ["promptTokenCount": 50, "candidatesTokenCount": 20, "totalTokenCount": 70])
    }

    @Test func maxTokensAndSafety() throws {
        let (length, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/max_tokens.sse"))
        #expect(WireResponseAccumulator(length).response.finishReason == WireFinishReason(.length, raw: "MAX_TOKENS"))
        let (safety, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/safety.sse"))
        let response = WireResponseAccumulator(safety).response
        #expect(response.finishReason == WireFinishReason(.contentFilter, raw: "SAFETY"))
        #expect(response.choiceExtra.keys == ["safetyRatings"])
        #expect(response.message.parts == [.text(WireText("Here is how"))])
    }

    @Test func blockedPromptStream() throws {
        let body = try Fixtures.json("Gemini/responses/blocked.json")
        let elements: [SSEElement] = [.event(SSEEvent(data: body.description))]
        let (events, warnings) = try decodeGeminiStream(elements)
        #expect(warnings.isEmpty, "\(warnings)")
        let accumulated = WireResponseAccumulator(events).response
        #expect(accumulated == (try GeminiCodec.parseResponse(body).value))
        let (encoded, _) = encodeGeminiStream(events)
        #expect(checkGeminiStream(encoded) == [])
        #expect(geminiChunks(encoded).map(\.canonical) == [body.canonical])
    }

    @Test func errorFrame() throws {
        let elements: [SSEElement] = [
            .event(SSEEvent(data: #"{"candidates":[{"content":{"parts":[{"text":"Hi"}],"role":"model"}}],"responseId":"r"}"#)),
            .event(SSEEvent(data: #"{"error":{"code":503,"message":"The model is overloaded.","status":"UNAVAILABLE"}}"#)),
        ]
        let (events, _) = try decodeGeminiStream(elements)
        #expect(checkEventSequence(events) == [])
        #expect(events.contains(.error(WireStreamError(
            message: "The model is overloaded.", type: "UNAVAILABLE", code: "503",
            raw: ["code": 503, "message": "The model is overloaded.", "status": "UNAVAILABLE"],
        ))))
        let (encoded, _) = encodeGeminiStream(events)
        #expect(checkGeminiStream(encoded) == [])
        #expect(geminiChunks(encoded).last == ["error": ["code": 503, "message": "The model is overloaded.", "status": "UNAVAILABLE"]])
        // Another protocol's client gets its own error shape.
        let (chat, _) = encodeChatStream(events)
        #expect(checkChatStream(chat) == [])
    }

    @Test func pingsWriteNothing() {
        let events: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(id: "x", source: .anthropicMessages)),
            .ping,
            .textStart(id: "t", text: WireText("")),
            .textDelta(id: "t", delta: "hi"),
            .textEnd(id: "t", text: nil),
            .finish(WireFinish(reason: WireFinishReason(.stop, raw: "end_turn"))),
        ]
        let (elements, _) = encodeGeminiStream(events)
        #expect(checkGeminiStream(elements) == [])
        #expect(elements.count == 1, "the only content frame carries the finish")
    }
}
