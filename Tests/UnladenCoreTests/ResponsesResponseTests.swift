import Testing
@_spi(Wire) import UnladenCore

private let responseFixtures = (try? Fixtures.names("Responses/responses", extension: "json")) ?? []
private let streamFixtures = (try? Fixtures.names("Responses/streams", extension: "sse")) ?? []

@Suite struct ResponsesResponseTests {
    @Test func fixturesExist() {
        #expect(responseFixtures.count >= 4)
        #expect(streamFixtures.count >= 7)
    }

    @Test(arguments: responseFixtures)
    func sameProtocolRoundTrip(_ name: String) throws {
        let original = try Fixtures.json("Responses/responses/\(name)")
        let decoded = try ResponsesCodec.parseResponse(Fixtures.bytes("Responses/responses/\(name)"))
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        let encoded = ResponsesCodec.encodeResponse(decoded.value, defaults: responsesDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == original.canonical)
        #expect(encoded.body == ResponsesCodec.encodeResponse(decoded.value, defaults: responsesDefaults).body)
    }

    @Test func reasoningAndUsage() throws {
        let response = try ResponsesCodec.parseResponse(Fixtures.bytes("Responses/responses/reasoning.json")).value
        #expect(response.message.parts == [
            .reasoning(WireReasoning(text: "**Checking the math**", itemID: "rs_reason", summaryIndex: 0, origin: "openai")),
            .reasoning(WireReasoning(
                text: "2 + 2 is 4.", encrypted: "gAAAAABoEncryptedReasoning==", itemID: "rs_reason", summaryIndex: 1, origin: "openai",
            )),
            .text(WireText("The answer is 4.", itemID: "msg_reason", origin: "openai")),
        ])
        #expect(response.finishReason == WireFinishReason(.stop, raw: "completed"))
        #expect(response.usage == WireUsage(
            inputTokens: 30, outputTokens: 120, totalTokens: 150, cachedInputTokens: 16, reasoningTokens: 96,
            inputDetailsExtra: [:], outputDetailsExtra: [:],
        ))
        #expect(response.created == 1_741_290_958)
    }

    @Test func toolCallsAndIncomplete() throws {
        let tools = try ResponsesCodec.parseResponse(Fixtures.bytes("Responses/responses/parallel_tools.json")).value
        #expect(tools.finishReason == WireFinishReason(.toolCalls, raw: "completed"))
        #expect(tools.message.parts.last == .toolCall(WireToolCall(
            id: "call_P", name: "apply_patch", arguments: "*** Begin Patch\n*** End Patch",
            itemType: "custom_tool_call", itemID: "ctc_patch", origin: "openai",
        )))
        let incomplete = try ResponsesCodec.parseResponse(Fixtures.bytes("Responses/responses/incomplete.json")).value
        #expect(incomplete.finishReason == WireFinishReason(.length, raw: "max_output_tokens"))
        let search = try ResponsesCodec.parseResponse(Fixtures.bytes("Responses/responses/web_search.json")).value
        guard case .opaque(let call) = search.message.parts.first, case .text(let cited) = search.message.parts[1] else {
            Issue.record("expected an opaque item and text")
            return
        }
        #expect(call.slot == "item")
        #expect(cited.extra.keys == ["annotations"], "empty logprobs are a default")
    }

    @Test func crossProtocolReplyFromChat() throws {
        let chat = try ChatCompletionsCodec.parseResponse(Fixtures.bytes("Chat/responses/tool_calls.json")).value
        let encoded = ResponsesCodec.encodeResponse(chat, defaults: responsesDefaults)
        let json = encoded.json
        #expect(json["id"]?.stringValue?.hasPrefix("resp_") == true)
        #expect(json["object"] == "response")
        #expect(json["status"] == "completed")
        #expect(json["tools"] == [])
        let output = try #require(json["output"]?.arrayValue)
        #expect(output.allSatisfy { $0["id"]?.stringValue != nil })
        let calls = output.filter { $0["type"] == "function_call" }
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0["id"]?.stringValue?.hasPrefix("fc_") == true && $0["status"] == "completed" })
        #expect(json["usage"]?["total_tokens"] != nil)
        #expect(json["usage"]?["input_tokens_details"]?["cached_tokens"] != nil)
    }

    @Test func errors() {
        #expect(throws: WireDecodingError(.missingField, path: "output")) {
            try ResponsesCodec.parseResponse(Array(#"{"id":"x"}"#.utf8))
        }
        #expect(throws: WireDecodingError(.typeMismatch(expected: "an array"), path: "output")) {
            try ResponsesCodec.parseResponse(Array(#"{"output":"x"}"#.utf8))
        }
    }
}

@Suite struct ResponsesStreamTests {
    @Test func reasoningStream() throws {
        let (events, warnings) = try decodeResponsesStream(Fixtures.sse("Responses/streams/reasoning.sse"))
        #expect(warnings.isEmpty, "\(warnings)")
        let content = Array(events.dropFirst().dropLast())
        #expect(content == [
            .reasoningStart(id: "reasoning-0", reasoning: WireReasoning(text: "", itemID: "rs_reason", summaryIndex: 0, origin: "openai")),
            .reasoningDelta(id: "reasoning-0", delta: "**Checking"),
            .reasoningDelta(id: "reasoning-0", delta: " the math**"),
            .reasoningEnd(id: "reasoning-0", reasoning: nil),
            .reasoningStart(id: "reasoning-1", reasoning: WireReasoning(text: "", itemID: "rs_reason", summaryIndex: 1, origin: "openai")),
            .reasoningDelta(id: "reasoning-1", delta: "2 + 2 "),
            .reasoningDelta(id: "reasoning-1", delta: "is 4."),
            .reasoningEnd(id: "reasoning-1", reasoning: WireReasoning(text: "", encrypted: "gAAAAABoEncryptedReasoning==")),
            .textStart(id: "text-2", text: WireText("", itemID: "msg_reason", origin: "openai")),
            .textDelta(id: "text-2", delta: "The answer is 4."),
            .textEnd(id: "text-2", text: nil),
        ])
        guard case .responseMetadata(let metadata) = events.first, case .finish(let finish) = events.last else {
            Issue.record("expected metadata and finish")
            return
        }
        #expect(metadata.id == "resp_reason")
        #expect(metadata.extra["service_tier"] == "auto")
        #expect(finish.reason == WireFinishReason(.stop, raw: "completed"))
        #expect(finish.extra.isEmpty)
        #expect(finish.usage?.reasoningTokens == 96)
    }

    @Test func failedAndErrorStreams() throws {
        let (failed, failedWarnings) = try decodeResponsesStream(Fixtures.sse("Responses/streams/failed.sse"))
        #expect(failedWarnings.isEmpty)
        let error: JSONValue = ["code": "server_error", "message": "The model failed."]
        #expect(Array(failed.suffix(2)) == [
            .error(WireStreamError(message: "The model failed.", code: "server_error", raw: error)),
            .finish(WireFinish(
                reason: WireFinishReason(.error, raw: "failed"),
                usage: WireUsage(inputTokens: 10, outputTokens: 1, totalTokens: 11, cachedInputTokens: 0, reasoningTokens: 0, inputDetailsExtra: [:], outputDetailsExtra: [:]),
                extra: ["error": error],
            )),
        ])
        let (errored, erroredWarnings) = try decodeResponsesStream(Fixtures.sse("Responses/streams/error.sse"))
        #expect(erroredWarnings.isEmpty, "an error event is a proper ending")
        #expect(Array(errored.suffix(3)) == [
            .textEnd(id: "text-0", text: nil),
            .error(WireStreamError(
                message: "Slow down.", code: "rate_limit_exceeded",
                raw: ["code": "rate_limit_exceeded", "message": "Slow down.", "param": nil],
            )),
            .finish(WireFinish(reason: WireFinishReason(.error))),
        ])
    }

    @Test(arguments: streamFixtures)
    func decodedStreamsAreWellFormed(_ name: String) throws {
        let (events, warnings) = try decodeResponsesStream(Fixtures.sse("Responses/streams/\(name)"))
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(checkEventSequence(events) == [])
    }

    @Test(arguments: streamFixtures)
    func decodeEncodeDecodeIsStable(_ name: String) throws {
        let original = try Fixtures.sse("Responses/streams/\(name)")
        let (events, _) = try decodeResponsesStream(original)
        let (elements, encodeWarnings) = encodeResponsesStream(events)
        #expect(encodeWarnings.isEmpty, "\(encodeWarnings)")
        #expect(checkResponsesStream(elements) == [])
        let (again, decodeWarnings) = try decodeResponsesStream(elements)
        #expect(decodeWarnings.isEmpty, "\(decodeWarnings)")
        if name == "error.sse" {
            // An `error` event comes back as `response.failed`; stable from then on.
            let (third, _) = try decodeResponsesStream(encodeResponsesStream(again).elements)
            #expect(third == again)
        } else {
            #expect(again == events)
            // The re-encoded final response is the upstream's.
            if let upstream = finalResponse(original) {
                #expect(finalResponse(elements)?.canonical == upstream.canonical)
            }
        }
        let bytes = elements.flatMap { SSEWriter.encode($0) }
        #expect(encodeResponsesStream(events).elements.flatMap { SSEWriter.encode($0) } == bytes)
    }

    @Test(arguments: ["text", "reasoning", "parallel_tools", "incomplete"])
    func accumulatedStreamEqualsTheReply(_ name: String) throws {
        let (events, _) = try decodeResponsesStream(Fixtures.sse("Responses/streams/\(name).sse"))
        let accumulator = WireResponseAccumulator(events)
        #expect(accumulator.warnings.isEmpty)
        let reply = try ResponsesCodec.parseResponse(Fixtures.bytes("Responses/responses/\(name).json")).value
        #expect(accumulator.response == reply)
    }

    @Test func encoderNumbersAndNamesEverything() throws {
        let events: [WireEvent] = [
            .ping,
            .responseMetadata(WireResponseMetadata(id: "msg_1", model: "claude", source: .anthropicMessages)),
            .reasoningStart(id: "r", reasoning: WireReasoning(text: "", origin: "anthropic")),
            .reasoningDelta(id: "r", delta: "Hmm."),
            .reasoningSignatureDelta(id: "r", delta: "sig"),
            .reasoningEnd(id: "r", reasoning: nil),
            .textStart(id: "t", text: WireText("")),
            .textDelta(id: "t", delta: "Hi"),
            .textEnd(id: "t", text: nil),
            .toolCall(id: "c", call: WireToolCall(id: "toolu_1", name: "f", arguments: "")),
            .finish(WireFinish(reason: WireFinishReason(.toolCalls, raw: "tool_use"), usage: WireUsage(inputTokens: 3, outputTokens: 4))),
        ]
        let (elements, warnings) = encodeResponsesStream(events)
        #expect(warnings.isEmpty)
        #expect(checkResponsesStream(elements) == [])
        #expect(elements.first == .comment("ping"))
        let names = responsesPayloads(elements).map { $0.name ?? "" }
        #expect(names == [
            "response.created", "response.in_progress",
            "response.output_item.added", "response.reasoning_summary_part.added", "response.reasoning_summary_text.delta",
            "response.reasoning_summary_text.done", "response.reasoning_summary_part.done",
            "response.output_item.done",
            "response.output_item.added", "response.content_part.added", "response.output_text.delta",
            "response.output_text.done", "response.content_part.done", "response.output_item.done",
            "response.output_item.added", "response.function_call_arguments.delta", "response.function_call_arguments.done",
            "response.output_item.done",
            "response.completed",
        ])
        let final = try #require(finalResponse(elements))
        #expect(final["id"] == "resp_msg_1")
        #expect(final["output"]?.arrayValue?.map { $0["id"] } == ["rs_unladen_msg_1_0", "msg_unladen_msg_1_1", "fc_unladen_msg_1_2"])
        #expect(final["output"]?[2]?["arguments"] == "{}")
        #expect(final["output"]?[2]?["call_id"] == "toolu_1")
        #expect(final["usage"] == [
            "input_tokens": 3, "input_tokens_details": ["cached_tokens": 0], "output_tokens": 4,
            "output_tokens_details": ["reasoning_tokens": 0], "total_tokens": 7,
        ])
        let sealed = try #require(final["output"]?[0]?["encrypted_content"]?.stringValue)
        #expect(ResponsesSeal.open(sealed) == .sealed(.init(origin: "anthropic", signature: "sig")))
    }

    @Test func interleavedBlocksAreSerialized() throws {
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/parallel_tools.sse"))
        let (elements, warnings) = encodeResponsesStream(events)
        #expect(checkResponsesStream(elements) == [])
        #expect(warnings.map(\.path) == ["provider", "native_finish_reason"], "OpenRouter's bags")
        let (decoded, decodeWarnings) = try decodeResponsesStream(elements)
        #expect(decodeWarnings.isEmpty)
        #expect(checkEventSequence(decoded) == [])
        let response = WireResponseAccumulator(decoded).response
        let calls = response.message.parts.compactMap { part -> WireToolCall? in
            if case .toolCall(let call) = part { return call }
            return nil
        }
        #expect(calls.map(\.id) == ["call_T", "call_O"])
        #expect(calls.map(\.arguments) == [#"{"city":"Tokyo"}"#, #"{"city":"Osaka"}"#])
        #expect(response.message.parts.first == .reasoning(WireReasoning(text: "Two cities, two calls.", itemID: "rs_unladen_gen-1_0", summaryIndex: 0, origin: "openai")))
        #expect(response.finishReason == WireFinishReason(.toolCalls, raw: "completed"))
        #expect(response.usage?.cachedInputTokens == 64)
    }

    @Test func incompleteFinishMarksTheOpenItem() {
        let events: [WireEvent] = [
            .textStart(id: "t", text: WireText("")),
            .textDelta(id: "t", delta: "Once"),
            .finish(WireFinish(reason: WireFinishReason(.length, raw: "length"))),
        ]
        let (elements, _) = encodeResponsesStream(events)
        #expect(checkResponsesStream(elements) == [])
        let final = finalResponse(elements)
        #expect(final?["status"] == "incomplete")
        #expect(final?["incomplete_details"] == ["reason": "max_output_tokens"])
        #expect(final?["output"]?[0]?["status"] == "incomplete")
        #expect(responsesPayloads(elements).last?.name == "response.incomplete")
    }

    @Test func invalidJSONInStreamThrows() {
        var decoder = ResponsesStreamDecoder()
        #expect(throws: WireDecodingError.self) {
            try decoder.decode(SSEElement.event(SSEEvent(event: "response.created", data: "{not json")))
        }
    }

    @Test func sequenceGapsAndTruncationWarn() throws {
        var elements = try Fixtures.sse("Responses/streams/text.sse")
        elements.remove(at: 4)
        elements.removeLast()
        let (events, warnings) = try decodeResponsesStream(elements)
        #expect(checkEventSequence(events) == [])
        #expect(warnings.map(\.code) == [.malformedStream, .malformedStream])
    }
}
