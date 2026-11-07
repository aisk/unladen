import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

@Suite struct ChatToAnthropicRequestTests {
    @Test func toolResultsAreRegroupedIntoUserTurns() throws {
        let chat = try ChatCompletionsCodec.parseRequest(Fixtures.bytes("Chat/requests/multi_turn_tools.json")).value
        let built = AnthropicMessagesCodec.buildRequest(chat)
        let messages = try #require(built.json["messages"]?.arrayValue)
        // Strict alternation, starting with the user.
        let roles = messages.compactMap { $0["role"]?.stringValue }
        #expect(roles.first == "user")
        for (a, b) in zip(roles, roles.dropFirst()) { #expect(a != b, "\(roles)") }
        // Every tool_use is answered first thing in the next user turn.
        for (i, message) in messages.enumerated() where message["role"] == "assistant" {
            let calls = (message["content"]?.arrayValue ?? []).filter { $0["type"] == "tool_use" }.compactMap { $0["id"]?.stringValue }
            guard !calls.isEmpty else { continue }
            let next = try #require(messages[i + 1]["content"]?.arrayValue)
            let answered = next.prefix(calls.count).compactMap { $0["tool_use_id"]?.stringValue }
            #expect(answered == calls)
        }
        #expect(built.json["system"] != nil)
        #expect(built.json["max_tokens"] == 2048)
    }

    @Test func chatShapesAreRestructured() {
        var request = WireRequest(model: "gpt", messages: [
            WireMessage(role: .system, parts: [.text(WireText("Be brief."))], contentForm: .string),
            WireMessage(role: .developer, parts: [.text(WireText("Use tools."))], contentForm: .string),
            WireMessage(role: .user, parts: [.text(WireText("Weather in Paris and Rome?"))], contentForm: .string),
            WireMessage(role: .assistant, parts: [
                .reasoning(WireReasoning(text: "Two calls.", sourceKey: "reasoning_content")),
                .toolCall(WireToolCall(id: "call_P", name: "w", arguments: #"{"c":"Paris"}"#)),
                .toolCall(WireToolCall(id: "call_R", name: "w", arguments: "")),
            ], contentForm: .null),
            WireMessage(role: .tool, parts: [.toolResult(WireToolResult(callID: "call_P", content: [.text(WireText("18C"))], contentForm: .string))]),
            WireMessage(role: .tool, parts: [.toolResult(WireToolResult(callID: "call_R", content: [], contentForm: .string))]),
            WireMessage(role: .user, parts: [.text(WireText("Thanks!"))], contentForm: .string),
            WireMessage(role: .user, parts: [.text(WireText(""))], contentForm: .string),
            WireMessage(role: .system, parts: [.text(WireText("Answer in French."))], contentForm: .string),
        ], source: .chatCompletions)
        request.stop = .single("END")
        request.user = "u-1"
        request.reasoning = WireReasoningConfig(effort: "low")
        request.seed = 7
        let built = AnthropicMessagesCodec.buildRequest(request)
        let expected: JSONValue = [
            "model": "gpt",
            "messages": [
                ["role": "user", "content": "Weather in Paris and Rome?"],
                ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "call_P", "name": "w", "input": ["c": "Paris"]],
                    ["type": "tool_use", "id": "call_R", "name": "w", "input": [:]],
                ]],
                ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "call_P", "content": "18C"],
                    ["type": "tool_result", "tool_use_id": "call_R"],
                    ["type": "text", "text": "Thanks!"],
                    ["type": "text", "text": "Answer in French."],
                ]],
            ],
            "max_tokens": 4096,
            "metadata": ["user_id": "u-1"],
            "output_config": ["effort": "low"],
            "stop_sequences": ["END"],
            "system": [["type": "text", "text": "Be brief."], ["type": "text", "text": "Use tools."]],
        ]
        #expect(built.json == expected)
        // Unsigned reasoning dropped, late system message demoted, seed dropped.
        #expect(built.warnings.map(\.code) == [.droppedContent, .lossyConversion, .droppedField])
    }

    @Test func foreignBagsAndOpaqueContentAreDropped() throws {
        let chat = try ChatCompletionsCodec.parseRequest(Fixtures.bytes("Chat/requests/vendor_extras.json")).value
        let built = AnthropicMessagesCodec.buildRequest(chat)
        #expect(built.json["provider"] == nil)
        #expect(
            built.json["system"] == [["type": "text", "text": "You are terse.", "cache_control": ["type": "ephemeral"]]],
            "a Chat breakpoint is typed, so Anthropic carries it",
        )
        #expect(built.json["tools"]?[0]?["cache_control"] == ["type": "ephemeral"])
        let dropped = built.warnings.map(\.path)
        #expect(dropped.contains("provider"))
        #expect(!dropped.contains { $0.hasSuffix("cache_control") })
        #expect(dropped.contains("messages[4].prefix"))
        #expect(dropped.contains("top_k"), "Chat keeps top_k in its bag, which is Chat's alone")
        #expect(built.warnings.contains { $0.code == .droppedContent && $0.path == "messages[3].content[0]" })
    }
}

@Suite struct AnthropicToChatRequestTests {
    @Test func claudeCodeRequestToChat() throws {
        let anthropic = try AnthropicMessagesCodec.parseRequest(Fixtures.bytes("Anthropic/requests/claude_code.json")).value
        let built = ChatCompletionsCodec.buildRequest(anthropic)
        let messages = try #require(built.json["messages"]?.arrayValue)
        #expect(messages.compactMap { $0["role"]?.stringValue } == [
            "system", "user", "assistant", "tool", "assistant", "tool", "tool", "user", "assistant", "user",
        ])
        #expect(messages[0]["content"]?.arrayValue?.count == 2)
        // Thinking text survives as reasoning_content; its signature does not.
        #expect(messages[2]["reasoning_content"] == "The image is a single pixel. Then I need the weather tool.")
        #expect(messages[2]["tool_calls"]?[0]?["function"]?["arguments"] == #"{"city":"Paris","unit":"celsius"}"#)
        #expect(messages[3] == ["role": "tool", "content": [["type": "text", "text": "Service unavailable"]], "tool_call_id": "toolu_01A09q90qw90lq917835lq9"])
        #expect(built.json["user"] == "user_abc123_account_def_session_0f1e")
        #expect(built.json["max_completion_tokens"] == 32000)
        let messagesOf = { (code: WireWarning.Code) in built.warnings.filter { $0.code == code }.map(\.message) }
        #expect(messagesOf(.droppedContent).contains("reasoning signature/encrypted data cannot be carried by Chat"))
        #expect(messagesOf(.lossyConversion).contains("Chat tool messages cannot mark an error"))
        #expect(built.warnings.contains { $0.path == "tools[2]" }, "server tools are dropped")
        #expect(built.warnings.contains { $0.path.hasSuffix("cache_control") })
    }
}

@Suite struct CrossProtocolStreamTests {
    @Test func anthropicStreamToChatClient() throws {
        let (events, _) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/thinking.sse"))
        let (elements, warnings) = encodeChatStream(events)
        #expect(checkChatStream(elements) == [])
        #expect(warnings.map(\.code) == [.droppedContent, .droppedContent], "signature and redacted data")
        let (decoded, _) = try decodeChatStream(elements)
        let accumulated = WireResponseAccumulator(decoded).response
        #expect(accumulated.message.parts == [
            .reasoning(WireReasoning(text: "2 plus 2 is 4.", sourceKey: "reasoning_content")),
            .text(WireText("The answer is 4.")),
        ])
        #expect(accumulated.finishReason == WireFinishReason(.stop, raw: "stop"))
        #expect(accumulated.usage?.inputTokens == 2160)
        #expect(accumulated.usage?.cachedInputTokens == 2048)
    }

    @Test func anthropicToolStreamToChatClient() throws {
        let (events, _) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/parallel_tools.sse"))
        let (elements, warnings) = encodeChatStream(events)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(checkChatStream(elements) == [])
        let (decoded, _) = try decodeChatStream(elements)
        let calls = decoded.compactMap { event -> WireToolCall? in
            if case .toolCall(_, let call) = event { return call }
            return nil
        }
        #expect(calls.map(\.id) == ["toolu_T", "toolu_O", "toolu_N"])
        #expect(calls.map(\.arguments) == [#"{"city":"Tokyo"}"#, #"{"city":"Osaka"}"#, "{}"])
    }

    @Test func chatStreamToAnthropicClient() throws {
        // Interleaved parallel tool calls are serialized into one block at a time.
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/parallel_tools.sse"))
        let (elements, warnings) = encodeAnthropicStream(events)
        #expect(checkAnthropicStream(elements) == [])
        #expect(warnings.map(\.path) == ["provider", "delta.native_finish_reason"], "OpenRouter's bags")
        let (decoded, decodeWarnings) = try decodeAnthropicStream(elements)
        #expect(decodeWarnings.isEmpty)
        #expect(checkEventSequence(decoded) == [])
        let response = WireResponseAccumulator(decoded).response
        #expect(response.id == "gen-1")
        #expect(response.message.parts == [
            .reasoning(WireReasoning(text: "Two cities, two calls.", origin: "anthropic")),
            .toolCall(WireToolCall(id: "call_T", name: "get_weather", arguments: #"{"city":"Tokyo"}"#)),
            .toolCall(WireToolCall(id: "call_O", name: "get_weather", arguments: #"{"city":"Osaka"}"#)),
        ])
        #expect(response.finishReason == WireFinishReason(.toolCalls, raw: "tool_use"))
        #expect(response.usage?.inputTokens == 80)
        #expect(response.usage?.cachedInputTokens == 64)
        #expect(response.usage?.outputTokens == 40)
    }

    @Test func chatRefusalAndErrorToAnthropicClient() throws {
        let (events, _) = try decodeChatStream(Fixtures.sse("Chat/streams/refusal_error.sse"))
        let (elements, warnings) = encodeAnthropicStream(events)
        #expect(checkAnthropicStream(elements) == [])
        #expect(warnings.map(\.code) == [.lossyConversion])
        let payloads = anthropicPayloads(elements)
        #expect(payloads.last?.name == "error")
        #expect(payloads.last?.json["error"] == ["type": "server_error", "message": "Upstream overloaded"])
        #expect(!payloads.contains { $0.name == "message_stop" })
    }

    @Test func foreignReasoningSignaturesAreNotForwarded() throws {
        let events: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(id: "r", source: .responses)),
            // Encrypted-only reasoning from another system: no block at all.
            .reasoningStart(id: "a", reasoning: WireReasoning(text: "", itemID: "rs_1", origin: "openai")),
            .reasoningEnd(id: "a", reasoning: WireReasoning(text: "", encrypted: "gAAAA", origin: "openai")),
            // Summary text from another system: thinking with an empty signature.
            .reasoningStart(id: "b", reasoning: WireReasoning(text: "", itemID: "rs_2", origin: "openai")),
            .reasoningDelta(id: "b", delta: "Summary."),
            .reasoningEnd(id: "b", reasoning: nil),
            .textStart(id: "c", text: WireText("", itemID: "msg_1", origin: "openai")),
            .textDelta(id: "c", delta: "Hi"),
            .textEnd(id: "c", text: nil),
            .finish(WireFinish(reason: WireFinishReason(.stop, raw: "completed"))),
        ]
        let (elements, warnings) = encodeAnthropicStream(events)
        #expect(checkAnthropicStream(elements) == [])
        #expect(warnings.map(\.code) == [.droppedContent])
        let blocks = anthropicPayloads(elements).filter { $0.name == "content_block_start" }.map { $0.json["content_block"] }
        #expect(blocks == [["type": "thinking", "thinking": "", "signature": ""], ["type": "text", "text": ""]])
    }
}
