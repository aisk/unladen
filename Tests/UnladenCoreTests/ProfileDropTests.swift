import Testing
@_spi(Wire) import UnladenCore

/// Parameters a Profile declares unsupported are removed by the transform
/// with an `unsupported_by_model` warning, once; the codec does not report
/// them again.
@Suite struct ProfileDropTests {
    private func prepared(_ reference: String, preferring: APIProtocol? = nil, _ edit: (inout WireRequest) -> Void) throws -> UpstreamRequest {
        var request = WireRequest(model: "x", messages: [WireMessage(role: .user, parts: [.text(WireText("Hi"))])])
        edit(&request)
        let target = try ProviderRegistry.builtIn.resolve(reference, preferring: preferring)
        return try UpstreamCall(target: target, apiKey: "k", transport: MockTransport { _, _ in throw CancellationError() })
            .prepare(request, stream: false)
    }

    @Test func anthropicDeclaresWhatItHasNoFieldFor() throws {
        let prepared = try prepared("anthropic/claude-sonnet-5") {
            $0.seed = 7
            $0.frequencyPenalty = 0.1
            $0.presencePenalty = 0.1
            $0.responseFormat = WireResponseFormat(kind: .jsonObject)
            $0.temperature = 0.5
        }
        let paths = prepared.warnings.map(\.path).sorted()
        #expect(paths == ["frequency_penalty", "presence_penalty", "response_format", "seed", "temperature"], "\(prepared.warnings)")
        #expect(prepared.warnings.allSatisfy { $0.code == .unsupportedByModel && !$0.isEscalatedWhenStrict })
    }

    @Test func geminiDeclaresUserAndSerialToolCalls() throws {
        let prepared = try prepared("gemini/gemini-2.5-flash") {
            $0.user = "u"
            $0.parallelToolCalls = false
        }
        #expect(prepared.warnings.map(\.path).sorted() == ["parallel_tool_calls", "user"], "\(prepared.warnings)")
        #expect(prepared.warnings.allSatisfy { $0.code == .unsupportedByModel })
    }

    @Test func chatAndResponsesDeclareTheirGaps() throws {
        let chat = try prepared("deepseek/deepseek-chat") { $0.topK = 40 }
        #expect(chat.warnings.map(\.code) == [.unsupportedByModel])
        let responses = try prepared("openai/gpt-4.1") {
            $0.seed = 1
            $0.stop = .multiple(["x"])
        }
        #expect(responses.warnings.map(\.path).sorted() == ["seed", "stop"])
        #expect(responses.warnings.allSatisfy { $0.code == .unsupportedByModel })
    }

    @Test func noReasoningAndUncontrolledReasoningAreDeclared() throws {
        for reference in ["moonshot/kimi-k2-0905-preview", "xai/grok-4", "openai/gpt-5-chat-latest"] {
            let prepared = try prepared(reference) { $0.reasoning = WireReasoningConfig(effort: "high") }
            #expect(prepared.warnings.map(\.code) == [.unsupportedByModel], "\(reference): \(prepared.warnings)")
        }
    }

    /// Images are content, not a parameter: still a lossy drop.
    @Test func imagesStayLossy() {
        var request = WireRequest(model: "x", messages: [WireMessage(role: .user, parts: [
            .text(WireText("What?")), .image(WireMedia(source: .url("https://example.com/a.png"))),
        ])])
        var warnings: [WireWarning] = []
        WireTransforms.dropUnsupportedParams(&request, profile: Profile(supportsImages: false), warnings: &warnings)
        #expect(warnings.map(\.code) == [.droppedContent])
        #expect(warnings.allSatisfy { $0.isEscalatedWhenStrict })
    }

    /// Endpoint declarations (protocol gaps) and a model rule's add up.
    @Test func unsupportedParametersAccumulateAcrossMerges() throws {
        let profile = try ProviderRegistry.builtIn.resolve("anthropic/claude-sonnet-5").profile
        let declared = profile.unsupportedParameters ?? []
        #expect(declared.isSuperset(of: [.temperature, .topP, .topK, .seed, .frequencyPenalty, .presencePenalty, .responseFormat]))
    }
}
