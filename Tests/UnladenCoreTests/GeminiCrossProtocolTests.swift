import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

private func toolCalls(_ parts: [WirePart]) -> [WireToolCall] {
    parts.compactMap { part in
        if case .toolCall(let call) = part { return call }
        return nil
    }
}

@Suite struct GeminiCrossProtocolRequestTests {
    @Test func chatRequestToGemini() throws {
        let chat = try ChatCompletionsCodec.parseRequest(Fixtures.bytes("Chat/requests/multi_turn_tools.json")).value
        let built = GeminiCodec.buildRequest(chat)
        #expect(built.warnings.map(\.path) == ["tools[0].strict"], "\(built.warnings)")
        #expect(built.json["systemInstruction"] == ["parts": [["text": "You are a helpful assistant with access to weather tools."]]])
        #expect(built.json["contents"] == [
            ["parts": [["text": "What's the weather in Paris?"]], "role": "user"],
            ["parts": [["functionCall": ["id": "call_Xk2a9", "name": "get_weather", "args": ["city": "Paris", "unit": "celsius"]]]], "role": "model"],
            ["parts": [["functionResponse": [
                "id": "call_Xk2a9", "name": "get_weather", "response": ["output": #"{"temp":18,"condition":"cloudy"}"#],
            ]]], "role": "user"],
            ["parts": [["text": "It's 18°C and cloudy in Paris."]], "role": "model"],
            ["parts": [["text": "And tomorrow?"]], "role": "user"],
        ])
        #expect(built.json["toolConfig"] == ["functionCallingConfig": ["mode": "AUTO"]])
        #expect(built.json["generationConfig"] == ["maxOutputTokens": 2048, "thinkingConfig": ["thinkingLevel": "low"]])
        let declarations = try #require(built.json["tools"]?[0]?["functionDeclarations"]?.arrayValue)
        #expect(declarations.count == 2)
        #expect(declarations[0]["parametersJsonSchema"]?["additionalProperties"] == false)
    }

    @Test func claudeCodeRequestToGemini() throws {
        let claude = try AnthropicMessagesCodec.parseRequest(Fixtures.bytes("Anthropic/requests/claude_code.json")).value
        let built = GeminiCodec.buildRequest(claude)
        let contents = try #require(built.json["contents"]?.arrayValue)
        let roles = contents.compactMap { $0["role"]?.stringValue }
        for (a, b) in zip(roles, roles.dropFirst()) { #expect(a != b, "\(roles)") }
        #expect(built.json["systemInstruction"]?["parts"]?.arrayValue?.isEmpty == false)
        let parts = contents.flatMap { $0["parts"]?.arrayValue ?? [] }
        #expect(parts.contains { $0["functionCall"]?["id"] == "toolu_01A09q90qw90lq917835lq9" })
        #expect(parts.contains { $0["functionResponse"]?["response"] == ["error": "Service unavailable"] })
        #expect(!parts.contains { $0["thought"] != nil }, "Claude's thinking cannot be replayed to Gemini")
        #expect(built.warnings.contains { $0.message.contains("reasoning from another protocol cannot be replayed to Gemini") })
        #expect(built.json["generationConfig"]?["thinkingConfig"] == ["includeThoughts": true, "thinkingBudget": 31999])
    }

    @Test func codexRequestToGemini() throws {
        let codex = try ResponsesCodec.parseRequest(Fixtures.bytes("Responses/requests/codex.json")).value
        let built = GeminiCodec.buildRequest(codex)
        let contents = try #require(built.json["contents"]?.arrayValue)
        let roles = contents.compactMap { $0["role"]?.stringValue }
        for (a, b) in zip(roles, roles.dropFirst()) { #expect(a != b, "\(roles)") }
        let responses = contents.flatMap { $0["parts"]?.arrayValue ?? [] }.compactMap { $0["functionResponse"] }
        #expect(responses.allSatisfy { $0["name"]?.stringValue?.isEmpty == false }, "names come from the calls")
        #expect(responses.map { $0["id"] } == ["call_A", "call_B", "call_C"])
    }

    @Test func geminiRequestToOtherProtocols() throws {
        let gemini = try parseGeminiRequest("gemini_cli.json").value

        let chat = ChatCompletionsCodec.buildRequest(gemini)
        let messages = try #require(chat.json["messages"]?.arrayValue)
        #expect(messages.compactMap { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool", "tool", "assistant", "user"])
        #expect(messages[2]["tool_calls"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["unladen_gc_1_1", "unladen_gc_1_2"])
        #expect(messages[3]["tool_call_id"] == "unladen_gc_1_1")
        #expect(messages[3]["content"] == "18°C, cloudy")
        #expect(messages[4]["content"]?[0]?["text"] == #"{"time":"14:05","dst":true}"#)
        #expect(chat.warnings.contains { $0.message == "tool call signature cannot be carried by Chat" })

        let claude = AnthropicMessagesCodec.buildRequest(gemini)
        let turns = try #require(claude.json["messages"]?.arrayValue)
        #expect(turns[1]["content"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["unladen_gc_1_1", "unladen_gc_1_2"])
        #expect(turns[2]["content"]?[0]?["tool_use_id"] == "unladen_gc_1_1")
        #expect(claude.json["system"] == [["type": "text", "text": "You are Gemini CLI, an interactive CLI agent specializing in software engineering tasks."]])

        let responses = ResponsesCodec.buildRequest(gemini)
        let items = try #require(responses.json["input"]?.arrayValue)
        #expect(items.compactMap { $0["call_id"]?.stringValue } == ["unladen_gc_1_1", "unladen_gc_1_2", "unladen_gc_1_1", "unladen_gc_1_2"])
    }
}

@Suite struct GeminiCrossProtocolStreamTests {
    @Test func geminiStreamsToOtherClients() throws {
        for name in ["text", "thoughts", "parallel_tools", "max_tokens", "safety"] {
            let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/\(name).sse"))
            #expect(checkChatStream(encodeChatStream(events).elements) == [], "\(name)")
            #expect(checkAnthropicStream(encodeAnthropicStream(events).elements) == [], "\(name)")
            #expect(checkResponsesStream(encodeResponsesStream(events).elements) == [], "\(name)")
        }
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/max_tokens.sse"))
        let chat = WireResponseAccumulator(try decodeChatStream(encodeChatStream(events).elements).events).response
        #expect(chat.finishReason?.unified == .length)
        #expect(chat.message.parts == [.text(WireText("Once upon a time, there was a"))])
    }

    @Test func otherStreamsToGeminiClient() throws {
        let sources: [(String, [WireEvent])] = [
            ("chat", try decodeChatStream(Fixtures.sse("Chat/streams/parallel_tools.sse")).events),
            ("anthropic", try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/thinking.sse")).events),
            ("anthropic tools", try decodeAnthropicStream(Fixtures.sse("Anthropic/streams/parallel_tools.sse")).events),
            ("responses", try decodeResponsesStream(Fixtures.sse("Responses/streams/reasoning.sse")).events),
            ("responses tools", try decodeResponsesStream(Fixtures.sse("Responses/streams/parallel_tools.sse")).events),
        ]
        for (name, events) in sources {
            let (elements, _) = encodeGeminiStream(events)
            #expect(checkGeminiStream(elements) == [], "\(name)")
            let (again, warnings) = try decodeGeminiStream(elements)
            #expect(warnings.isEmpty, "\(name): \(warnings)")
            #expect(checkEventSequence(again) == [], "\(name)")
        }
        // Claude's thinking reaches a Gemini client as thoughts, unsigned.
        let (thinking, warnings) = encodeGeminiStream(sources[1].1)
        let parts = geminiParts(thinking)
        #expect(parts.first == ["text": "2 plus 2", "thought": true])
        #expect(!parts.contains { $0["thoughtSignature"] != nil })
        #expect(warnings.map(\.code) == [.droppedContent, .droppedContent], "signature, redacted data")
        // Chat's interleaved parallel calls come out whole, with their ids.
        let calls = geminiParts(encodeGeminiStream(sources[0].1).elements).compactMap { $0["functionCall"] }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0["id"] != nil && $0["args"]?.objectValue != nil })
    }

    @Test func otherRepliesToGeminiClient() throws {
        let chat = try ChatCompletionsCodec.parseResponse(Fixtures.bytes("Chat/responses/tool_calls.json")).value
        let encoded = GeminiCodec.encodeResponse(chat, defaults: geminiDefaults)
        let parts = try #require(encoded.json["candidates"]?[0]?["content"]?["parts"]?.arrayValue)
        #expect(parts.contains { $0["functionCall"]?["id"] != nil })
        #expect(encoded.json["usageMetadata"]?["totalTokenCount"] != nil)
    }
}

@Suite struct GeminiToolIDRoundTripTests {
    @Test func synthesizedIdsNeverReachGemini() throws {
        // Gemini makes two id-less calls; a Chat client gets made-up ids…
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/parallel_tools.sse"))
        let (elements, warnings) = encodeChatStream(events)
        #expect(warnings.map(\.message) == ["tool call signature cannot be carried by Chat"])
        let reply = WireResponseAccumulator(try decodeChatStream(elements).events).response
        let ids = toolCalls(reply.message.parts).map(\.id)
        #expect(ids == ["unladen_gc_resp-P1_0", "unladen_gc_resp-P1_1"])

        // …and sends them back with its results.
        let body: JSONValue = ["model": "gemini-3-pro-preview", "messages": [
            ["role": "user", "content": "Weather and time in Paris?"],
            ["role": "assistant", "content": "Checking both.", "tool_calls": [
                ["id": .string(ids[0]), "type": "function", "function": ["name": "get_weather", "arguments": #"{"city":"Paris"}"#]],
                ["id": .string(ids[1]), "type": "function", "function": ["name": "get_time", "arguments": #"{"tz":"Europe/Paris"}"#]],
            ]],
            ["role": "tool", "tool_call_id": .string(ids[0]), "content": "18°C"],
            ["role": "tool", "tool_call_id": .string(ids[1]), "content": "14:05"],
        ]]
        let request = try ChatCompletionsCodec.parseRequest(body).value
        let options = GeminiRequestOptions(missingSignatureFallback: GeminiRequestOptions.skipSignatureValidator)
        let built = GeminiCodec.buildRequest(request, options: options)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(!String(decoding: built.body, as: UTF8.self).contains("unladen_gc_"))
        #expect(built.json["contents"] == [
            ["parts": [["text": "Weather and time in Paris?"]], "role": "user"],
            ["parts": [
                ["text": "Checking both."],
                ["functionCall": ["name": "get_weather", "args": ["city": "Paris"]], "thoughtSignature": "skip_thought_signature_validator"],
                ["functionCall": ["name": "get_time", "args": ["tz": "Europe/Paris"]], "thoughtSignature": "skip_thought_signature_validator"],
            ], "role": "model"],
            ["parts": [
                ["functionResponse": ["name": "get_weather", "response": ["output": "18°C"]]],
                ["functionResponse": ["name": "get_time", "response": ["output": "14:05"]]],
            ], "role": "user"],
        ])
    }
}

@Suite struct GeminiSignatureCarryingTests {
    /// What a Responses client (Codex) sends next: the reply's output items
    /// after the user turn, then the call outputs.
    private func echo(_ output: [JSONValue]) -> JSONValue {
        let user: JSONValue = ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Weather and time in Paris?"]]]
        let results: [JSONValue] = output.compactMap { item in
            guard item["type"] == "function_call", let id = item["call_id"] else { return nil }
            return ["type": "function_call_output", "call_id": id, "output": item["name"] == "get_weather" ? "18°C" : "14:05"]
        }
        return ["model": "gemini-3-pro-preview", "input": .array([user] + output + results), "store": false, "stream": true]
    }

    private let expectedContents: JSONValue = [
        ["parts": [["text": "Weather and time in Paris?"]], "role": "user"],
        ["parts": [
            ["text": "Checking both."],
            ["functionCall": ["name": "get_weather", "args": ["city": "Paris"]], "thoughtSignature": "sigCallFirst=="],
            ["functionCall": ["name": "get_time", "args": ["tz": "Europe/Paris"]]],
        ], "role": "model"],
        ["parts": [
            ["functionResponse": ["name": "get_weather", "response": ["output": "18°C"]]],
            ["functionResponse": ["name": "get_time", "response": ["output": "14:05"]]],
        ], "role": "user"],
    ]

    @Test func callSignatureSurvivesAResponsesClient() throws {
        // Gemini 3 signs its first call → the gateway answers a Responses client.
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/parallel_tools.sse"))
        let (elements, warnings) = encodeResponsesStream(events)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(checkResponsesStream(elements) == [])
        let output = try #require(finalResponse(elements)?["output"]?.arrayValue)
        #expect(output.map { $0["type"] } == ["message", "reasoning", "function_call", "function_call"])
        #expect(output[1]["summary"] == [])
        let sealed = try #require(output[1]["encrypted_content"]?.stringValue)
        #expect(ResponsesSeal.open(sealed) == .sealed(ResponsesSeal.Contents(
            origin: "gemini", signature: "sigCallFirst==", target: ResponsesSeal.callTarget,
        )))

        // The client echoes the items; the signature goes back on its call.
        let request = try ResponsesCodec.parseRequest(echo(output))
        #expect(request.warnings.isEmpty, "\(request.warnings)")
        let calls = request.value.messages.flatMap { toolCalls($0.parts) }
        #expect(calls.map(\.signature) == ["sigCallFirst==", nil])
        #expect(calls[0].origin == "gemini")
        #expect(calls[0].itemID == nil)
        let built = GeminiCodec.buildRequest(request.value)
        #expect(built.warnings.allSatisfy { $0.code == .droppedField }, "item statuses, store: \(built.warnings)")
        #expect(built.json["contents"] == expectedContents)

        // Toward an OpenAI upstream the envelope never leaves the gateway.
        let openai = ResponsesCodec.buildRequest(request.value)
        #expect(!String(decoding: openai.body, as: UTF8.self).contains(ResponsesSeal.prefix))
        #expect(openai.warnings.map(\.message) == ["tool call signature cannot be carried by Responses"])
    }

    @Test func nonStreamingRepliesSealToo() throws {
        let reply = try GeminiCodec.parseResponse(Fixtures.bytes("Gemini/responses/parallel_tools.json")).value
        let encoded = ResponsesCodec.encodeResponse(reply, defaults: responsesDefaults)
        #expect(encoded.warnings.isEmpty, "\(encoded.warnings)")
        let output = try #require(encoded.json["output"]?.arrayValue)
        #expect(output.map { $0["type"] } == ["message", "reasoning", "function_call", "function_call"])
        let request = try ResponsesCodec.parseRequest(echo(output)).value
        #expect(GeminiCodec.buildRequest(request).json["contents"] == expectedContents)
    }

    @Test func thoughtSignaturesRideTheExistingSeal() throws {
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/thoughts.sse"))
        let (elements, _) = encodeResponsesStream(events)
        let output = try #require(finalResponse(elements)?["output"]?.arrayValue)
        #expect(output.map { $0["type"] } == ["reasoning", "message"])
        let request = try ResponsesCodec.parseRequest(echo(output)).value
        #expect(request.messages[1].parts == [.reasoning(WireReasoning(
            text: "**Planning**\nI will add the numbers.", signature: "sigThought==", summaryIndex: 0, origin: "gemini",
        ))])
        let built = GeminiCodec.buildRequest(request)
        #expect(built.json["contents"]?[1]?["parts"]?[0] == [
            "text": "**Planning**\nI will add the numbers.", "thought": true, "thoughtSignature": "sigThought==",
        ])
    }

    @Test func strayEnvelopeIsDropped() throws {
        let envelope = ResponsesSeal.seal(ResponsesSeal.Contents(origin: "gemini", signature: "s", target: ResponsesSeal.callTarget))
        let body: JSONValue = ["model": "m", "input": [
            ["type": "reasoning", "summary": [], "encrypted_content": .string(envelope)],
            ["type": "message", "role": "user", "content": "hi"],
        ]]
        let decoded = try ResponsesCodec.parseRequest(body)
        #expect(decoded.value.messages.count == 1)
        #expect(decoded.warnings.map(\.message) == ["sealed tool call signature without its call dropped"])
    }

    @Test func anthropicAndChatClientsDropCallSignatures() throws {
        let (events, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/parallel_tools.sse"))
        let anthropic = encodeAnthropicStream(events)
        #expect(anthropic.warnings.map(\.message) == ["tool call signature cannot be carried by Anthropic"])
        let chat = encodeChatStream(events)
        #expect(chat.warnings.map(\.message) == ["tool call signature cannot be carried by Chat"])
        // A text signature cannot ride a Responses client (Gemini does not require it back).
        let (text, _) = try decodeGeminiStream(Fixtures.sse("Gemini/streams/text.sse"))
        #expect(encodeResponsesStream(text).warnings.filter { $0.code != .droppedField }.map(\.message) == [
            "text signature cannot be carried by Responses",
        ])
    }
}
