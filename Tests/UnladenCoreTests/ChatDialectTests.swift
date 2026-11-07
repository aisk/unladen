import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

/// Vendor dialects of Chat Completions the codecs type: Gemini's
/// `extra_content`, OpenRouter's `reasoning_details`, Mistral's `thinking`
/// content parts.
@Suite struct ChatDialectTests {
    private func sse(_ chunks: [String]) -> [SSEElement] {
        chunks.map { .event(SSEEvent(data: $0)) } + [.event(SSEEvent(data: "[DONE]"))]
    }

    private func chunk(_ delta: String, finish: String = "null") -> String {
        #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
    }

    /// Decode → Chat stream → decode again keeps the reply (same protocol).
    private func expectStableStream(_ events: [WireEvent], origin: WireSystemID?) throws -> [SSEElement] {
        let (elements, warnings) = encodeChatStream(events)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(checkChatStream(elements) == [])
        let (again, _) = try decodeChatStream(elements, origin: origin)
        #expect(WireResponseAccumulator(again).response.message == WireResponseAccumulator(events).response.message)
        return elements
    }

    private func deltas(_ elements: [SSEElement]) throws -> [JSONValue] {
        try elements.compactMap { element in
            guard case .event(let event) = element, event.data != "[DONE]" else { return nil }
            return try JSONValue(parsing: Array(event.data.utf8))["choices"]?[0]?["delta"]
        }
    }

    // MARK: Gemini extra_content

    @Test func geminiThoughtMarkerAndDeltaSignature() throws {
        let (events, warnings) = try decodeChatStream(sse([
            chunk(#"{"role":"assistant","content":"Thinking.","extra_content":{"google":{"thought":true}}}"#),
            chunk(#"{"content":"Hello"}"#),
            chunk(#"{"content":"","extra_content":{"google":{"thought_signature":"sig1","extra":1},"other":true}}"#, finish: #""stop""#),
        ]), origin: "gemini")
        #expect(warnings.allSatisfy { $0.code == .unknownField }, "\(warnings)")
        let message = WireResponseAccumulator(events).response.message
        #expect(message.parts == [
            .reasoning(WireReasoning(text: "Thinking.", sourceKey: "extra_content.google.thought")),
            .text(WireText("Hello", signature: "sig1", origin: "gemini", extra: ["extra_content": ["google": ["extra": 1], "other": true]])),
        ])

        let written = try deltas(expectStableStream(events, origin: "gemini"))
        #expect(written.contains { $0 == ["content": "Thinking.", "extra_content": ["google": ["thought": true]]] })
        #expect(written.contains { $0["extra_content"] == ["google": ["extra": 1, "thought_signature": "sig1"], "other": true] })
    }

    @Test func geminiSignatureEndsTheBlockAndSignsAnEmptyOneWhenNoneIsOpen() throws {
        let (events, _) = try decodeChatStream(sse([
            chunk(#"{"extra_content":{"google":{"thought_signature":"lonely"}}}"#),
            chunk(#"{"content":"A","extra_content":{"google":{"thought_signature":"a"}}}"#),
            chunk(#"{"content":"B"}"#, finish: #""stop""#),
        ]), origin: "gemini")
        #expect(WireResponseAccumulator(events).response.message.parts == [
            .text(WireText("", signature: "lonely", origin: "gemini")),
            .text(WireText("A", signature: "a", origin: "gemini")),
            .text(WireText("B")),
        ])
        #expect(checkEventSequence(events) == [])
        _ = try expectStableStream(events, origin: "gemini")
    }

    @Test func geminiToolCallSignatureIsTypedAndWrittenBackForChatOnly() throws {
        let (events, warnings) = try decodeChatStream(sse([
            chunk(#"{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"f","arguments":"{}"},"extra_content":{"google":{"thought_signature":"tsig"}}}]}"#, finish: #""stop""#),
        ]), origin: "gemini")
        #expect(warnings.isEmpty, "\(warnings)")
        let call = WireToolCall(id: "call_1", name: "f", arguments: "{}", signature: "tsig", origin: "gemini")
        #expect(WireResponseAccumulator(events).response.message.parts == [.toolCall(call)])
        let written = try deltas(expectStableStream(events, origin: "gemini"))
        #expect(written.contains { $0["tool_calls"]?[0]?["extra_content"] == ["google": ["thought_signature": "tsig"]] })

        // Non-streaming, and requests: the same.
        let message: JSONValue = [
            "role": "assistant", "content": nil,
            "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "f", "arguments": "{}"],
                            "extra_content": ["google": ["thought_signature": "tsig"]]]],
        ]
        let body: JSONValue = ["model": "m", "messages": [message]]
        let request = try ChatCompletionsCodec.parseRequest(body).value
        #expect(request.messages[0].parts == [.toolCall(WireToolCall(id: "call_1", name: "f", arguments: "{}", signature: "tsig"))])
        let encoded = ChatCompletionsCodec.buildRequest(request)
        #expect(encoded.warnings.isEmpty)
        #expect(encoded.json["messages"] == [message])
        // Another protocol's request: Chat has nowhere to put it.
        var foreign = request
        foreign.source = .anthropicMessages
        let dropped = ChatCompletionsCodec.buildRequest(foreign)
        #expect(dropped.json["messages"]?[0]?["tool_calls"]?[0]?["extra_content"] == nil)
        #expect(dropped.warnings.map(\.code) == [.droppedContent])
    }

    @Test func geminiMessageSignatureSignsTheText() throws {
        let body: JSONValue = [
            "id": "r", "object": "chat.completion", "created": 1, "model": "gemini-3",
            "choices": [["index": 0, "finish_reason": "stop", "message": [
                "role": "assistant", "content": "Sunny.",
                "extra_content": ["google": ["thought_signature": "msig"]],
            ]]],
        ]
        let response = try ChatCompletionsCodec.parseResponse(body, origin: "gemini").value
        #expect(response.message.parts == [.text(WireText("Sunny.", signature: "msig", origin: "gemini"))])
        #expect(response.message.extra.isEmpty)
        let encoded = ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == body.canonical)
    }

    // MARK: OpenRouter reasoning_details

    @Test func openRouterStreamDetailsCarrySignatureWithOrigin() throws {
        let (events, warnings) = try decodeChatStream(sse([
            chunk(#"{"role":"assistant","content":"","reasoning":"Think","reasoning_details":[{"type":"reasoning.text","text":"Think","format":"anthropic-claude-v1","index":0}]}"#),
            chunk(#"{"content":"","reasoning":"ing.","reasoning_details":[{"type":"reasoning.text","text":"ing.","format":"anthropic-claude-v1","index":0}]}"#),
            chunk(#"{"content":"","reasoning_details":[{"type":"reasoning.text","signature":"EqQB","format":"anthropic-claude-v1","index":0}]}"#),
            chunk(#"{"content":"","reasoning_details":[{"type":"reasoning.encrypted","data":"gAAAA","id":"rs_1","format":"openai-responses-v1","index":1}]}"#),
            chunk(#"{"content":"10"}"#, finish: #""stop""#),
        ]), origin: "openrouter")
        #expect(warnings.isEmpty, "\(warnings)")
        let message = WireResponseAccumulator(events).response.message
        #expect(message.parts == [
            .reasoning(WireReasoning(
                text: "Thinking.", signature: "EqQB", origin: "openrouter", sourceKey: "reasoning",
                extra: ["reasoning_details": ["type": "reasoning.text", "format": "anthropic-claude-v1", "index": 0]],
            )),
            .reasoning(WireReasoning(
                text: "", encrypted: "gAAAA", origin: "openrouter",
                extra: ["reasoning_details": ["type": "reasoning.encrypted", "id": "rs_1", "format": "openai-responses-v1", "index": 1]],
            )),
            .text(WireText("10")),
        ])

        let written = try deltas(expectStableStream(events, origin: "openrouter"))
        #expect(written.contains { $0 == ["reasoning": "Think", "reasoning_details": [["type": "reasoning.text", "format": "anthropic-claude-v1", "index": 0, "text": "Think"]]] })

        // The accumulated turn, as a Chat reply: OpenRouter's message shape.
        var response = WireResponseAccumulator(events).response
        response.source = .chatCompletions
        let reply = ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults)
        #expect(reply.warnings.isEmpty, "\(reply.warnings)")
        let replyMessage = reply.json["choices"]?[0]?["message"]
        #expect(replyMessage?["reasoning"] == "Thinking.")
        #expect(replyMessage?["reasoning_details"]?.arrayValue?.count == 2)
        #expect(replyMessage?["reasoning_details"]?[0]?["signature"] == "EqQB")

        // Replayed on an endpoint that trusts OpenRouter (its Messages API):
        // the signature reaches Anthropic.
        let request = WireRequest(model: "claude", messages: [
            WireMessage(role: .user, parts: [.text(WireText("Primes?"))]),
            WireMessage(role: .assistant, parts: Array(message.parts.prefix(1)) + [.text(WireText("10"))]),
        ])
        let anthropic = AnthropicMessagesCodec.buildRequest(request, options: AnthropicRequestOptions(trustedReasoningOrigins: ["openrouter"]))
        #expect(anthropic.json["messages"]?[1]?["content"]?[0] == ["type": "thinking", "thinking": "Thinking.", "signature": "EqQB"])
    }

    @Test func openRouterDetailsWithoutPlainFieldAccumulateText() throws {
        let (events, _) = try decodeChatStream(sse([
            chunk(#"{"reasoning_details":[{"type":"reasoning.summary","summary":"A","index":0}]}"#),
            chunk(#"{"reasoning_details":[{"type":"reasoning.summary","summary":"B","index":0}]}"#, finish: #""stop""#),
        ]), origin: "openrouter")
        #expect(WireResponseAccumulator(events).response.message.parts == [
            .reasoning(WireReasoning(text: "AB", extra: ["reasoning_details": ["type": "reasoning.summary", "index": 0]])),
        ])
        let written = try deltas(expectStableStream(events, origin: "openrouter"))
        #expect(!written.contains { $0["reasoning_content"] != nil })
    }

    @Test func openRouterNonStreamingDetailsAreTyped() throws {
        let body: JSONValue = [
            "id": "gen", "object": "chat.completion", "created": 1, "model": "openai/gpt-5-mini",
            "choices": [["index": 0, "finish_reason": "stop", "message": [
                "role": "assistant", "content": "Answer.", "reasoning": "Summary.",
                "reasoning_details": [
                    ["type": "reasoning.summary", "summary": "Summary.", "format": "openai-responses-v1", "index": 0],
                    ["type": "reasoning.encrypted", "data": "gAAAA", "id": "rs_1", "format": "openai-responses-v1", "index": 0],
                ],
            ]]],
        ]
        let response = try ChatCompletionsCodec.parseResponse(body, origin: "openrouter").value
        #expect(response.message.extra.isEmpty)
        #expect(response.message.parts.count == 3)
        #expect(response.message.parts[1] == .reasoning(WireReasoning(
            text: "", encrypted: "gAAAA", origin: "openrouter",
            extra: ["reasoning_details": ["type": "reasoning.encrypted", "id": "rs_1", "format": "openai-responses-v1", "index": 0]],
        )))
        let encoded = ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == body.canonical)

        // Details that disagree with the plain field stay in the bag.
        var mismatched = body
        if case .object(var root) = mismatched, case .array(var choices)? = root["choices"], case .object(var choice) = choices[0],
           case .object(var message)? = choice["message"]
        {
            message["reasoning"] = "Something else."
            choice["message"] = .object(message)
            choices[0] = .object(choice)
            root["choices"] = .array(choices)
            mismatched = .object(root)
        }
        let kept = try ChatCompletionsCodec.parseResponse(mismatched).value
        #expect(kept.message.extra["reasoning_details"] != nil)
        #expect(kept.message.parts.first == .reasoning(WireReasoning(text: "Something else.", sourceKey: "reasoning")))
    }

    @Test func kimiStripsTypedReasoningDetails() {
        let details = WireReasoning(
            text: "Thought.", signature: "sig", sourceKey: "reasoning",
            extra: ["reasoning_details": ["type": "reasoning.text", "index": 0]],
        )
        var request = WireRequest(model: "kimi-k2", messages: [
            WireMessage(role: .assistant, parts: [.reasoning(details), .text(WireText("Hi."))]),
        ], source: .chatCompletions)
        var warnings: [WireWarning] = []
        WireTransforms.stripForeignReasoning(&request, trusted: ["moonshot"], warnings: &warnings)
        #expect(request.messages[0].parts.first == .reasoning(WireReasoning(text: "Thought.", sourceKey: "reasoning")))
        #expect(warnings.map(\.code) == [.droppedContent])
    }

    // MARK: Mistral thinking parts

    @Test func mistralThinkingPartsAreReasoningAndRoundTrip() throws {
        let body: JSONValue = [
            "id": "m1", "object": "chat.completion", "created": 1, "model": "magistral-medium-latest",
            "choices": [["index": 0, "finish_reason": "stop", "message": [
                "role": "assistant", "tool_calls": nil,
                "content": [
                    ["type": "thinking", "thinking": [["type": "text", "text": "First."], ["type": "text", "text": " Second."]]],
                    ["type": "text", "text": "Answer."],
                ],
            ]]],
        ]
        let decoded = try ChatCompletionsCodec.parseResponse(body)
        #expect(decoded.warnings.allSatisfy { $0.code == .unknownField }, "\(decoded.warnings)")
        #expect(decoded.value.message.parts == [
            .reasoning(WireReasoning(text: "First.", summaryIndex: 0, sourceKey: "thinking")),
            .reasoning(WireReasoning(text: " Second.", summaryIndex: 1, sourceKey: "thinking")),
            .text(WireText("Answer.")),
        ])
        let encoded = ChatCompletionsCodec.encodeResponse(decoded.value, defaults: testDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == body.canonical)

        // Another protocol's reply: plain Chat reasoning.
        var foreign = decoded.value
        foreign.source = .anthropicMessages
        let message = ChatCompletionsCodec.encodeResponse(foreign, defaults: testDefaults).json["choices"]?[0]?["message"]
        #expect(message?["reasoning_content"] == "First. Second.")
        #expect(message?["content"] == [["type": "text", "text": "Answer."]])
    }

    @Test func mistralThinkingStreamKeepsItsShapeForChat() throws {
        let (events, _) = try decodeChatStream(sse([
            chunk(#"{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"Hmm."}]}]}"#),
            chunk(#"{"content":"Yes."}"#, finish: #""stop""#),
        ]))
        let written = try deltas(expectStableStream(events, origin: nil))
        #expect(written.contains { $0 == ["content": [["type": "thinking", "thinking": [["type": "text", "text": "Hmm."]]]]] })
    }

    // MARK: Gemini replies

    @Test func geminiReplyKeepsCandidateIndexAndAbsentParts() throws {
        let body: JSONValue = [
            "candidates": [["content": ["role": "model"], "finishReason": "MAX_TOKENS", "index": 0]],
            "modelVersion": "gemini-2.5-pro", "responseId": "r1",
        ]
        let response = try GeminiCodec.parseResponse(body).value
        #expect(response.message.contentForm == .absent)
        #expect(response.choiceExtra["index"] == 0)
        let encoded = GeminiCodec.encodeResponse(response, defaults: geminiDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == body.canonical)

        // Parts that were there, even empty, stay.
        let empty: JSONValue = [
            "candidates": [["content": ["role": "model", "parts": []], "finishReason": "STOP", "index": 0]],
            "modelVersion": "gemini-2.5-pro", "responseId": "r1",
        ]
        let again = GeminiCodec.encodeResponse(try GeminiCodec.parseResponse(empty).value, defaults: geminiDefaults)
        #expect(again.json.canonical == empty.canonical)
    }
}
