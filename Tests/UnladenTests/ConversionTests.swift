import Testing
@_spi(Wire) import UnladenCore
@testable import Unladen

/// The semantic ↔ wire conversion: pure functions.
@Suite struct ConversionTests {
    @Test func semanticToWireIsLossless() throws {
        let request = ModelRequest(
            messages: [
                .system("Be brief."),
                .user([.text("Look:"), .image(Media(bytes: [1, 2, 3], mediaType: "image/png")), .file(Media(.fileID("file-1"), mediaType: "application/pdf", filename: "a.pdf"))]),
                .assistant([.refusal("No."), .toolCall(ToolCall(id: "c1", name: "f", arguments: ["x": 1]))]),
                .tool(ToolResult(callID: "c1", toolName: "f", output: [.text("done")], isError: true)),
            ],
            tools: [Tool(name: "f", description: "d", inputSchema: ["type": "object"], strict: true)],
            toolChoice: .tool("f"),
            settings: GenerationSettings(
                maxOutputTokens: 10, temperature: 0.7, topP: 0.9, topK: 3, frequencyPenalty: 0.1, presencePenalty: 0.2,
                stopSequences: ["x"], seed: 1,
                reasoning: ReasoningSettings(enabled: true, effort: .low, budgetTokens: 100, visibility: .summary("concise")),
                responseFormat: .jsonSchema(["type": "object"], name: "out", description: "o", strict: true),
                parallelToolCalls: false, user: "u", promptCacheKey: "k",
            ),
        )

        let wire = try WireConversion.request(request, model: "m")

        #expect(wire.model == "m")
        #expect(wire.source == nil) // built in code: encoders normalize for their protocol
        #expect(wire.messages.map(\.role) == [.system, .user, .assistant, .tool])
        #expect(wire.messages[1].parts[1] == .image(WireMedia(source: .base64("AQID"), mediaType: "image/png")))
        #expect(wire.messages[1].parts[2] == .file(WireMedia(source: .fileID("file-1"), mediaType: "application/pdf", filename: "a.pdf")))
        #expect(wire.messages[2].parts == [.refusal(WireRefusal("No.")), .toolCall(WireToolCall(id: "c1", name: "f", arguments: #"{"x":1}"#))])
        #expect(wire.messages[3].parts == [.toolResult(WireToolResult(callID: "c1", name: "f", content: [.text(WireText("done"))], isError: true))])
        #expect(wire.tools == [.function(WireFunctionTool(name: "f", description: "d", parameters: ["type": "object"], strict: true))])
        #expect(wire.toolChoice == .function("f"))
        #expect(wire.maxOutputTokens == 10)
        #expect(wire.temperature == 0.7)
        #expect(wire.topP == 0.9)
        #expect(wire.topK == 3)
        #expect(wire.frequencyPenalty == 0.1)
        #expect(wire.presencePenalty == 0.2)
        #expect(wire.stop == .multiple(["x"]))
        #expect(wire.seed == 1)
        #expect(wire.reasoning == WireReasoningConfig(effort: "low", budgetTokens: 100, enabled: true, summary: "concise"))
        #expect(wire.responseFormat == WireResponseFormat(kind: .jsonSchema, name: "out", description: "o", schema: ["type": "object"], strict: true))
        #expect(wire.parallelToolCalls == false)
        #expect(wire.user == "u")
        #expect(wire.promptCacheKey == "k")
    }

    @Test func replayTokensRoundTrip() throws {
        // An assistant turn as decoders produce it, fidelity data and all.
        let wire = WireMessage(role: .assistant, parts: [
            .reasoning(WireReasoning(text: "a", itemID: "rs_1", summaryIndex: 0, origin: "openai")),
            .reasoning(WireReasoning(text: "b", encrypted: "enc", itemID: "rs_1", summaryIndex: 1, origin: "openai")),
            .reasoning(WireReasoning(text: "", signature: "sig", origin: "anthropic", sourceKey: "content")),
            .text(WireText("hi", signature: "tsig", itemID: "msg_1", origin: "openai")),
            .refusal(WireRefusal("no", itemID: "msg_1", origin: "openai")),
            .toolCall(WireToolCall(id: "gemini_call_0", idSynthesized: true, name: "f", arguments: "{}", itemType: "custom_tool_call", itemID: "fc_1", signature: "csig", origin: "openai")),
        ])
        var warnings: [CallWarning] = []

        let message = WireConversion.message(wire, system: "openai", warnings: &warnings)
        let back = try WireConversion.wireMessage(message, path: "m")

        #expect(back == wire)
        #expect(warnings.isEmpty)
    }

    @Test func unknownContentIsDroppedWithAWarning() {
        let wire = WireMessage(role: .assistant, parts: [
            .opaque(WireOpaque(protocol: .anthropicMessages, value: ["type": "server_tool_use"])),
            .text(WireText("ok", extra: ["citations": []])),
        ])
        var warnings: [CallWarning] = []
        let message = WireConversion.message(wire, system: "anthropic", warnings: &warnings)
        #expect(message.content == [.text("ok")]) // bags are not kept
        #expect(warnings.map(\.code) == [.opaqueContent])
    }

    @Test func foreignReplayDataIsRemovedForTheTarget() {
        var warnings: [CallWarning] = []
        let history = [WireConversion.message(WireMessage(role: .assistant, parts: [
            .reasoning(WireReasoning(text: "think", signature: "sig", origin: "anthropic")),
            .text(WireText("hi")),
            .toolCall(WireToolCall(id: "c", name: "f", arguments: "{}", signature: "csig", origin: "anthropic")),
        ]), system: "anthropic", warnings: &warnings)]

        let kept = WireConversion.forTarget(history, trusted: ["anthropic"])
        #expect(kept.messages == history)
        #expect(kept.notices.isEmpty)

        let moved = WireConversion.forTarget(history, trusted: ["openai"])
        #expect(moved.messages[0].content == [.text("hi"), .toolCall(ToolCall(id: "c", name: "f", arguments: "{}"))])
        #expect(moved.notices.map(\.code) == [.replayDataDropped, .replayDataDropped])
    }

    @Test func invalidRequestsAreRejected() {
        #expect(throws: UnladenError.self) {
            try WireConversion.request(ModelRequest(messages: [.user([.toolCall(ToolCall(id: "c", name: "f", arguments: "{}"))])]), model: "m")
        }
        #expect(throws: UnladenError.self) {
            try WireConversion.request(ModelRequest(messages: [.user("x")], settings: GenerationSettings(temperature: .nan)), model: "m")
        }
    }

    @Test func deepMerge() {
        let merged = WireConversion.deepMerge(["a": ["b": 1, "c": 2], "d": [1]], ["a": ["c": nil, "e": 3], "d": [2], "f": ["g": nil]])
        #expect(merged == ["a": ["b": 1, "e": 3], "d": [2], "f": [:]])
    }
}
