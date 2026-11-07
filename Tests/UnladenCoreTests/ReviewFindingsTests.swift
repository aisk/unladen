import HTTPTypes
import Testing
@_spi(Wire) import UnladenCore

/// Whether `body` throws ``ModelReferenceError/invalidModelID(_:reason:)``.
private func rejectsModelID(_ body: () throws(ModelReferenceError) -> ResolvedModel) -> Bool {
    do {
        _ = try body()
        return false
    } catch {
        if case .invalidModelID = error { return true }
        return false
    }
}

/// Model ids are validated when a reference is resolved: nothing that can
/// leave the model's place in an upstream URL gets through.
@Suite struct ModelIDValidationTests {
    let registry = ProviderRegistry.builtIn

    @Test(arguments: [
        "gemini/../../v1beta/cachedContents?key=EVIL#",
        "gemini/gemini-2.5-flash?alt=json",
        "gemini/gemini-2.5-flash#x",
        "gemini/a/b",
        "openai/gpt-4o\r\nX-Injected: 1",
        "openai/gpt 4o",
        "openai/gpt-4o\t",
        "openai/..",
        "openai/../gpt-4o",
        "openai/gpt-4o/..",
        "openai/./gpt-4o",
        "openai/gpt\\4o",
        "openai/gpt-4o\u{7F}",
        "openrouter/anthropic//claude-sonnet-4-5",
        "openrouter/anthropic/claude-sonnet-4-5?x=1",
    ])
    func rejected(_ reference: String) {
        #expect(rejectsModelID { () throws(ModelReferenceError) in try registry.resolve(reference) }, "\(reference)")
    }

    @Test(arguments: [
        "openai/gpt-4o",
        "openai/gpt-5.2",
        "openrouter/anthropic/claude-sonnet-4-5",
        "openrouter/meta-llama/llama-3.3-70b-instruct:free",
        "gemini/gemini-2.5-flash",
        "gemini/models/gemini-2.5-flash",
        "together/meta-llama/Llama-3.3-70B-Instruct-Turbo",
        "ollama/llama3.2:latest",
    ])
    func accepted(_ reference: String) throws {
        _ = try registry.resolve(reference)
    }

    @Test func providerResolveValidatesToo() {
        let gemini = Presets.gemini
        #expect(rejectsModelID { () throws(ModelReferenceError) in try gemini.resolve(model: "../cachedContents") })
    }
}

@Suite struct GeminiPathEncodingTests {
    @Test func modelSegmentIsPercentEncoded() {
        #expect(GeminiCodec.path(model: "gemini-2.5-flash", stream: false) == "/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(GeminiCodec.path(model: "models/gemini-2.5-flash", stream: true) == "/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        let evil = GeminiCodec.path(model: "../../v1beta/cachedContents?key=EVIL#", stream: false)
        #expect(evil == "/v1beta/models/..%2F..%2Fv1beta%2FcachedContents%3Fkey%3DEVIL%23:generateContent")
        #expect(!evil.contains("?") && !evil.contains("#"))
    }

    /// A hand-built ``ResolvedModel`` skips reference validation; the
    /// request path is still safe.
    @Test func handBuiltTargetCannotEscapeTheModelSegment() throws {
        let target = ResolvedModel(
            provider: "gemini", model: "../../v1beta/cachedContents?key=EVIL#",
            endpoint: Presets.gemini.endpoints[0], profile: Profile(),
        )
        let call = UpstreamCall(target: target, apiKey: "k", transport: MockTransport { _, _ in throw CancellationError() })
        let prepared = try call.prepare(
            WireRequest(model: "x", messages: [WireMessage(role: .user, parts: [.text(WireText("Hi"))])]), stream: false,
        )
        let path = try #require(prepared.http.path)
        #expect(path.hasPrefix("/v1beta/models/"))
        #expect(!path.contains("?") && !path.contains("#") && !path.contains("/../"))
    }
}

@Suite struct StrictClassificationTests {
    @Test func losslessCodesAreNotEscalated() {
        #expect(!WireWarning(.unknownField, "kept unknown field `x`", path: "x").isEscalatedWhenStrict)
        #expect(!WireWarning(.opaqueContent, "kept as opaque", path: "input[0]").isEscalatedWhenStrict)
        #expect(!WireWarning(.adjusted, "lowered", path: "max_tokens").isEscalatedWhenStrict)
        #expect(!WireWarning(.droppedField, "cache hint", path: "prompt_cache_key").isEscalatedWhenStrict)
        #expect(!WireWarning(.droppedContent, "cache hint", path: "messages[0].content[0].cache_control").isEscalatedWhenStrict)
    }

    @Test func lossyCodesAreEscalated() {
        #expect(WireWarning(.droppedField, "dropped", path: "logit_bias").isEscalatedWhenStrict)
        #expect(WireWarning(.droppedContent, "dropped", path: "messages[0]").isEscalatedWhenStrict)
        #expect(WireWarning(.lossyConversion, "joined", path: "system").isEscalatedWhenStrict)
        #expect(WireWarning(.unsupportedValue, "ignored", path: "x").isEscalatedWhenStrict)
    }
}

/// An effort that fully expresses the request goes to Chat without a
/// warning, however the effort was arrived at.
@Suite struct ChatEffortWarningTests {
    private func encode(_ reasoning: WireReasoningConfig) -> WireEncoded {
        var request = WireRequest(model: "gpt-5", messages: [WireMessage(role: .user, parts: [.text(WireText("Hi"))])])
        request.reasoning = reasoning
        return ChatCompletionsCodec.buildRequest(request)
    }

    @Test func budgetConvertedToEffortIsNotAWarning() throws {
        let profile = try ProviderRegistry.builtIn.resolve("openai/gpt-5", preferring: .chatCompletions).profile
        for enabled in [true, nil] as [Bool?] {
            var request = WireRequest(model: "gpt-5", messages: [WireMessage(role: .user, parts: [.text(WireText("Hi"))])])
            request.reasoning = WireReasoningConfig(budgetTokens: 4096, enabled: enabled)
            var warnings: [WireWarning] = []
            WireTransforms.mapReasoningEffort(&request, profile: profile, warnings: &warnings)
            #expect(warnings.allSatisfy { $0.code == .adjusted })
            let encoded = ChatCompletionsCodec.buildRequest(request)
            #expect(encoded.warnings == [])
            #expect((try JSONValue(parsing: encoded.body))["reasoning_effort"]?.stringValue != nil)
        }
    }

    @Test func whatEffortCannotSayIsStillAWarning() {
        #expect(encode(WireReasoningConfig(effort: "low", enabled: true)).warnings == [])
        #expect(encode(WireReasoningConfig(effort: "none", enabled: false)).warnings == [])
        #expect(!encode(WireReasoningConfig(enabled: true)).warnings.isEmpty)
        #expect(!encode(WireReasoningConfig(enabled: false)).warnings.isEmpty)
        #expect(!encode(WireReasoningConfig(effort: "low", enabled: false)).warnings.isEmpty)
        #expect(!encode(WireReasoningConfig(effort: "low", budgetTokens: 100)).warnings.isEmpty)
        #expect(!encode(WireReasoningConfig(effort: "low", visible: false)).warnings.isEmpty)
    }
}

@Suite struct MistralToolIDTests {
    private func isMistralID(_ id: String) -> Bool {
        id.utf8.count == 9 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private func ids(_ request: WireRequest) -> (calls: [String], results: [String]) {
        var calls: [String] = [], results: [String] = []
        for message in request.messages {
            for part in message.parts {
                switch part {
                case .toolCall(let call): calls.append(call.id)
                case .toolResult(let result): results.append(result.callID)
                default: break
                }
            }
        }
        return (calls, results)
    }

    private func conversation(_ callIDs: [String]) -> WireRequest {
        WireRequest(model: "m", messages: [
            WireMessage(role: .user, parts: [.text(WireText("Weather?"))]),
            WireMessage(role: .assistant, parts: callIDs.map { .toolCall(WireToolCall(id: $0, name: "get_weather", arguments: "{}")) }),
        ] + callIDs.map { WireMessage(role: .tool, parts: [.toolResult(WireToolResult(callID: $0, content: [.text(WireText("18"))]))]) },
        source: .chatCompletions)
    }

    @Test func foreignIDsAreRewrittenConsistently() {
        let foreign = ["toolu_01A09q90qw90lq917835lq9", "call_abc123def456", "fc_1", "abcDEF123"]
        var request = conversation(foreign)
        WireTransforms.mistralToolIDs(&request)
        let (calls, results) = ids(request)
        #expect(calls.count == 4 && calls.allSatisfy(isMistralID))
        #expect(calls == results)
        #expect(Set(calls).count == 4)
        // Already valid: unchanged.
        #expect(calls[3] == "abcDEF123")
        // Deterministic.
        var again = conversation(foreign)
        WireTransforms.mistralToolIDs(&again)
        #expect(ids(again).calls == calls)
    }

    @Test func collisionsAreResolvedDeterministically() {
        // A valid id equal to what a foreign id would be rewritten to.
        var probe = conversation(["toolu_x"])
        WireTransforms.mistralToolIDs(&probe)
        let taken = ids(probe).calls[0]
        var request = conversation(["toolu_x", taken])
        WireTransforms.mistralToolIDs(&request)
        let (calls, results) = ids(request)
        #expect(calls[1] == taken)
        #expect(calls[0] != taken && isMistralID(calls[0]))
        #expect(calls == results)
    }

    @Test func mistralPresetUsesIt() throws {
        let target = try ProviderRegistry.builtIn.resolve("mistral/mistral-small-latest")
        #expect(target.profile.transforms?.contains(.mistralToolIDs) == true)
    }
}

@Suite struct GPT5ChatRuleTests {
    @Test func gpt5ChatLatestKeepsTemperature() throws {
        for reference in ["openai/gpt-5-chat-latest", "openrouter/openai/gpt-5-chat"] {
            let profile = try ProviderRegistry.builtIn.resolve(reference).profile
            #expect(profile.unsupportedParameters?.contains(.temperature) != true, "\(reference)")
            #expect(profile.supportsReasoning == false, "\(reference)")
        }
        let gpt5 = try ProviderRegistry.builtIn.resolve("openai/gpt-5-mini").profile
        #expect(gpt5.unsupportedParameters?.contains(.temperature) == true)
    }
}
