import Testing
@_spi(Wire) @testable import UnladenCore
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

    private func keys(_ value: JSONValue) -> Set<String> {
        switch value {
        case .array(let items): items.reduce(into: Set()) { $0.formUnion(keys($1)) }
        case .object(let object): object.reduce(into: Set(object.keys)) { $0.formUnion(keys($1.value)) }
        default: []
        }
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
                text: "Thinking.", signature: "EqQB", origin: "openrouter:anthropic-claude-v1", sourceKey: "reasoning",
                extra: ["reasoning_details": ["type": "reasoning.text", "format": "anthropic-claude-v1", "index": 0]],
            )),
            .reasoning(WireReasoning(
                text: "", encrypted: "gAAAA", origin: "openrouter:openai-responses-v1",
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

        // The origin names the format: an Anthropic endpoint configured to
        // trust OpenRouter's Claude signatures takes it…
        let request = WireRequest(model: "claude", messages: [
            WireMessage(role: .user, parts: [.text(WireText("Primes?"))]),
            WireMessage(role: .assistant, parts: Array(message.parts.prefix(1)) + [.text(WireText("10"))]),
        ])
        let trusting = AnthropicMessagesCodec.buildRequest(
            request, options: AnthropicRequestOptions(trustedReasoningOrigins: ["openrouter:anthropic-claude-v1"]),
        )
        #expect(trusting.json["messages"]?[1]?["content"]?[0] == ["type": "thinking", "thinking": "Thinking.", "signature": "EqQB"])
        // …OpenRouter's Messages endpoint by default (trusting `openrouter`) does not.
        let plain = AnthropicMessagesCodec.buildRequest(request, options: AnthropicRequestOptions(trustedReasoningOrigins: ["openrouter"]))
        #expect(!keys(plain.json).contains("signature"))
    }

    /// Another vendor's reasoning behind the same relay never reaches
    /// Anthropic: OpenAI encrypted data, a Gemini signature.
    @Test func openRouterOtherFormatsDoNotLeakToAnthropic() throws {
        func reply(_ details: JSONValue, model: String) throws -> WireMessage {
            let body: JSONValue = [
                "id": "gen", "object": "chat.completion", "created": 1, "model": .string(model),
                "choices": [["index": 0, "finish_reason": "stop", "message": [
                    "role": "assistant", "content": "Answer.", "reasoning_details": details,
                ]]],
            ]
            return try ChatCompletionsCodec.parseResponse(body, origin: "openrouter").value.message
        }
        let openAI = try reply([
            ["type": "reasoning.summary", "summary": "Summary.", "format": "openai-responses-v1", "index": 0],
            ["type": "reasoning.encrypted", "data": "gAAAA", "id": "rs_1", "format": "openai-responses-v1", "index": 0],
        ], model: "openai/gpt-5-mini")
        let gemini = try reply([
            ["type": "reasoning.text", "text": "Thought.", "signature": "GEMSIG", "format": "google-gemini-v1", "index": 0],
        ], model: "google/gemini-3-pro")
        let options = AnthropicRequestOptions(trustedReasoningOrigins: ["openrouter", "openrouter:anthropic-claude-v1"])
        for message in [openAI, gemini] {
            let request = WireRequest(model: "claude", messages: [
                WireMessage(role: .user, parts: [.text(WireText("Q?"))]), message,
                WireMessage(role: .user, parts: [.text(WireText("Again?"))]),
            ])
            let blocks = AnthropicMessagesCodec.buildRequest(request, options: options).json["messages"]?[1]?["content"]?.arrayValue ?? []
            #expect(!blocks.contains { $0["type"] == "redacted_thinking" || $0["signature"] == "GEMSIG" || $0["data"] == "gAAAA" })
        }
        // OpenRouter's own Chat API takes them all back.
        let request = WireRequest(model: "openai/gpt-5-mini", messages: [WireMessage(role: .user, parts: [.text(WireText("Q?"))]), openAI])
        let chat = ChatCompletionsCodec.buildRequest(request, options: ChatRequestOptions(trustedOrigins: ["openrouter"]))
        #expect(chat.json["messages"]?[1]?["reasoning_details"]?[1]?["data"] == "gAAAA")
        // An endpoint that does not trust it gets the text only.
        let untrusting = ChatCompletionsCodec.buildRequest(request).json["messages"]?[1]
        #expect(untrusting?["reasoning_details"]?.arrayValue?.count == 1)
        #expect(!keys(untrusting ?? nil).contains("data"))
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
            text: "", encrypted: "gAAAA", origin: "openrouter:openai-responses-v1",
            extra: ["reasoning_details": ["type": "reasoning.encrypted", "id": "rs_1", "format": "openai-responses-v1", "index": 0]],
        )))
        let encoded = ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        #expect(encoded.json.canonical == body.canonical)

        // The details are the reasoning; a plain field that disagrees is
        // only their spelling (as in streams).
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
        let typed = try ChatCompletionsCodec.parseResponse(mismatched).value
        #expect(typed.message.extra.isEmpty)
        #expect(typed.message.parts.first == .reasoning(WireReasoning(
            text: "Summary.", sourceKey: "reasoning",
            extra: ["reasoning_details": ["type": "reasoning.summary", "format": "openai-responses-v1", "index": 0]],
        )))
    }

    @Test func streamDetailsAreTheReasoningOverAPlainFieldThatDisagrees() throws {
        let (events, _) = try decodeChatStream(sse([
            chunk(#"{"role":"assistant","reasoning":"Hello","reasoning_details":[{"type":"reasoning.text","text":"Hello ","index":0}]}"#),
            chunk(#"{"content":"Hi"}"#, finish: #""stop""#),
        ]), origin: "openrouter")
        #expect(WireResponseAccumulator(events).response.message.parts.first == .reasoning(WireReasoning(
            text: "Hello ", sourceKey: "reasoning", extra: ["reasoning_details": ["type": "reasoning.text", "index": 0]],
        )))
    }

    @Test func plainFieldBesideEncryptedOnlyDetailsIsItsOwnReasoning() throws {
        let (events, _) = try decodeChatStream(sse([
            chunk(#"{"role":"assistant","reasoning":"","reasoning_details":[{"type":"reasoning.encrypted","data":"gAAAA","format":"openai-responses-v1","index":0}]}"#),
            chunk(#"{"reasoning":"Plain.","reasoning_details":[{"type":"reasoning.encrypted","data":"gAAAA","format":"openai-responses-v1","index":1}]}"#),
            chunk(#"{"content":"Hi"}"#, finish: #""stop""#),
        ]), origin: "openrouter")
        let parts = WireResponseAccumulator(events).response.message.parts
        // An empty plain field is no spelling hint.
        guard case .reasoning(let first) = parts.first else { Issue.record("\(parts)"); return }
        #expect(first.sourceKey == nil)
        #expect(first.encrypted == "gAAAA")
        #expect(parts.contains(.reasoning(WireReasoning(text: "Plain.", sourceKey: "reasoning"))))
    }

    @Test func interleavedDetailsKeepEachBlockAndItsLateSignature() throws {
        let (events, warnings) = try decodeChatStream(sse([
            chunk(#"{"role":"assistant","reasoning_details":[{"type":"reasoning.text","text":"A","format":"anthropic-claude-v1","index":0}]}"#),
            chunk(#"{"reasoning_details":[{"type":"reasoning.text","text":"B","format":"anthropic-claude-v1","index":1}]}"#),
            chunk(#"{"reasoning_details":[{"type":"reasoning.text","signature":"SIG0","format":"anthropic-claude-v1","index":0}]}"#),
            chunk(#"{"content":"Hi"}"#),
            chunk(#"{"reasoning_details":[{"type":"reasoning.text","signature":"LATE","format":"anthropic-claude-v1","index":1}]}"#, finish: #""stop""#),
        ]), origin: "openrouter")
        #expect(checkEventSequence(events) == [])
        let reasoning = WireResponseAccumulator(events).response.message.parts.compactMap { part -> WireReasoning? in
            if case .reasoning(let value) = part { value } else { nil }
        }
        #expect(reasoning.map(\.text) == ["A", "B"])
        #expect(reasoning.map(\.signature) == ["SIG0", nil])
        // A signature for a block already ended starts no empty block.
        #expect(warnings.map(\.code) == [.malformedStream])
        _ = try expectStableStream(events, origin: "openrouter")
    }

    /// A whole OpenRouter reply replayed as a Chat stream decodes back to
    /// the same turn.
    @Test func openRouterReplyReplayedAsAStream() throws {
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
        var warnings: [WireWarning] = []
        let events = WireEvents.of(response, protocolName: "chat", warnings: &warnings)
        let (elements, encodeWarnings) = encodeChatStream(events)
        #expect(encodeWarnings.isEmpty, "\(encodeWarnings)")
        let (again, _) = try decodeChatStream(elements, origin: "openrouter")
        #expect(WireResponseAccumulator(again).response.message.parts == response.message.parts)
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

    @Test func geminiMessageThoughtMarkerStaysInTheBag() throws {
        let body: JSONValue = [
            "id": "r", "object": "chat.completion", "created": 1, "model": "gemini-3",
            "choices": [["index": 0, "finish_reason": "stop", "message": [
                "role": "assistant", "content": "Thinking.",
                "extra_content": ["google": ["thought_signature": "msig", "thought": true]],
            ]]],
        ]
        let response = try ChatCompletionsCodec.parseResponse(body, origin: "gemini").value
        #expect(response.message.parts == [.text(WireText("Thinking.", signature: "msig", origin: "gemini"))])
        #expect(response.message.extra == ["extra_content": ["google": ["thought": true]]])
        let encoded = ChatCompletionsCodec.encodeResponse(response, defaults: testDefaults)
        #expect(encoded.json.canonical == body.canonical)
    }

    /// A whole Gemini reply replayed as a Chat stream (a stream client, a
    /// non-streaming upstream) keeps the text signature, which is on the
    /// text's start there.
    @Test func geminiReplySignatureSurvivesAsAStream() throws {
        let response = WireResponse(
            message: WireMessage(role: .assistant, parts: [.text(WireText("Sunny.", signature: "msig", origin: "gemini"))]),
            id: "r", model: "gemini-3", created: 1, finishReason: WireFinishReason(.stop, raw: "stop"), source: .chatCompletions,
        )
        let events: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(source: .chatCompletions)),
            .textStart(id: "t", text: WireText("", signature: "msig", origin: "gemini")),
            .textDelta(id: "t", delta: "Sunny."),
            .textEnd(id: "t", text: nil),
            .finish(WireFinish(reason: response.finishReason)),
        ]
        let written = try deltas(expectStableStream(events, origin: "gemini"))
        #expect(written.contains { $0["extra_content"] == ["google": ["thought_signature": "msig"]] })
    }

    /// Strict upstreams (Mistral) get no `extra_content`, typed or not.
    @Test func strictUnknownFieldsDropsTypedGeminiSignatures() throws {
        let body: JSONValue = [
            "model": "mistral-large-latest",
            "messages": [
                ["role": "user", "content": "weather?"],
                ["role": "assistant", "content": "Let me check.", "extra_content": ["google": ["thought_signature": "T"]], "tool_calls": [[
                    "id": "call_1", "type": "function", "function": ["name": "get_weather", "arguments": "{}"],
                    "extra_content": ["google": ["thought_signature": "SIG"]],
                ]]],
                ["role": "tool", "tool_call_id": "call_1", "content": "sunny"],
            ],
        ]
        var request = try ChatCompletionsCodec.parseRequest(body).value
        var warnings: [WireWarning] = []
        WireTransforms.stripUnknownFields(&request, target: .chatCompletions, warnings: &warnings)
        #expect(!keys(ChatCompletionsCodec.buildRequest(request).json).contains("extra_content"))
        #expect(warnings.filter { $0.code == .unsupportedByModel }.count == 2)
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
