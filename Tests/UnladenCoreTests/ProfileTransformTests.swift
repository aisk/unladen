import Testing
@_spi(Wire) import UnladenCore

private func call(_ id: String, _ name: String = "get_weather", arguments: String = #"{"city":"Paris"}"#) -> WirePart {
    .toolCall(WireToolCall(id: id, name: name, arguments: arguments))
}

private func result(_ id: String, _ text: String = "18°C") -> WirePart {
    .toolResult(WireToolResult(callID: id, content: [.text(WireText(text))]))
}

private func text(_ value: String) -> WirePart { .text(WireText(value)) }

private func user(_ value: String) -> WireMessage { WireMessage(role: .user, parts: [text(value)]) }

private func resultIDs(_ message: WireMessage) -> [String] {
    message.parts.compactMap { if case .toolResult(let r) = $0 { r.callID } else { nil } }
}

private func isSynthetic(_ part: WirePart) -> Bool {
    guard case .toolResult(let r) = part, r.isError == true, case .text(let t)? = r.content.first else { return false }
    return t.text == WireTransforms.interruptedResult
}

@Suite struct PairToolCallsTests {
    @Test func chatStyleSynthesizesMissingAndDropsOrphans() {
        var request = WireRequest(model: "m", messages: [
            user("Weather in Paris and Rome?"),
            WireMessage(role: .assistant, parts: [call("call_1"), call("call_2")]),
            WireMessage(role: .tool, parts: [result("call_1")]),
            WireMessage(role: .tool, parts: [result("call_9")]),
            user("And tomorrow?"),
        ], source: .chatCompletions)
        var warnings: [WireWarning] = []
        WireTransforms.pairToolCalls(&request, warnings: &warnings)
        #expect(request.messages.map(\.role) == [.user, .assistant, .tool, .tool, .user])
        #expect(resultIDs(request.messages[2]) == ["call_1"])
        #expect(resultIDs(request.messages[3]) == ["call_2"])
        #expect(isSynthetic(request.messages[3].parts[0]))
        #expect(warnings.count == 2)
        #expect(warnings.allSatisfy { $0.code == .adjusted })
    }

    @Test func anthropicStyleInsertsAfterTheLastResult() {
        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .assistant, parts: [text("Checking."), call("toolu_a"), call("toolu_b")]),
            WireMessage(role: .user, parts: [result("toolu_a"), text("Also, hurry.")]),
        ], source: .anthropicMessages)
        var warnings: [WireWarning] = []
        WireTransforms.pairToolCalls(&request, warnings: &warnings)
        #expect(request.messages.count == 2)
        #expect(resultIDs(request.messages[1]) == ["toolu_a", "toolu_b"])
        #expect(isSynthetic(request.messages[1].parts[1]))
        #expect(request.messages[1].parts[2] == text("Also, hurry."))
    }

    @Test func responsesSplitTurnIsLeftAlone() {
        let messages = [
            user("hi"),
            WireMessage(role: .assistant, parts: [call("c1")]),
            WireMessage(role: .assistant, parts: [call("c2")]),
            WireMessage(role: .item, parts: [result("c1")]),
            WireMessage(role: .item, parts: [result("c2")]),
            WireMessage(role: .assistant, parts: [text("Done.")]),
        ]
        var request = WireRequest(model: "m", messages: messages, source: .responses)
        var warnings: [WireWarning] = []
        WireTransforms.pairToolCalls(&request, warnings: &warnings)
        #expect(request.messages == messages)
        #expect(warnings.isEmpty)
    }

    @Test func trailingCallAndDuplicateResult() {
        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .assistant, parts: [call("a")]),
            WireMessage(role: .tool, parts: [result("a")]),
            WireMessage(role: .tool, parts: [result("a", "again")]),
            WireMessage(role: .assistant, parts: [call("b", "custom", arguments: "x")]),
        ], source: .chatCompletions)
        var warnings: [WireWarning] = []
        WireTransforms.pairToolCalls(&request, warnings: &warnings)
        #expect(request.messages.map(\.role) == [.assistant, .tool, .assistant, .tool])
        #expect(resultIDs(request.messages[3]) == ["b"])
        guard case .toolResult(let synthetic) = request.messages[3].parts[0] else { Issue.record("no result"); return }
        #expect(synthetic.name == "custom")
    }
}

@Suite struct ParameterTransformTests {
    @Test func dropsParamsOpenAIReasoningModelsReject() throws {
        let target = try ProviderRegistry.builtIn.resolve("openai/o3")
        var request = WireRequest(model: "o3", messages: [user("hi")])
        request.temperature = 0.7
        request.topP = 0.9
        request.seed = 1
        var warnings: [WireWarning] = []
        WireTransforms.dropUnsupportedParams(&request, profile: target.profile, warnings: &warnings)
        #expect(request.temperature == nil)
        #expect(request.topP == nil)
        #expect(request.seed == 1)
        #expect(warnings.map(\.path) == ["temperature", "top_p"])
    }

    @Test func anthropicThinkingDropsTemperatureAndTopK() throws {
        let profile = try ProviderRegistry.builtIn.resolve("anthropic/claude-sonnet-4-5").profile
        var request = WireRequest(model: "claude-sonnet-4-5", messages: [user("hi")])
        request.temperature = 0.5
        request.topK = 40
        request.topP = 0.95
        var plain = request
        var warnings: [WireWarning] = []
        WireTransforms.dropUnsupportedParams(&plain, profile: profile, warnings: &warnings)
        #expect(plain == request)

        request.reasoning = WireReasoningConfig(budgetTokens: 4096, enabled: true)
        WireTransforms.dropUnsupportedParams(&request, profile: profile, warnings: &warnings)
        #expect(request.temperature == nil)
        #expect(request.topK == nil)
        #expect(request.topP == 0.95)
    }

    @Test func capabilitiesDropToolsReasoningAndImages() {
        let profile = Profile(supportsReasoning: false, supportsTools: false, supportsImages: false, supportsTemperature: false)
        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .user, parts: [text("what is this"), .image(WireMedia(source: .url("https://x/y.png")))]),
        ])
        request.tools = [.function(WireFunctionTool(name: "f"))]
        request.toolChoice = .auto
        request.reasoning = WireReasoningConfig(effort: "high")
        request.temperature = 1
        var warnings: [WireWarning] = []
        WireTransforms.dropUnsupportedParams(&request, profile: profile, warnings: &warnings)
        #expect(request.tools == nil && request.toolChoice == nil && request.reasoning == nil && request.temperature == nil)
        #expect(request.messages[0].parts == [text("what is this")])
        #expect(warnings.count == 4)
    }

    @Test func clampsEffortLevels() {
        #expect(WireTransforms.clampEffort("xhigh", to: ["low", "medium", "high", "max"]) == "max")
        #expect(WireTransforms.clampEffort("max", to: ["low", "medium", "high"]) == "high")
        #expect(WireTransforms.clampEffort("minimal", to: ["low", "high"]) == "low")
        #expect(WireTransforms.clampEffort("medium", to: ["low", "high"]) == "high")
        #expect(WireTransforms.clampEffort("none", to: ["low", "high"]) == nil)
        #expect(WireTransforms.clampEffort("turbo", to: ["low"]) == "turbo")
    }

    @Test func effortProfileClampsAndConvertsBudgets() throws {
        let profile = try ProviderRegistry.builtIn.resolve("anthropic/claude-opus-4-6").profile
        var request = WireRequest(model: "m", messages: [user("hi")])
        request.reasoning = WireReasoningConfig(effort: "xhigh")
        var warnings: [WireWarning] = []
        WireTransforms.mapReasoningEffort(&request, profile: profile, warnings: &warnings)
        #expect(request.reasoning == WireReasoningConfig(effort: "max"))

        request.reasoning = WireReasoningConfig(budgetTokens: 8000, enabled: true)
        WireTransforms.mapReasoningEffort(&request, profile: profile, warnings: &warnings)
        #expect(request.reasoning == WireReasoningConfig(effort: "medium", enabled: true))

        request.reasoning = WireReasoningConfig(budgetTokens: 0)
        WireTransforms.mapReasoningEffort(&request, profile: profile, warnings: &warnings)
        #expect(request.reasoning == WireReasoningConfig(enabled: false))
    }

    @Test func budgetProfileConvertsEfforts() throws {
        let profile = try ProviderRegistry.builtIn.resolve("anthropic/claude-sonnet-4-5").profile
        var request = WireRequest(model: "m", messages: [user("hi")])
        request.reasoning = WireReasoningConfig(effort: "high", summary: "auto")
        var warnings: [WireWarning] = []
        WireTransforms.mapReasoningEffort(&request, profile: profile, warnings: &warnings)
        // Sonnet 4.5 has no output_config.effort: the level becomes a budget.
        #expect(request.reasoning == WireReasoningConfig(budgetTokens: 24000, enabled: true, summary: "auto"))

        request.reasoning = WireReasoningConfig(effort: "none")
        WireTransforms.mapReasoningEffort(&request, profile: profile, warnings: &warnings)
        #expect(request.reasoning == WireReasoningConfig(enabled: false))

        // Opus 4.5 keeps its (clamped) effort beside the budget.
        let opus = try ProviderRegistry.builtIn.resolve("anthropic/claude-opus-4-5").profile
        request.reasoning = WireReasoningConfig(effort: "xhigh")
        WireTransforms.mapReasoningEffort(&request, profile: opus, warnings: &warnings)
        #expect(request.reasoning == WireReasoningConfig(effort: "high", budgetTokens: 32000, enabled: true))
    }

    @Test func uncontrolledReasoningIsDropped() {
        var request = WireRequest(model: "grok-4", messages: [user("hi")])
        request.reasoning = WireReasoningConfig(effort: "low")
        var warnings: [WireWarning] = []
        WireTransforms.mapReasoningEffort(&request, profile: Profile(reasoningControl: .uncontrolled), warnings: &warnings)
        #expect(request.reasoning == nil)
        #expect(warnings.count == 1)
    }
}

@Suite struct MessageTransformTests {
    @Test func developerBecomesSystem() {
        var request = WireRequest(model: "m", messages: [WireMessage(role: .developer, parts: [text("Be brief.")]), user("hi")])
        WireTransforms.developerToSystem(&request)
        #expect(request.messages.map(\.role) == [.system, .user])
    }

    @Test func flattensTextOnlyContentToAString() throws {
        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .user, parts: [text("Line one"), text("Line two")], contentForm: .parts),
            WireMessage(role: .user, parts: [text("look"), .image(WireMedia(source: .url("https://x/y.png")))], contentForm: .parts),
        ], source: .chatCompletions)
        var warnings: [WireWarning] = []
        WireTransforms.flattenTextParts(&request, warnings: &warnings)
        #expect(request.messages[0].parts == [text("Line one\nLine two")])
        #expect(request.messages[0].contentForm == .string)
        #expect(request.messages[1].contentForm == .parts)
        let body = ChatCompletionsCodec.buildRequest(request).json
        #expect(body["messages"]?[0]?["content"] == "Line one\nLine two")
        #expect(body["messages"]?[1]?["content"]?.arrayValue?.count == 2)
    }

    @Test func replaysReasoningContentOnToolTurns() throws {
        var request = WireRequest(model: "deepseek-reasoner", messages: [
            user("Weather?"),
            WireMessage(role: .assistant, parts: [call("call_1")]),
            WireMessage(role: .tool, parts: [result("call_1")]),
            WireMessage(role: .assistant, parts: [text("18°C in Paris.")]),
            user("Thanks"),
            WireMessage(role: .assistant, parts: [text("You're welcome.")]),
        ], source: .chatCompletions)
        WireTransforms.replayReasoningContent(&request)
        let body = ChatCompletionsCodec.buildRequest(request).json
        #expect(body["messages"]?[1]?["reasoning_content"] == " ")
        // Continuing after the tool result: also needs it.
        #expect(body["messages"]?[3]?["reasoning_content"] == " ")
        // A turn after a new user message does not.
        #expect(body["messages"]?[5]?["reasoning_content"] == nil)

        // Existing reasoning is kept as is.
        var kept = WireRequest(model: "m", messages: [
            WireMessage(role: .assistant, parts: [.reasoning(WireReasoning(text: "Need the tool.")), call("c")]),
        ], source: .chatCompletions)
        let before = kept
        WireTransforms.replayReasoningContent(&kept)
        #expect(kept == before)
    }

    @Test func stripsForeignReasoningForKimi() throws {
        let signed = WireReasoning(text: "Thinking about it.", signature: "EqQBCkgIBRABGAIiQL", origin: "anthropic")
        var details = WireMessage(role: .assistant, parts: [text("Answer.")])
        details.extra["reasoning_details"] = [["type": "reasoning.text", "text": "MiMo thought.", "index": 0]]
        var request = WireRequest(model: "kimi-k2", messages: [
            WireMessage(role: .assistant, parts: [.reasoning(signed), text("Hi.")]),
            WireMessage(role: .assistant, parts: [.reasoning(WireReasoning(text: "", encrypted: "gAAAA", origin: "openai"))]),
            details,
        ], source: .chatCompletions)
        var warnings: [WireWarning] = []
        WireTransforms.stripForeignReasoning(&request, trusted: ["moonshot"], warnings: &warnings)
        #expect(request.messages[0].parts[0] == .reasoning(WireReasoning(text: "Thinking about it.")))
        #expect(request.messages[1].parts.isEmpty)
        #expect(request.messages[2].extra.isEmpty)
        #expect(request.messages[2].parts.first == .reasoning(WireReasoning(text: "MiMo thought.")))
        #expect(warnings.count == 3)
    }

    @Test func ensuresThinkingOnToolTurnsForDeepSeekAnthropic() throws {
        let target = try ProviderRegistry.builtIn.resolve("deepseek/deepseek-chat", preferring: .anthropicMessages)
        let request = WireRequest(model: "deepseek-chat", messages: [
            user("Weather?"),
            WireMessage(role: .assistant, parts: [call("toolu_1")]),
            WireMessage(role: .user, parts: [result("toolu_1")]),
            WireMessage(role: .assistant, parts: [.reasoning(WireReasoning(text: "", encrypted: "EmwKAhgB", origin: "anthropic")), text("18°C.")]),
        ], source: .anthropicMessages)
        let prepared = try UpstreamCall(target: target, apiKey: "k", transport: MockTransport { _, _ in fatalError() })
            .prepare(request, stream: false)
        let body = try JSONValue(parsing: prepared.body)
        let first = body["messages"]?[1]?["content"]
        #expect(first?[0] == ["type": "thinking", "thinking": " ", "signature": ""])
        #expect(first?[1]?["type"] == "tool_use")
        // Redacted thinking DeepSeek cannot read becomes a placeholder.
        #expect(body["messages"]?[3]?["content"]?[0] == ["type": "thinking", "thinking": " ", "signature": ""])
    }

    @Test func customToolsBecomeFunctionsAndComeBack() throws {
        let custom: JSONValue = [
            "type": "custom", "name": "apply_patch", "description": "Apply a patch.",
            "format": ["type": "grammar", "syntax": "lark", "definition": "start: /.+/"],
        ]
        var request = WireRequest(model: "m", messages: [
            user("fix it"),
            WireMessage(role: .assistant, parts: [.toolCall(WireToolCall(
                id: "call_1", name: "apply_patch", arguments: "*** Begin Patch\n*** End Patch", itemType: "custom_tool_call",
            ))]),
            WireMessage(role: .item, parts: [.toolResult(WireToolResult(
                callID: "call_1", content: [text("ok")], itemType: "custom_tool_call_output",
            ))]),
        ], source: .responses)
        request.tools = [.opaque(WireOpaque(protocol: .responses, value: custom))]
        request.toolChoice = .opaque(WireOpaque(protocol: .responses, value: ["type": "custom", "name": "apply_patch"]))
        var warnings: [WireWarning] = []
        let names = WireTransforms.customToolsToFunctions(&request, warnings: &warnings)
        #expect(names == ["apply_patch"])
        guard case .function(let function)? = request.tools?.first else { Issue.record("not a function"); return }
        #expect(function.parameters?["required"] == ["input"])
        #expect(function.parameters?["properties"]?["input"]?["description"]?.stringValue?.contains("start: /.+/") == true)
        #expect(request.toolChoice == .function("apply_patch"))
        guard case .toolCall(let history) = request.messages[1].parts[0] else { Issue.record("no call"); return }
        #expect(history.itemType == nil)
        #expect(history.arguments == #"{"input":"*** Begin Patch\n*** End Patch"}"#)

        // Reply: complete.
        let mapper = CustomToolReplyMapper(names: names)
        let reply = WireResponse(message: WireMessage(role: .assistant, parts: [.toolCall(WireToolCall(
            id: "call_2", name: "apply_patch", arguments: #"{"input":"PATCH"}"#,
        ))]))
        guard case .toolCall(let mapped) = mapper.map(reply).message.parts[0] else { Issue.record("no call"); return }
        #expect(mapped.itemType == "custom_tool_call")
        #expect(mapped.arguments == "PATCH")

        // Reply: streamed.
        var streaming = mapper
        var events: [WireEvent] = []
        for event: WireEvent in [
            .toolInputStart(id: "b", call: WireToolCall(id: "call_3", name: "apply_patch", arguments: "")),
            .toolInputDelta(id: "b", delta: #"{"input":"PA"#),
            .toolInputDelta(id: "b", delta: #"TCH"}"#),
            .toolInputEnd(id: "b"),
            .toolCall(id: "b", call: WireToolCall(id: "call_3", name: "apply_patch", arguments: #"{"input":"PATCH"}"#)),
        ] {
            events += streaming.map(event)
        }
        #expect(events == [
            .toolInputStart(id: "b", call: WireToolCall(id: "call_3", name: "apply_patch", arguments: "", itemType: "custom_tool_call")),
            .toolInputDelta(id: "b", delta: "PATCH"),
            .toolInputEnd(id: "b"),
            .toolCall(id: "b", call: WireToolCall(id: "call_3", name: "apply_patch", arguments: "PATCH", itemType: "custom_tool_call")),
        ])
    }

    @Test func registryOrderAndProtocolScope() {
        var request = WireRequest(model: "m", messages: [
            WireMessage(role: .developer, parts: [text("a"), text("b")]),
            WireMessage(role: .assistant, parts: [call("c")]),
        ], source: .chatCompletions)
        let endpoint = Endpoint(system: "x", apiProtocol: .responses, baseURL: "https://x/v1")
        // Responses target: flattening and reasoning replay do not apply.
        let outcome = ProfileTransform.apply(
            [.flattenTextParts, .replayReasoningContent, .pairToolCalls, .developerToSystem], to: &request,
            context: WireTransformContext(target: .responses, endpoint: endpoint, profile: Profile()),
        )
        #expect(request.messages[0].role == .system)
        #expect(request.messages[0].parts.count == 2)
        #expect(request.messages[1].parts.count == 1)
        #expect(request.messages.count == 3)
        #expect(outcome.warnings.count == 1)
    }
}
