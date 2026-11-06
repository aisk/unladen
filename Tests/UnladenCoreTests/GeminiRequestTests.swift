import Testing
@_spi(Wire) import UnladenCore

private let requestFixtures = (try? Fixtures.names("Gemini/requests", extension: "json")) ?? []

private func parse(_ json: JSONValue, stream: Bool = false) throws(WireDecodingError) -> WireDecoded<WireRequest> {
    try GeminiCodec.parseRequest(json, model: "gemini-3-pro-preview", stream: stream)
}

@Suite struct GeminiRequestRoundTripTests {
    @Test func fixturesExist() {
        #expect(requestFixtures.count >= 4)
    }

    @Test(arguments: requestFixtures)
    func sameProtocolRoundTripIsStructurallyEqual(_ name: String) throws {
        let original = try Fixtures.json("Gemini/requests/\(name)")
        let decoded = try parseGeminiRequest(name)
        let built = GeminiCodec.buildRequest(decoded.value)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(built.json.canonical == original.canonical)
    }

    @Test(arguments: requestFixtures)
    func encodingIsDeterministicAndIdempotent(_ name: String) throws {
        let request = try parseGeminiRequest(name).value
        let first = GeminiCodec.buildRequest(request).body
        #expect(GeminiCodec.buildRequest(request).body == first)
        let again = try GeminiCodec.parseRequest(first, model: request.model, stream: true).value
        #expect(again == request)
        #expect(GeminiCodec.buildRequest(again).body == first)
    }

    @Test func bodyHasNoModelAndPathCarriesIt() throws {
        let request = try parseGeminiRequest("simple.json", model: "gemini-2.5-flash", stream: false).value
        #expect(request.model == "gemini-2.5-flash")
        #expect(request.stream == false)
        let built = GeminiCodec.buildRequest(request)
        #expect(built.json["model"] == nil)
        #expect(built.json["stream"] == nil)
        #expect(GeminiCodec.path(model: "gemini-2.5-flash", stream: false) == "/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(GeminiCodec.path(model: "models/gemini-3-pro-preview", stream: true)
            == "/v1beta/models/gemini-3-pro-preview:streamGenerateContent?alt=sse")
        #expect(GeminiCodec.parsePath("/v1beta/models/gemini-3-pro-preview:streamGenerateContent?alt=sse")! == ("gemini-3-pro-preview", true))
        #expect(GeminiCodec.parsePath("/v1/models/gemini-2.5-flash:generateContent")! == ("gemini-2.5-flash", false))
        #expect(GeminiCodec.parsePath("/v1beta/models/gemini-2.5-flash:countTokens") == nil)
        #expect(GeminiCodec.parsePath("/v1/chat/completions") == nil)
    }
}

@Suite struct GeminiRequestDecodingTests {
    @Test func geminiCLIRequestModel() throws {
        let decoded = try parseGeminiRequest("gemini_cli.json")
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        let request = decoded.value
        #expect(request.source == .gemini)
        #expect(request.stream == true)
        #expect(request.instructions == [.text(WireText("You are Gemini CLI, an interactive CLI agent specializing in software engineering tasks."))])
        #expect(request.instructionsForm == .parts)
        #expect(request.instructionsExtra == ["role": "user"])
        #expect(request.messages.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(request.messages[0].parts[1] == .image(WireMedia(source: .base64("iVBORw0KGgo="), mediaType: "image/png")))

        #expect(request.messages[1].parts == [
            .reasoning(WireReasoning(text: "**Planning the calls**")),
            .toolCall(WireToolCall(
                id: "unladen_gc_1_1", idSynthesized: true, name: "get_weather",
                arguments: #"{"city":"Paris","unit":"celsius","days":1.0}"#, signature: "CiQBVKhc7sigWeather==",
            )),
            .toolCall(WireToolCall(id: "unladen_gc_1_2", idSynthesized: true, name: "get_time", arguments: #"{"tz":"Europe/Paris"}"#)),
        ])
        #expect(request.messages[2].parts == [
            .toolResult(WireToolResult(
                callID: "unladen_gc_1_1", callIDSynthesized: true, name: "get_weather",
                content: [.text(WireText("18°C, cloudy"))], contentForm: .string,
            )),
            .toolResult(WireToolResult(
                callID: "unladen_gc_1_2", callIDSynthesized: true, name: "get_time",
                content: [.text(WireText(#"{"time":"14:05","dst":true}"#))], contentForm: .parts,
            )),
        ])
        #expect(request.messages[3].parts == [.text(WireText(
            "The image is a bar chart. In Paris it is 18°C and cloudy, and the time is 14:05.", signature: "CiQBVKhc7sigText==",
        ))], "a client's request does not say where its signatures came from")

        guard case .function(let weather)? = request.tools?[0], case .function(let time)? = request.tools?[1],
              case .opaque(let search)? = request.tools?[2] else {
            Issue.record("expected two functions and an opaque tool")
            return
        }
        #expect(weather.sourceKey == "parametersJsonSchema")
        #expect(weather.parameters?["required"] == ["city"])
        #expect(time.sourceKey == "parameters")
        #expect(search.value == ["googleSearch": [:]])
        #expect(request.toolChoice == .auto)
        #expect(request.temperature?.literal == "0.70")
        #expect(request.maxOutputTokens == 8192)
        #expect(request.reasoning == WireReasoningConfig(budgetTokens: 1024, visible: true))
        #expect(request.extra.keys == ["safetySettings"])
    }

    @Test func structuredRequestModel() throws {
        let decoded = try parseGeminiRequest("structured.json")
        #expect(Set(decoded.warnings.map(\.path)) == ["toolConfig.retrievalConfig", "generationConfig.responseModalities"])
        let request = decoded.value
        #expect(request.messages[0].parts[1] == .file(WireMedia(
            source: .url("https://generativelanguage.googleapis.com/v1beta/files/abc123"), mediaType: "application/pdf",
        )))
        #expect(request.messages[1].parts == [.toolCall(WireToolCall(
            id: "fc-lookup-1", name: "lookup", arguments: #"{"q":"ACME","limit":1}"#, signature: "sigLookup==",
        ))])
        #expect(request.messages[2].parts == [.toolResult(WireToolResult(
            callID: "fc-lookup-1", name: "lookup", content: [.text(WireText("not found"))], contentForm: .string, isError: true,
        ))])
        #expect(request.toolChoice == .function("lookup"))
        #expect(request.responseFormat?.kind == .jsonSchema)
        #expect(request.responseFormat?.sourceKey == "responseSchema")
        #expect(request.stop == .multiple(["END"]))
        #expect(request.seed == 42)
        #expect(request.candidateCount == 1)
        #expect(request.topK?.literal == "40")
        #expect(request.presencePenalty?.literal == "0.5")
        #expect(request.frequencyPenalty?.literal == "0.25")
        #expect(request.reasoning == WireReasoningConfig(effort: "low"))
        #expect(request.extra == [
            "toolConfig": ["retrievalConfig": ["languageCode": "en"]],
            "generationConfig": ["responseModalities": ["TEXT"]],
            "cachedContent": "cachedContents/xyz",
            "labels": ["team": "billing"],
        ])
    }

    @Test func stringSystemInstructionAndOpaqueParts() throws {
        let simple = try parseGeminiRequest("simple.json").value
        #expect(simple.instructions == [.text(WireText("You are a poet."))])
        #expect(simple.instructionsForm == .string)
        #expect(simple.responseFormat == WireResponseFormat(kind: .text))
        #expect(simple.reasoning == WireReasoningConfig(budgetTokens: 0))

        let decoded = try parseGeminiRequest("validated.json")
        #expect(decoded.warnings.map(\.code) == [.opaqueContent], "VALIDATED mode; code execution parts are known")
        let request = decoded.value
        guard case .opaque(let choice)? = request.toolChoice else {
            Issue.record("expected an opaque tool choice")
            return
        }
        #expect(choice.value["mode"] == "VALIDATED")
        #expect(request.messages[1].parts.allSatisfy { if case .opaque = $0 { true } else { false } })
        #expect(request.responseFormat?.sourceKey == "responseJsonSchema")
    }

    @Test func idlessResponsesMatchCallsByNameAndOrder() throws {
        let body: JSONValue = ["contents": [
            ["role": "model", "parts": [
                ["functionCall": ["name": "read", "args": ["path": "a"]]],
                ["functionCall": ["name": "read", "args": ["path": "b"]]],
                ["functionCall": ["id": "real-1", "name": "list"]],
            ]],
            ["role": "user", "parts": [
                ["functionResponse": ["name": "list", "response": ["output": "x"]]],
                ["functionResponse": ["name": "read", "response": ["output": "A"]]],
                ["functionResponse": ["name": "read", "response": ["output": "B"]]],
                ["functionResponse": ["name": "orphan", "response": ["output": "?"]]],
            ]],
        ]]
        let request = try parse(body).value
        let ids = request.messages[1].parts.compactMap { part -> String? in
            if case .toolResult(let result) = part { return result.callID }
            return nil
        }
        #expect(ids == ["real-1", "unladen_gc_0_0", "unladen_gc_0_1", "unladen_gc_1_3"])
        // The answers had no ids: none are invented on the way back.
        let built = GeminiCodec.buildRequest(request)
        #expect(built.json.canonical == body.canonical)
    }

    @Test func errors() {
        #expect(throws: WireDecodingError(.missingField, path: "contents")) {
            try parse(["generationConfig": [:]])
        }
        #expect(throws: WireDecodingError(.typeMismatch(expected: "an integer"), path: "generationConfig.maxOutputTokens")) {
            try parse(["contents": [], "generationConfig": ["maxOutputTokens": 1.5]])
        }
    }
}

@Suite struct GeminiSignatureReplayTests {
    @Test func missingSignatureFallbackIsOptIn() throws {
        // A Chat history: the calls have no signatures at all.
        let chat = try ChatCompletionsCodec.parseRequest(Fixtures.bytes("Chat/requests/multi_turn_tools.json")).value
        let plain = GeminiCodec.buildRequest(chat)
        let call = try #require(plain.json["contents"]?.arrayValue?.first { $0["role"] == "model" }?["parts"]?[0])
        #expect(call["thoughtSignature"] == nil)

        let options = GeminiRequestOptions(missingSignatureFallback: GeminiRequestOptions.skipSignatureValidator)
        let patched = GeminiCodec.buildRequest(chat, options: options)
        let signed = try #require(patched.json["contents"]?.arrayValue?.first { $0["role"] == "model" }?["parts"]?[0])
        #expect(signed["thoughtSignature"] == "skip_thought_signature_validator")
    }

    @Test func onlyCallsBeforeTheFirstSignedOneGetTheFallback() throws {
        let request = try parseGeminiRequest("gemini_cli.json").value
        let options = GeminiRequestOptions(missingSignatureFallback: GeminiRequestOptions.skipSignatureValidator)
        let built = GeminiCodec.buildRequest(request, options: options)
        // The second parallel call legitimately has none.
        #expect(built.json.canonical == (try Fixtures.json("Gemini/requests/gemini_cli.json")).canonical)

        var unsigned = request
        guard case .toolCall(var first) = unsigned.messages[1].parts[1] else {
            Issue.record("expected a call")
            return
        }
        first.signature = nil
        unsigned.messages[1].parts[1] = .toolCall(first)
        let parts = try #require(GeminiCodec.buildRequest(unsigned, options: options).json["contents"]?[1]?["parts"]?.arrayValue)
        #expect(parts[1]["thoughtSignature"] == "skip_thought_signature_validator")
        #expect(parts[2]["thoughtSignature"] == "skip_thought_signature_validator")
    }

    @Test func untrustedSignaturesAreDropped() {
        let call = WireToolCall(id: "c1", name: "f", arguments: "{}", signature: "sig", origin: "gemini")
        let request = WireRequest(model: "m", messages: [
            WireMessage(role: .user, parts: [.text(WireText("go"))]),
            WireMessage(role: .assistant, parts: [
                .reasoning(WireReasoning(text: "thinking", signature: "rsig", origin: "gemini")),
                .toolCall(call),
            ]),
        ], source: .chatCompletions)
        let gemini = GeminiCodec.buildRequest(request)
        #expect(gemini.json["contents"]?[1]?["parts"] == [
            ["text": "thinking", "thought": true, "thoughtSignature": "rsig"],
            ["functionCall": ["id": "c1", "name": "f", "args": [:]], "thoughtSignature": "sig"],
        ])
        #expect(gemini.warnings.isEmpty, "\(gemini.warnings)")
        // A Vertex endpoint does not accept AI Studio signatures.
        let vertex = GeminiCodec.buildRequest(request, options: GeminiRequestOptions(
            trustedSignatureOrigins: ["google-vertex"], missingSignatureFallback: GeminiRequestOptions.skipSignatureValidator,
        ))
        #expect(vertex.json["contents"]?[1]?["parts"] == [
            ["functionCall": ["id": "c1", "name": "f", "args": [:]], "thoughtSignature": "skip_thought_signature_validator"],
        ])
        #expect(vertex.warnings.map(\.code) == [.droppedContent, .droppedContent])
    }
}
