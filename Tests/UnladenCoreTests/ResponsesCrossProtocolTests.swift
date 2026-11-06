import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

/// The next request a Responses client (Codex) sends: the reply's output
/// items echoed between two user turns.
private func echoRequest(_ output: [JSONValue]) -> JSONValue {
    let first: JSONValue = ["type": "message", "role": "user", "content": [["type": "input_text", "text": "What is 2+2?"]]]
    let next: JSONValue = ["type": "message", "role": "user", "content": [["type": "input_text", "text": "And 3+3?"]]]
    return ["model": "claude-sonnet-4-5", "input": .array([first] + output + [next]), "store": false, "stream": true]
}

@Suite struct ResponsesSignatureCarryingTests {
    @Test func anthropicThinkingSurvivesAResponsesClient() throws {
        // Claude streams thinking → the gateway answers a Responses client.
        let (events, _) = try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/thinking.sse"))
        let (elements, warnings) = encodeResponsesStream(events)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(checkResponsesStream(elements) == [])
        let output = try #require(finalResponse(elements)?["output"]?.arrayValue)
        #expect(output.map { $0["type"] } == ["reasoning", "reasoning", "message"])
        #expect(output[0]["summary"] == [["type": "summary_text", "text": "2 plus 2 is 4."]])
        #expect(output[1]["summary"] == [])
        #expect(output.prefix(2).allSatisfy { $0["encrypted_content"]?.stringValue?.hasPrefix(ResponsesSeal.prefix) == true })

        // The client echoes the items; the gateway sends them on to Claude.
        let request = try ResponsesCodec.parseRequest(echoRequest(output))
        #expect(request.warnings.isEmpty, "\(request.warnings)")
        let built = AnthropicMessagesCodec.buildRequest(request.value)
        #expect(!built.warnings.contains { $0.code == .droppedContent }, "\(built.warnings)")
        #expect(built.json["messages"] == [
            ["role": "user", "content": [["type": "text", "text": "What is 2+2?"]]],
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "2 plus 2 is 4.", "signature": "EqQBCkYIBxgCKkDsig=="],
                ["type": "redacted_thinking", "data": "EmwKAhgBEgyredacted"],
                ["type": "text", "text": "The answer is 4."],
            ]],
            ["role": "user", "content": [["type": "text", "text": "And 3+3?"]]],
        ])

        // Toward an OpenAI upstream the envelopes never leave the gateway.
        let openai = ResponsesCodec.buildRequest(request.value)
        #expect(!String(decoding: openai.body, as: UTF8.self).contains(ResponsesSeal.prefix))
        #expect(openai.warnings.filter { $0.code == .droppedContent }.count == 2)
        #expect(openai.json["input"]?.arrayValue?.map { $0["type"] } == ["message", "message", "message"])
    }

    @Test func nonStreamingRepliesSealToo() throws {
        let reply = try AnthropicMessagesCodec.parseResponse(Fixtures.bytes("Anthropic/responses/thinking_text.json")).value
        let encoded = ResponsesCodec.encodeResponse(reply, defaults: responsesDefaults)
        #expect(encoded.warnings.allSatisfy { $0.code == .droppedField }, "\(encoded.warnings)")
        let output = try #require(encoded.json["output"]?.arrayValue)
        let request = try ResponsesCodec.parseRequest(echoRequest(output)).value
        #expect(request.messages[1].parts == [
            .reasoning(WireReasoning(text: "2 plus 2 is 4.", signature: "EqQBCkYIBxgCKkDsig==", summaryIndex: 0, origin: "anthropic")),
        ])
        #expect(request.messages[2].parts == [
            .reasoning(WireReasoning(text: "", encrypted: "EmwKAhgBEgyredacted", origin: "anthropic")),
        ])
        // A Bedrock endpoint does not accept first-party signatures.
        let bedrock = AnthropicMessagesCodec.buildRequest(request, options: AnthropicRequestOptions(trustedReasoningOrigins: ["aws-bedrock"]))
        #expect(bedrock.json["messages"]?[1]?["content"] == [["type": "text", "text": "The answer is 4."]])
    }

    @Test func openAIReasoningPassesThroughRaw() throws {
        let (events, _) = try decodeResponsesStream(Fixtures.sse("Responses/streams/reasoning.sse"))
        let (elements, _) = encodeResponsesStream(events)
        let output = try #require(finalResponse(elements)?["output"]?.arrayValue)
        #expect(output[0]["encrypted_content"] == "gAAAAABoEncryptedReasoning==")
        let request = try ResponsesCodec.parseRequest(echoRequest(output)).value
        let built = ResponsesCodec.buildRequest(request)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(built.json["input"]?[1] == [
            "type": "reasoning", "id": "rs_reason",
            "summary": [["type": "summary_text", "text": "**Checking the math**"], ["type": "summary_text", "text": "2 + 2 is 4."]],
            "encrypted_content": "gAAAAABoEncryptedReasoning==",
        ])
        // Claude cannot use OpenAI's reasoning: dropped with a warning.
        let claude = AnthropicMessagesCodec.buildRequest(request)
        #expect(claude.json["messages"]?[1]?["content"] == [["type": "text", "text": "The answer is 4."]])
        #expect(claude.warnings.contains { $0.code == .droppedContent })
    }
}

@Suite struct ChatResponsesRequestTests {
    @Test func chatRequestToResponses() throws {
        let chat = try ChatCompletionsCodec.parseRequest(Fixtures.bytes("Chat/requests/multi_turn_tools.json")).value
        let built = ResponsesCodec.buildRequest(chat)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(built.json["input"] == [
            ["type": "message", "role": "system", "content": "You are a helpful assistant with access to weather tools."],
            ["type": "message", "role": "user", "content": "What's the weather in Paris?"],
            ["type": "function_call", "call_id": "call_Xk2a9", "name": "get_weather", "arguments": #"{"city":"Paris","unit":"celsius"}"#],
            ["type": "function_call_output", "call_id": "call_Xk2a9", "output": #"{"temp":18,"condition":"cloudy"}"#],
            ["type": "message", "role": "assistant", "content": "It's 18°C and cloudy in Paris."],
            ["type": "message", "role": "user", "content": "And tomorrow?"],
        ])
        #expect(built.json["max_output_tokens"] == 2048)
        #expect(built.json["reasoning"] == ["effort": "low"])
        #expect(built.json["stream_options"] == nil)
        let tools = try #require(built.json["tools"]?.arrayValue)
        #expect(tools[0]["type"] == "function")
        #expect(tools[0]["name"] == "get_weather")
        #expect(tools[0]["strict"] == true)
        #expect(tools[1]["strict"] == false, "Responses defaults strict to true")
    }

    @Test func codexRequestToChat() throws {
        let codex = try ResponsesCodec.parseRequest(Fixtures.bytes("Responses/requests/codex.json")).value
        let built = ChatCompletionsCodec.buildRequest(codex)
        let messages = try #require(built.json["messages"]?.arrayValue)
        #expect(messages.compactMap { $0["role"]?.stringValue } == [
            "system", "developer", "user", "assistant", "tool", "tool", "assistant", "tool", "assistant", "user",
        ])
        // One model turn: reasoning summary, text and both calls together.
        #expect(messages[3]["content"] == "Let me look at the tests.")
        #expect(messages[3]["reasoning_content"] == "**Inspecting tests****Planning the fix**")
        #expect(messages[3]["tool_calls"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["call_A", "call_B"])
        #expect(messages[4] == ["role": "tool", "content": "Package.swift\nSources\nTests", "tool_call_id": "call_A"])
        #expect(messages[2]["content"]?[1]?["image_url"] == ["url": "data:image/png;base64,iVBORw0KGgo=", "detail": "auto"])
        let codes = built.warnings.map(\.code)
        #expect(codes.contains(.lossyConversion), "custom tool call and joined reasoning")
        #expect(built.warnings.contains { $0.path == "include" })
        #expect(built.warnings.contains { $0.path == "tools[1]" }, "custom tools are dropped")
        #expect(built.warnings.contains { $0.message.contains("role-less item") })
    }

    @Test func codexRequestToAnthropic() throws {
        let codex = try ResponsesCodec.parseRequest(Fixtures.bytes("Responses/requests/codex.json")).value
        let built = AnthropicMessagesCodec.buildRequest(codex)
        let messages = try #require(built.json["messages"]?.arrayValue)
        let roles = messages.compactMap { $0["role"]?.stringValue }
        for (a, b) in zip(roles, roles.dropFirst()) { #expect(a != b, "\(roles)") }
        #expect(built.json["system"] == [
            ["type": "text", "text": "You are Codex, a coding agent running in a terminal."],
            ["type": "text", "text": "<permissions>workspace-write</permissions>"],
        ])
        #expect(messages[1]["content"]?.arrayValue?.compactMap { $0["type"]?.stringValue } == ["text", "tool_use", "tool_use"])
        #expect(messages[2]["content"]?[0]?["tool_use_id"] == "call_A")
        #expect(messages[2]["content"]?[1]?["content"] == [["type": "text", "text": "1 test failed"]])
        #expect(built.warnings.contains { $0.message == "reasoning from openai cannot be replayed to Anthropic" })
        #expect(built.json["thinking"] == nil)
        #expect(built.json["output_config"] == ["effort": "medium"])
    }
}

@Suite struct ResponsesCrossProtocolStreamTests {
    @Test func responsesStreamToChatClient() throws {
        let (events, _) = try decodeResponsesStream(Fixtures.sse("Responses/streams/reasoning.sse"))
        let (elements, warnings) = encodeChatStream(events)
        #expect(checkChatStream(elements) == [])
        // Besides the echoed request parameters (bags of another protocol):
        // the encrypted reasoning; item ids drop silently.
        #expect(warnings.filter { $0.code != .droppedField }.map(\.code) == [.droppedContent])
        let response = WireResponseAccumulator(try decodeChatStream(elements).events).response
        #expect(response.message.parts.last == .text(WireText("The answer is 4.")))
        #expect(response.usage?.reasoningTokens == 96)
    }

    @Test func responsesToolStreamToAnthropicClient() throws {
        let (events, _) = try decodeResponsesStream(Fixtures.sse("Responses/streams/parallel_tools.sse"))
        let (elements, warnings) = encodeAnthropicStream(events)
        #expect(checkAnthropicStream(elements) == [])
        #expect(warnings.filter { $0.code != .droppedField }.map(\.code) == [.droppedContent, .lossyConversion], "encrypted reasoning, custom call")
        let response = WireResponseAccumulator(try decodeAnthropicStream(elements).events).response
        let calls = response.message.parts.compactMap { part -> WireToolCall? in
            if case .toolCall(let call) = part { return call }
            return nil
        }
        #expect(calls.map(\.id) == ["call_T", "call_O", "call_P"])
        #expect(response.finishReason == WireFinishReason(.toolCalls, raw: "tool_use"))
    }

    @Test func responsesFailureToChatAndAnthropic() throws {
        let (events, _) = try decodeResponsesStream(Fixtures.sse("Responses/streams/failed.sse"))
        let (chat, _) = encodeChatStream(events)
        #expect(checkChatStream(chat) == [])
        #expect(chat.contains { if case .event(let event) = $0 { event.data.contains("The model failed.") } else { false } })
        let (anthropic, _) = encodeAnthropicStream(events)
        #expect(checkAnthropicStream(anthropic) == [])
        #expect(anthropicPayloads(anthropic).last?.name == "error")
    }
}

@Suite struct AnthropicToolIDTests {
    @Test func idsAreEncodedReversibly() {
        for id in ["call_A", "toolu_01A09q90qw90lq917835lq9", "functions.get_weather:0", "call|fc_1", "unl_abc", "ünïcode", "a b"] {
            let out = AnthropicToolID.outbound(id)
            #expect(AnthropicToolID.isValid(out), "\(id) → \(out)")
            #expect(AnthropicToolID.inbound(out) == id)
        }
        #expect(AnthropicToolID.outbound("call_A") == "call_A")
        #expect(AnthropicToolID.outbound("functions.get:0") == "unl_ZnVuY3Rpb25zLmdldDow")
        #expect(AnthropicToolID.inbound("unl_x") == "unl_x", "not an encoding")
        #expect(AnthropicToolID.inbound("toolu_1") == "toolu_1")
    }

    @Test func foreignCallIDsRoundTripThroughAnAnthropicClient() throws {
        // A Kimi-style call id from an upstream reaches a Claude Code client…
        let events: [WireEvent] = [
            .responseMetadata(WireResponseMetadata(id: "x", source: .chatCompletions)),
            .toolCall(id: "c", call: WireToolCall(id: "functions.read:0", name: "read", arguments: "{}")),
            .finish(WireFinish(reason: WireFinishReason(.toolCalls))),
        ]
        let (elements, _) = encodeAnthropicStream(events)
        let start = anthropicPayloads(elements).first { $0.name == "content_block_start" }?.json
        let sent = try #require(start?["content_block"]?["id"]?.stringValue)
        #expect(AnthropicToolID.isValid(sent))
        // …which answers with it; the gateway gives the upstream its own id back.
        let body: JSONValue = ["model": "m", "max_tokens": 10, "messages": [
            ["role": "user", "content": "go"],
            ["role": "assistant", "content": [["type": "tool_use", "id": .string(sent), "name": "read", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(sent), "content": "ok"]]],
        ]]
        let request = try AnthropicMessagesCodec.parseRequest(body).value
        #expect(request.messages[1].parts == [.toolCall(WireToolCall(id: "functions.read:0", name: "read", arguments: "{}"))])
        guard case .toolResult(let result) = request.messages[2].parts.first else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.callID == "functions.read:0")
        // Same protocol: the client's ids go back unchanged.
        #expect(AnthropicMessagesCodec.buildRequest(request).json.canonical == body.canonical)
        // And a Responses history with such ids is valid for Claude.
        let responses = WireRequest(model: "m", messages: [
            WireMessage(role: .assistant, parts: [.toolCall(WireToolCall(id: "call|1", name: "f", arguments: "{}"))]),
            WireMessage(role: .item, parts: [.toolResult(WireToolResult(callID: "call|1", content: [], contentForm: .string))]),
        ], source: .responses)
        let built = AnthropicMessagesCodec.buildRequest(responses)
        let id = try #require(built.json["messages"]?[0]?["content"]?[0]?["id"]?.stringValue)
        #expect(AnthropicToolID.isValid(id))
        #expect(built.json["messages"]?[1]?["content"]?[0]?["tool_use_id"]?.stringValue == id)
    }
}
