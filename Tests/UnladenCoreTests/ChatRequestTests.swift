import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

private let requestFixtures = (try? Fixtures.names("Chat/requests", extension: "json")) ?? []

private func parseFixture(_ name: String) throws -> WireDecoded<WireRequest> {
    try ChatCompletionsCodec.parseRequest(Fixtures.bytes("Chat/requests/\(name)"))
}

@Suite struct ChatRequestRoundTripTests {
    @Test func fixturesExist() {
        #expect(requestFixtures.count >= 5)
    }

    @Test(arguments: requestFixtures)
    func sameProtocolRoundTripIsStructurallyEqual(_ name: String) throws {
        let original = try Fixtures.json("Chat/requests/\(name)")
        let decoded = try parseFixture(name)
        let built = ChatCompletionsCodec.buildRequest(decoded.value)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(built.json.canonical == original.canonical)
    }

    @Test(arguments: requestFixtures)
    func encodingIsDeterministicAndIdempotent(_ name: String) throws {
        let request = try parseFixture(name).value
        let first = ChatCompletionsCodec.buildRequest(request).body
        let second = ChatCompletionsCodec.buildRequest(request).body
        #expect(first == second)
        // Decoding our own output and encoding again yields the same bytes.
        let again = try ChatCompletionsCodec.parseRequest(first).value
        #expect(again == request)
        #expect(ChatCompletionsCodec.buildRequest(again).body == first)
    }

    @Test func knownOrderFixtureRoundTripsByteForByte() throws {
        let text = #"{"model":"m","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":true,"temperature":0.50,"x_vendor":{"a":1}}"#
        let request = try ChatCompletionsCodec.parseRequest(Array(text.utf8)).value
        #expect(String(decoding: ChatCompletionsCodec.buildRequest(request).body, as: UTF8.self) == text)
    }
}

@Suite struct ChatRequestDecodingTests {
    @Test func multiTurnToolsModel() throws {
        let decoded = try parseFixture("multi_turn_tools.json")
        let request = decoded.value
        #expect(decoded.warnings.isEmpty)
        #expect(request.source == .chatCompletions)
        #expect(request.model == "gpt-4.1")
        #expect(request.maxOutputTokens == 2048)
        #expect(request.spellings[.maxOutputTokens] == "max_completion_tokens")
        #expect(request.reasoning == WireReasoningConfig(effort: "low"))
        #expect(request.streamOptions == WireStreamOptions(includeUsage: true))
        #expect(request.toolChoice == .auto)
        #expect(request.parallelToolCalls == true)
        #expect(request.temperature == nil)
        #expect(request.messages.count == 6)

        let assistant = request.messages[2]
        #expect(assistant.role == .assistant)
        #expect(assistant.contentForm == .null)
        #expect(assistant.parts == [.toolCall(WireToolCall(
            id: "call_Xk2a9", name: "get_weather", arguments: #"{"city":"Paris","unit":"celsius"}"#,
        ))])
        #expect(request.messages[3] == WireMessage(role: .tool, parts: [.toolResult(WireToolResult(
            callID: "call_Xk2a9", content: [.text(WireText(#"{"temp":18,"condition":"cloudy"}"#))], contentForm: .string,
        ))]))
        guard case .function(let tool)? = request.tools?.first else {
            Issue.record("expected a function tool")
            return
        }
        #expect(tool.name == "get_weather")
        #expect(tool.strict == true)
    }

    @Test func toolArgumentsKeepTheirExactText() throws {
        let request = try parseFixture("parallel_tools.json").value
        let calls = request.messages[1].parts.compactMap { part -> String? in
            if case .toolCall(let call) = part { return call.arguments }
            return nil
        }
        #expect(calls == [#"{"city": "Tokyo"}"#, #"{"city":"Osaka" }"#])
        #expect(request.messages[1].contentForm == .string)
        #expect(request.toolChoice == .function("get_weather"))
        #expect(request.temperature?.literal == "0.70")
        #expect(request.topP?.literal == "1.0")
        #expect(request.stop == .multiple(["\n\nUser:", "<|end|>"]))
    }

    @Test func mediaPartsAreUnderstood() throws {
        let request = try parseFixture("images.json").value
        #expect(request.messages[0].role == .developer)
        let user = request.messages[1]
        #expect(user.extra == ["name": "alice"])
        #expect(user.parts.count == 5)
        #expect(user.parts[1] == .image(WireMedia(source: .url("https://example.com/cat.jpg"), detail: "high")))
        guard case .image(let inline) = user.parts[2] else {
            Issue.record("expected an image")
            return
        }
        #expect(inline.mediaType == "image/png")
        #expect(inline.source == .base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        #expect(user.parts[3] == .file(WireMedia(source: .base64("JVBERi0xLjQK"), mediaType: "application/pdf", filename: "report.pdf")))
        #expect(user.parts[4] == .file(WireMedia(source: .fileID("file-abc123"))))
        #expect(request.spellings[.maxOutputTokens] == "max_tokens")
        #expect(request.candidateCount == 1)
        #expect(request.user == "user-1234")
        #expect(request.store == false)
        #expect(request.extra == ["metadata": ["session": "s-1"]])
    }

    @Test func vendorExtrasGoToBagsAndOpaqueParts() throws {
        let decoded = try parseFixture("vendor_extras.json")
        let request = decoded.value
        #expect(Array(request.extra.keys) == [
            "provider", "top_k", "repetition_penalty", "frequency_penalty", "logprobs", "top_logprobs",
            "web_search_options", "transforms", "usage",
        ])
        #expect(request.extra["frequency_penalty"] == .null)
        #expect(request.spellings[.reasoning] == "reasoning")
        #expect(request.reasoning == WireReasoningConfig(effort: "high", visible: true))
        #expect(request.presencePenalty?.literal == "0")
        #expect(request.temperature?.literal == "1.0")
        #expect(request.stop == .single("###"))
        #expect(request.responseFormat?.kind == .jsonSchema)
        #expect(request.responseFormat?.name == "answer")
        #expect(request.toolChoice == .required)

        // A cache breakpoint is typed, not a bag key.
        #expect(request.messages[0].parts == [.text(WireText("You are terse.", cacheControl: WireCacheControl()))])
        // DeepSeek reasoning in history, refusal: null kept in the message bag.
        #expect(request.messages[2].parts == [
            .reasoning(WireReasoning(text: "Simple arithmetic: 4.", sourceKey: "reasoning_content")),
            .text(WireText("4")),
        ])
        #expect(request.messages[2].extra == ["refusal": nil])
        // Unknown part type kept as opaque.
        guard case .opaque(let audio) = request.messages[3].parts[0] else {
            Issue.record("expected an opaque part")
            return
        }
        #expect(audio.protocol == .chatCompletions)
        #expect(audio.value["type"] == "input_audio")
        #expect(request.messages[4].extra == ["prefix": true])

        // Tool-level bags and opaque tools.
        guard case .function(let calc)? = request.tools?.first, case .opaque? = request.tools?.last else {
            Issue.record("expected a function and an opaque tool")
            return
        }
        #expect(calc.extra == ["defer_loading": true])
        #expect(calc.envelopeExtra.isEmpty)
        #expect(calc.cacheControl == WireCacheControl())

        let codes = Set(decoded.warnings.map(\.code))
        #expect(codes == [.unknownField, .opaqueContent])
        #expect(decoded.warnings.contains { $0.path == "messages[3].content[0]" && $0.code == .opaqueContent })
        #expect(!decoded.warnings.contains { $0.path == "frequency_penalty" }, "null values are not unknown content")
    }

    @Test func presenceAndSynonymsAreTracked() throws {
        let request = try parseFixture("developer_and_nulls.json").value
        // Both spellings sent: the official one is the field, the other stays in the bag.
        #expect(request.spellings[.maxOutputTokens] == "max_completion_tokens")
        #expect(request.extra["max_tokens"] == 1000)
        #expect(request.extra["tool_choice"] == .null)
        #expect(request.toolChoice == nil)
        #expect(request.tools == [])
        #expect(request.stream == false)
        #expect(request.verbosity == "low")
        #expect(request.serviceTier == "flex")
        #expect(request.promptCacheKey == "thread-42")
        #expect(request.safetyIdentifier == "hash-1")
        #expect(request.messages[0].contentForm == .parts)
        #expect(request.messages[2].contentForm == .absent)
        #expect(request.messages[2].parts.first == .reasoning(WireReasoning(text: "Need to search first.", sourceKey: "reasoning")))
        #expect(request.messages[4].extra == ["tool_calls": []])
        #expect(request.messages[3].parts == [.toolResult(WireToolResult(callID: "call_a", content: [], contentForm: .string))])
    }
}

@Suite struct ChatRequestErrorTests {
    private func error(_ text: String) -> WireDecodingError? {
        do {
            _ = try ChatCompletionsCodec.parseRequest(Array(text.utf8))
            return nil
        } catch {
            return error
        }
    }

    @Test func invalidJSON() {
        guard case .invalidJSON? = error(#"{"model": "m", "messages": [}"#)?.kind else {
            Issue.record("expected invalidJSON")
            return
        }
    }

    @Test func missingRequiredFields() {
        #expect(error(#"{"messages": []}"#) == WireDecodingError(.missingField, path: "model"))
        #expect(error(#"{"model": "m"}"#) == WireDecodingError(.missingField, path: "messages"))
        #expect(error(#"{"model": "m", "messages": [{"content": "x"}]}"#) == WireDecodingError(.missingField, path: "messages[0].role"))
        #expect(error(#"{"model": "m", "messages": [{"role": "tool", "content": "x"}]}"#)
            == WireDecodingError(.missingField, path: "messages[0].tool_call_id"))
        #expect(error(#"{"model": "m", "messages": [{"role": "assistant", "tool_calls": [{"id": "c", "type": "function"}]}]}"#)
            == WireDecodingError(.missingField, path: "messages[0].tool_calls[0].function"))
    }

    @Test func wrongTypes() {
        #expect(error(#"[]"#) == WireDecodingError(.typeMismatch(expected: "an object"), path: ""))
        #expect(error(#"{"model": 1, "messages": []}"#) == WireDecodingError(.typeMismatch(expected: "a string"), path: "model"))
        #expect(error(#"{"model": "m", "messages": {}}"#) == WireDecodingError(.typeMismatch(expected: "an array"), path: "messages"))
        #expect(error(#"{"model": "m", "messages": [], "temperature": "hot"}"#)
            == WireDecodingError(.typeMismatch(expected: "a number"), path: "temperature"))
        #expect(error(#"{"model": "m", "messages": [], "max_tokens": 1.5}"#)
            == WireDecodingError(.typeMismatch(expected: "an integer"), path: "max_tokens"))
        #expect(error(#"{"model": "m", "messages": [{"role": "user", "content": 3}]}"#)
            == WireDecodingError(.typeMismatch(expected: "a string, an array or null"), path: "messages[0].content"))
        #expect(error(#"{"model": "m", "messages": [], "stop": [1]}"#)
            == WireDecodingError(.typeMismatch(expected: "a string"), path: "stop[0]"))
    }

    @Test func unknownContentNeverFails() throws {
        let text = #"{"model":"m","messages":[{"role":"critic","content":[{"type":"hologram","data":1},{"text":"no type"}]}],"weird":[1,2]}"#
        let decoded = try ChatCompletionsCodec.parseRequest(Array(text.utf8))
        #expect(decoded.value.messages[0].role == WireRole(rawValue: "critic"))
        #expect(decoded.warnings.count == 3)
        let built = ChatCompletionsCodec.buildRequest(decoded.value)
        #expect(built.json.canonical == (try JSONValue(parsing: text)).canonical)
    }
}

@Suite struct ChatRequestCrossProtocolTests {
    @Test func bagsAreDroppedWithWarningsForAnotherSource() throws {
        var request = try parseFixture("vendor_extras.json").value
        request.source = .anthropicMessages
        let built = ChatCompletionsCodec.buildRequest(request)
        #expect(built.json["provider"] == nil)
        #expect(built.json["frequency_penalty"] == nil)
        #expect(built.json["messages"]?[0]?["content"] == [["type": "text", "text": "You are terse."]])
        let dropped = built.warnings.filter { $0.code == .droppedField }.map(\.path)
        #expect(dropped.contains("provider"))
        #expect(dropped.contains("messages[0].content[0].cache_control"))
        #expect(!dropped.contains("frequency_penalty"), "dropping a null is not worth a warning")
        // The chat-sourced opaque part and tool are still the same protocol's.
        #expect(built.json["messages"]?[3]?["content"]?[0]?["type"] == "input_audio")
    }

    @Test func foreignContentIsDroppedOrMapped() {
        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .assistant, parts: [
                .reasoning(WireReasoning(text: "hmm", signature: "sig", origin: "anthropic")),
                .text(WireText("Calling.")),
                .toolCall(WireToolCall(id: "toolu_1", name: "f", arguments: "{}")),
            ]),
            WireMessage(role: .user, parts: [
                .toolResult(WireToolResult(callID: "toolu_1", content: [.text(WireText("ok"))], isError: true)),
                .text(WireText("Thanks")),
                .opaque(WireOpaque(protocol: .anthropicMessages, value: ["type": "document"])),
            ]),
        ], source: .anthropicMessages)
        request.instructions = [.text(WireText("Be brief."))]
        request.maxOutputTokens = 100
        request.topK = 5
        request.reasoning = WireReasoningConfig(budgetTokens: 1024, enabled: true)
        let built = ChatCompletionsCodec.buildRequest(request)
        let expected: JSONValue = [
            "model": "m",
            "messages": [
                ["role": "system", "content": "Be brief."],
                ["role": "assistant", "content": "Calling.", "reasoning_content": "hmm",
                 "tool_calls": [["id": "toolu_1", "type": "function", "function": ["name": "f", "arguments": "{}"]]]],
                ["role": "tool", "content": "ok", "tool_call_id": "toolu_1"],
                ["role": "user", "content": "Thanks"],
            ],
            "max_completion_tokens": 100,
        ]
        #expect(built.json == expected)
        let codes = built.warnings.map(\.code)
        #expect(codes.contains(.droppedContent)) // signature, opaque part
        #expect(codes.contains(.lossyConversion)) // is_error
        #expect(codes.contains(.droppedField)) // top_k, reasoning budget
    }
}
