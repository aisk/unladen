import Testing
@_spi(Wire) import UnladenCore

private func anthropic(_ text: String) throws -> WireDecoded<WireRequest> {
    try AnthropicMessagesCodec.parseRequest(Array(text.utf8))
}

private func chat(_ text: String) throws -> WireDecoded<WireRequest> {
    try ChatCompletionsCodec.parseRequest(Array(text.utf8))
}

private func string(_ encoded: WireEncoded) -> String {
    String(decoding: encoded.body, as: UTF8.self)
}

/// `cache_control` as a typed wire field (``WireCacheControl``): lifted by
/// the Anthropic and Chat decoders, written by the Anthropic and Chat
/// encoders, dropped as a cache hint by Responses and Gemini.
@Suite struct CacheControlCodecTests {
    static let anthropicRequest = #"""
    {"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"doc","cache_control":{"type":"ephemeral"}},{"type":"image","source":{"type":"url","url":"https://e.x/a.png"},"cache_control":{"type":"ephemeral","ttl":"1h"}}]},{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"f","input":{},"cache_control":{"type":"ephemeral"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok","cache_control":{"type":"ephemeral"}}]}],"max_tokens":5,"system":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral","ttl":"1h"}}],"tools":[{"name":"f","input_schema":{"type":"object"},"cache_control":{"type":"ephemeral"}}]}
    """#

    // MARK: Anthropic

    @Test func anthropicLiftsBreakpointsAndWritesThemBackByteForByte() throws {
        let decoded = try anthropic(Self.anthropicRequest)
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        let request = decoded.value
        #expect(request.instructions == [.text(WireText("sys", cacheControl: WireCacheControl(ttl: "1h")))])
        #expect(request.messages[0].parts[0] == .text(WireText("doc", cacheControl: WireCacheControl())))
        #expect(request.messages[0].parts[1].cacheControl == WireCacheControl(ttl: "1h"))
        #expect(request.messages[1].parts[0].cacheControl == WireCacheControl())
        #expect(request.messages[2].parts[0].cacheControl == WireCacheControl())
        guard case .function(let tool)? = request.tools?.first else {
            Issue.record("expected a function tool")
            return
        }
        #expect(tool.cacheControl == WireCacheControl() && tool.extra.isEmpty)

        let built = AnthropicMessagesCodec.buildRequest(request)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(string(built) == Self.anthropicRequest)
    }

    /// Spellings the typed field could not reproduce stay in the bag, and
    /// still round-trip byte for byte.
    @Test func unusualSpellingsStayInTheBag() throws {
        let text = #"""
        {"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"a","cache_control":{"ttl":"1h","type":"ephemeral"}},{"type":"text","text":"b","cache_control":{"type":"ephemeral"},"x_after":1},{"type":"text","text":"c","cache_control":{"type":"persistent"}}]}],"max_tokens":5}
        """#
        let decoded = try anthropic(text)
        let parts = decoded.value.messages[0].parts
        #expect(parts.allSatisfy { $0.cacheControl == nil })
        guard case .text(let first) = parts[0], case .text(let second) = parts[1] else {
            Issue.record("expected text")
            return
        }
        #expect(first.extra.keys == ["cache_control"])
        #expect(second.extra.keys == ["cache_control", "x_after"])
        #expect(decoded.warnings.map(\.path) == ["messages[0].content[1].x_after"], "cache_control is never news")
        #expect(string(AnthropicMessagesCodec.buildRequest(decoded.value)) == text)
    }

    // MARK: Chat

    static let chatRequest = #"""
    {"model":"m","messages":[{"role":"system","content":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral"}}]},{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://e.x/a.png"},"cache_control":{"type":"ephemeral","ttl":"1h"}}]}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}},"cache_control":{"type":"ephemeral"}}]}
    """#

    @Test func chatLiftsBreakpointsAndWritesThemBackToChat() throws {
        let request = try chat(Self.chatRequest).value
        #expect(request.messages[0].parts == [.text(WireText("sys", cacheControl: WireCacheControl()))])
        #expect(request.messages[1].parts[0].cacheControl == WireCacheControl(ttl: "1h"))
        // Same protocol: written back unless the upstream is known not to take them.
        let same = ChatCompletionsCodec.buildRequest(request)
        #expect(same.warnings.isEmpty, "\(same.warnings)")
        #expect(string(same) == Self.chatRequest)
        #expect(string(ChatCompletionsCodec.buildRequest(request, options: ChatRequestOptions(cacheControl: true))) == Self.chatRequest)

        let refused = ChatCompletionsCodec.buildRequest(request, options: ChatRequestOptions(cacheControl: false))
        #expect(!string(refused).contains("cache_control"))
        #expect(refused.json["messages"]?[0]?["content"] == [["type": "text", "text": "sys"]], "the client's form is kept")
        #expect(refused.warnings.map(\.path) == [
            "messages[0].content[0].cache_control", "messages[1].content[0].cache_control", "tools[0].cache_control",
        ])
        #expect(refused.warnings.allSatisfy { $0.isCacheHint && !$0.isEscalatedWhenStrict })
    }

    /// An Anthropic request's breakpoints in a Chat request for a relay
    /// serving Claude: on content parts, on the last part of a tool
    /// message, on the tool envelope; none fits a tool call.
    @Test func anthropicBreakpointsTranslateToChat() throws {
        let request = try anthropic(Self.anthropicRequest).value
        let built = ChatCompletionsCodec.buildRequest(request, options: ChatRequestOptions(cacheControl: true))
        let ephemeral: JSONValue = ["type": "ephemeral"]
        let hour: JSONValue = ["type": "ephemeral", "ttl": "1h"]
        let messages = try #require(built.json["messages"]?.arrayValue)
        #expect(messages[0] == ["role": "system", "content": [["type": "text", "text": "sys", "cache_control": hour]]])
        #expect(messages[1]["content"] == [
            ["type": "text", "text": "doc", "cache_control": ephemeral],
            ["type": "image_url", "image_url": ["url": "https://e.x/a.png"], "cache_control": hour],
        ])
        #expect(messages[2]["tool_calls"]?[0]?["cache_control"] == nil)
        #expect(messages[3] == ["role": "tool", "content": [["type": "text", "text": "ok", "cache_control": ephemeral]], "tool_call_id": "toolu_1"])
        #expect(built.json["tools"]?[0]?["cache_control"] == ephemeral)
        #expect(built.warnings.map(\.path) == ["messages[1].tool_calls[0].cache_control"])
        #expect(built.warnings.allSatisfy { $0.isCacheHint })
    }

    @Test func chatBreakpointsTranslateToAnthropic() throws {
        let request = try chat(Self.chatRequest).value
        let built = AnthropicMessagesCodec.buildRequest(request)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(built.json["system"] == [["type": "text", "text": "sys", "cache_control": ["type": "ephemeral"]]])
        #expect(built.json["messages"]?[0]?["content"]?[0] == [
            "type": "image", "source": ["type": "url", "url": "https://e.x/a.png"], "cache_control": ["type": "ephemeral", "ttl": "1h"],
        ])
        #expect(built.json["tools"]?[0] == ["name": "f", "input_schema": ["type": "object"], "cache_control": ["type": "ephemeral"]])
    }

    // MARK: Protocols without breakpoints

    @Test func responsesAndGeminiDropBreakpointsAsCacheHints() throws {
        let request = try anthropic(Self.anthropicRequest).value
        let responses = ResponsesCodec.buildRequest(request)
        #expect(!string(responses).contains("cache_control"))
        #expect(responses.warnings.filter { $0.path.hasSuffix("cache_control") }.map(\.path) == [
            "instructions.cache_control", "input[0].content[0].cache_control", "input[0].content[1].cache_control",
            "input[1].content[0].cache_control", "input[2].content[0].cache_control", "tools[0].cache_control",
        ])
        let gemini = GeminiCodec.buildRequest(request)
        #expect(!string(gemini).contains("cache_control"))
        #expect(gemini.warnings.filter { $0.path.hasSuffix("cache_control") }.count == 6)
        for warning in responses.warnings + gemini.warnings where warning.path.hasSuffix("cache_control") {
            #expect(warning.code == .droppedField && warning.isCacheHint && !warning.isEscalatedWhenStrict)
        }
    }

    // MARK: Limit

    @Test func limitKeepsToolsInstructionsAndTheNewest() throws {
        var request = try anthropic(Self.anthropicRequest).value
        // tools[0], system[0], then messages newest first: 2, 1, 0.1, 0.0.
        var warnings: [WireWarning] = []
        WireTransforms.limitCacheBreakpoints(&request, max: 4, warnings: &warnings)
        #expect(warnings.map(\.path) == ["messages[0].content[1].cache_control", "messages[0].content[0].cache_control"])
        #expect(warnings.allSatisfy { $0.isCacheHint })
        #expect(request.messages[0].parts.allSatisfy { $0.cacheControl == nil })
        #expect(request.messages[1].parts[0].cacheControl != nil && request.messages[2].parts[0].cacheControl != nil)
        #expect(request.instructions?[0].cacheControl != nil)

        var within = try anthropic(Self.anthropicRequest).value
        let original = within
        warnings = []
        WireTransforms.limitCacheBreakpoints(&within, max: 6, warnings: &warnings)
        #expect(within == original && warnings.isEmpty)
    }

    @Test func profileLimitAppliesOnTheUpstreamCall() throws {
        let target = try ProviderRegistry.builtIn.resolve("anthropic/claude-sonnet-4-5")
        #expect(target.profile.maxCacheBreakpoints == 4)
        var request = try anthropic(Self.anthropicRequest).value
        request.messages[0].parts.append(.text(WireText("more", cacheControl: WireCacheControl())))
        let prepared = try UpstreamCall(target: target, apiKey: "k", transport: MockTransport { _, _ in fatalError() })
            .prepare(request, stream: false)
        let body = try JSONValue(parsing: prepared.body)
        let marks = String(decoding: prepared.body, as: UTF8.self).components(separatedBy: "cache_control").count - 1
        #expect(marks == 4)
        #expect(body["system"]?[0]?["cache_control"] != nil && body["tools"]?[0]?["cache_control"] != nil)
        #expect(prepared.warnings.filter(\.isCacheHint).count == 3)
    }

    // MARK: Patches

    @Test func patchesMergeForTheirProtocolOnly() {
        var object: JSONObject = ["type": "text", "text": "x", "nested": ["a": 1, "b": 2]]
        WirePatch(protocol: .chatCompletions, object: ["nested": ["b": nil, "c": 3], "type": "text", "extra": true]).apply(to: &object)
        #expect(object == ["type": "text", "text": "x", "nested": ["a": 1, "c": 3], "extra": true])

        let combined = WirePatch.combined(
            WirePatch(protocol: .gemini, object: ["a": ["x": 1], "b": 1]),
            WirePatch(protocol: .gemini, object: ["a": ["y": 2], "b": nil]),
        )
        #expect(combined?.object == ["a": ["x": 1, "y": 2], "b": nil], "a null survives to remove the key")

        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .user, parts: [.text(WireText("hi", patch: WirePatch(protocol: .gemini, object: ["thought": false])))]),
        ])
        request.messages[0].patch = WirePatch(protocol: .anthropicMessages, object: ["x": 1])
        let chat = ChatCompletionsCodec.buildRequest(request)
        #expect(chat.json["messages"] == [["role": "user", "content": "hi"]], "other protocols' patches are ignored")
        #expect(chat.warnings.isEmpty)
        let anthropic = AnthropicMessagesCodec.buildRequest(request)
        #expect(anthropic.json["messages"] == [["role": "user", "content": "hi", "x": 1]])
        let gemini = GeminiCodec.buildRequest(request)
        #expect(gemini.json["contents"] == [["parts": [["text": "hi", "thought": false]], "role": "user"]])
    }
}
