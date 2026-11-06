import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

private let requestFixtures = (try? Fixtures.names("Anthropic/requests", extension: "json")) ?? []

private func parseFixture(_ name: String) throws -> WireDecoded<WireRequest> {
    try AnthropicMessagesCodec.parseRequest(Fixtures.bytes("Anthropic/requests/\(name)"))
}

private func parse(_ text: String) throws(WireDecodingError) -> WireDecoded<WireRequest> {
    try AnthropicMessagesCodec.parseRequest(Array(text.utf8))
}

@Suite struct AnthropicRequestRoundTripTests {
    @Test func fixturesExist() {
        #expect(requestFixtures.count >= 4)
    }

    @Test(arguments: requestFixtures)
    func sameProtocolRoundTripIsStructurallyEqual(_ name: String) throws {
        let original = try Fixtures.json("Anthropic/requests/\(name)")
        let decoded = try parseFixture(name)
        let built = AnthropicMessagesCodec.buildRequest(decoded.value)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(built.json.canonical == original.canonical)
    }

    @Test(arguments: requestFixtures)
    func encodingIsDeterministicAndIdempotent(_ name: String) throws {
        let request = try parseFixture(name).value
        let first = AnthropicMessagesCodec.buildRequest(request).body
        #expect(AnthropicMessagesCodec.buildRequest(request).body == first)
        let again = try AnthropicMessagesCodec.parseRequest(first).value
        #expect(again == request)
        #expect(AnthropicMessagesCodec.buildRequest(again).body == first)
    }

    @Test func knownOrderRoundTripsByteForByte() throws {
        let text = #"{"model":"m","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":true,"temperature":0.50,"x_vendor":{"a":1}}"#
        let request = try parse(text).value
        #expect(String(decoding: AnthropicMessagesCodec.buildRequest(request).body, as: UTF8.self) == text)
    }
}

@Suite struct AnthropicRequestDecodingTests {
    @Test func claudeCodeRequestModel() throws {
        let decoded = try parseFixture("claude_code.json")
        let request = decoded.value
        // cache_control, citations and known server blocks are not news.
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        #expect(request.source == .anthropicMessages)
        #expect(request.maxOutputTokens == 32000)
        #expect(request.user == "user_abc123_account_def_session_0f1e")
        #expect(request.reasoning == WireReasoningConfig(budgetTokens: 31999, enabled: true))
        #expect(request.stream == true)
        #expect(request.instructionsForm == .parts)
        #expect(request.instructions?.last == .text(WireText(
            "You are an interactive CLI tool that helps users with software engineering tasks.",
            extra: ["cache_control": ["type": "ephemeral"]],
        )))

        let first = request.messages[1].parts
        #expect(first[0] == .reasoning(WireReasoning(
            text: "The image is a single pixel. Then I need the weather tool.",
            signature: "EqQBCkYIBxgCKkDiM7w5FjTnL0rLoWq3sZcR8xGjS5qSyN7Hh9b0r3Q==",
        )))
        #expect(first[2] == .toolCall(WireToolCall(
            id: "toolu_01A09q90qw90lq917835lq9", name: "get_weather", arguments: #"{"city":"Paris","unit":"celsius"}"#,
        )))
        #expect(request.messages[2].parts == [.toolResult(WireToolResult(
            callID: "toolu_01A09q90qw90lq917835lq9", content: [.text(WireText("Service unavailable"))],
            contentForm: .parts, isError: true,
        ))])
        guard case .reasoning(let redacted) = request.messages[3].parts[0] else {
            Issue.record("expected redacted thinking")
            return
        }
        #expect(redacted.text.isEmpty)
        #expect(redacted.encrypted?.hasPrefix("EmwKAhgB") == true)
        #expect(redacted.origin == nil, "a client's request does not say where its signatures came from")

        let results = request.messages[4].parts
        #expect(results[0] == .toolResult(WireToolResult(callID: "toolu_01B", content: [.text(WireText(#"{"temp":18}"#))], contentForm: .string)))
        guard case .toolResult(let mixed) = results[1] else {
            Issue.record("expected a tool result")
            return
        }
        #expect(mixed.content.last == .image(WireMedia(source: .url("https://example.com/chart.png"))))
        guard case .opaque(let server) = request.messages[5].parts[0] else {
            Issue.record("expected an opaque server_tool_use block")
            return
        }
        #expect(server.protocol == .anthropicMessages)
        #expect(server.value["name"] == "web_search")
        guard case .text(let cited) = request.messages[5].parts[2] else {
            Issue.record("expected text")
            return
        }
        #expect(cited.extra.keys == ["citations"])

        guard case .function(let bash)? = request.tools?[1], case .opaque(let search)? = request.tools?[2] else {
            Issue.record("expected a function and a server tool")
            return
        }
        #expect(bash.extra == ["cache_control": ["type": "ephemeral"]])
        #expect(bash.parameters?["additionalProperties"] == false)
        #expect(search.value["type"] == "web_search_20250305")
    }

    @Test func stringFormsAndSettings() throws {
        let decoded = try parseFixture("simple_string.json")
        let request = decoded.value
        #expect(request.instructions == [.text(WireText("You are a poet."))])
        #expect(request.instructionsForm == .string)
        #expect(request.messages[1] == WireMessage(role: .assistant, parts: [.text(WireText("Waves fold into foam"))], contentForm: .string))
        #expect(request.stop == .multiple(["\n\nHuman:", "###"]))
        #expect(request.temperature?.literal == "0.70")
        #expect(request.topK?.literal == "40")
        #expect(request.topP?.literal == "0.9")
        #expect(request.serviceTier == "auto")
        #expect(request.toolChoice == .function("save_poem"))
        #expect(request.parallelToolCalls == false)
        guard case .function(let tool)? = request.tools?.first else {
            Issue.record("expected a function tool")
            return
        }
        #expect(tool.strict == true)
        #expect(tool.extra == ["type": "custom"])
        #expect(request.extra == ["anthropic_beta_flag": ["x": 1]])
        #expect(decoded.warnings.map(\.path) == ["anthropic_beta_flag"])
    }

    @Test func documentsAndAdaptiveThinking() throws {
        let decoded = try parseFixture("documents.json")
        let request = decoded.value
        #expect(request.reasoning == WireReasoningConfig(effort: "high", enabled: true))
        #expect(request.toolChoice == .required)
        #expect(request.parallelToolCalls == nil)
        let parts = request.messages[0].parts
        #expect(parts[0] == .file(WireMedia(
            source: .base64("JVBERi0xLjQK"), mediaType: "application/pdf", filename: "report.pdf",
            extra: ["context": "Quarterly report", "citations": ["enabled": true]],
        )))
        #expect(parts[1] == .file(WireMedia(source: .url("https://example.com/paper.pdf"))))
        #expect(parts[2] == .file(WireMedia(source: .fileID("file_011CNha8iCJcU1wXNR6q4V8w"))))
        guard case .opaque = parts[3], case .opaque = parts[6] else {
            Issue.record("text documents and search results are opaque")
            return
        }
        #expect(parts[5] == .image(WireMedia(source: .fileID("file_img"))))
        // The text document is the only unknown content; context_management a top-level unknown.
        #expect(decoded.warnings.map(\.path) == ["messages[0].content[3]", "context_management"])
    }

    @Test func presenceIsTracked() throws {
        let request = try parseFixture("thinking_disabled.json").value
        #expect(request.instructions == [])
        #expect(request.instructionsForm == .string)
        #expect(request.messages[1].contentForm == .parts)
        #expect(request.messages[2].contentForm == .string)
        #expect(request.reasoning == WireReasoningConfig(enabled: false))
        #expect(request.toolChoice == .auto)
        #expect(request.parallelToolCalls == true)
        #expect(request.tools == [])
        #expect(request.user == nil, "metadata with other keys stays whole in the bag")
        #expect(request.extra["metadata"] == ["user_id": "u", "extra": 1])
    }
}

@Suite struct AnthropicRequestErrorTests {
    private func error(_ text: String) -> WireDecodingError? {
        do {
            _ = try parse(text)
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
        #expect(error(#"{"model": "m", "messages": []}"#) == WireDecodingError(.missingField, path: "max_tokens"))
        #expect(error(#"{"messages": [], "max_tokens": 1}"#) == WireDecodingError(.missingField, path: "model"))
        #expect(error(#"{"model": "m", "max_tokens": 1}"#) == WireDecodingError(.missingField, path: "messages"))
        #expect(error(#"{"model": "m", "max_tokens": 1, "messages": [{"content": "x"}]}"#)
            == WireDecodingError(.missingField, path: "messages[0].role"))
    }

    @Test func wrongTypes() {
        #expect(error(#"{"model": "m", "messages": [], "max_tokens": null}"#)
            == WireDecodingError(.typeMismatch(expected: "an integer"), path: "max_tokens"))
        #expect(error(#"{"model": "m", "messages": [], "max_tokens": "5"}"#)
            == WireDecodingError(.typeMismatch(expected: "a number"), path: "max_tokens"))
        #expect(error(#"{"model": "m", "messages": [], "max_tokens": 1, "system": 3}"#)
            == WireDecodingError(.typeMismatch(expected: "a string or an array"), path: "system"))
        #expect(error(#"{"model": "m", "messages": [{"role": "user", "content": 3}], "max_tokens": 1}"#)
            == WireDecodingError(.typeMismatch(expected: "a string or an array"), path: "messages[0].content"))
        #expect(error(#"{"model": "m", "messages": [], "max_tokens": 1, "stop_sequences": [1]}"#)
            == WireDecodingError(.typeMismatch(expected: "a string"), path: "stop_sequences[0]"))
    }

    @Test func unknownContentNeverFails() throws {
        let text = #"{"model":"m","messages":[{"role":"user","content":[{"type":"hologram","data":1},{"text":"no type"}]}],"max_tokens":1,"thinking":{"type":"turbo"},"tool_choice":{"type":"auto","extra":1}}"#
        let decoded = try parse(text)
        #expect(decoded.value.reasoning == nil)
        guard case .opaque? = decoded.value.toolChoice else {
            Issue.record("expected an opaque tool choice")
            return
        }
        #expect(decoded.warnings.count == 4)
        let built = AnthropicMessagesCodec.buildRequest(decoded.value)
        #expect(built.json.canonical == (try JSONValue(parsing: text)).canonical)
    }
}

@Suite struct AnthropicRequestBuildTests {
    @Test func maxTokensComesFromTheOptions() {
        var request = WireRequest(model: "m", messages: [WireMessage(role: .user, parts: [.text(WireText("hi"))])])
        #expect(AnthropicMessagesCodec.buildRequest(request).json["max_tokens"] == 4096)
        #expect(AnthropicMessagesCodec.buildRequest(request, options: .init(defaultMaxTokens: 1000)).json["max_tokens"] == 1000)
        // max_tokens must exceed the thinking budget.
        request.reasoning = WireReasoningConfig(budgetTokens: 8000)
        let built = AnthropicMessagesCodec.buildRequest(request)
        #expect(built.json["max_tokens"] == 12096)
        #expect(built.json["thinking"] == ["type": "enabled", "budget_tokens": 8000])
        request.maxOutputTokens = 9000
        #expect(AnthropicMessagesCodec.buildRequest(request).json["max_tokens"] == 9000)
    }

    @Test func reasoningReplayFollowsTheTrustSet() {
        let request = WireRequest(model: "m", messages: [
            WireMessage(role: .assistant, parts: [
                .reasoning(WireReasoning(text: "a", signature: "sigA", origin: "anthropic")),
                .reasoning(WireReasoning(text: "b", signature: "sigB", origin: "google-vertex-anthropic")),
                .reasoning(WireReasoning(text: "", encrypted: "red", origin: "anthropic")),
                .text(WireText("done")),
            ]),
        ], source: .chatCompletions)
        let built = AnthropicMessagesCodec.buildRequest(request)
        #expect(built.json["messages"]?[0]?["content"] == [
            ["type": "thinking", "thinking": "a", "signature": "sigA"],
            ["type": "redacted_thinking", "data": "red"],
            ["type": "text", "text": "done"],
        ])
        #expect(built.warnings.map(\.code) == [.droppedContent])
        let trusting = AnthropicMessagesCodec.buildRequest(
            request, options: .init(trustedReasoningOrigins: ["anthropic", "google-vertex-anthropic"]),
        )
        #expect(trusting.json["messages"]?[0]?["content"]?.arrayValue?.count == 4)
    }

    @Test func toolChoiceAndParallelCalls() {
        var request = WireRequest(model: "m", messages: [], source: .chatCompletions)
        request.parallelToolCalls = false
        #expect(AnthropicMessagesCodec.buildRequest(request).json["tool_choice"] == ["type": "auto", "disable_parallel_tool_use": true])
        request.parallelToolCalls = true
        #expect(AnthropicMessagesCodec.buildRequest(request).json["tool_choice"] == nil)
        request.toolChoice = .required
        #expect(AnthropicMessagesCodec.buildRequest(request).json["tool_choice"] == ["type": "any", "disable_parallel_tool_use": false])
        request.toolChoice = WireToolChoice.none
        #expect(AnthropicMessagesCodec.buildRequest(request).json["tool_choice"] == ["type": "none"])
    }
}
