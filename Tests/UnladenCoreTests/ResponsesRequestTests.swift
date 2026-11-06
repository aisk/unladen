import Testing
@_spi(Wire) import UnladenCore

private let requestFixtures = (try? Fixtures.names("Responses/requests", extension: "json")) ?? []

@Suite struct ResponsesRequestTests {
    @Test func fixturesExist() {
        #expect(requestFixtures.count >= 2)
    }

    @Test(arguments: requestFixtures)
    func sameProtocolRoundTrip(_ name: String) throws {
        let original = try Fixtures.json("Responses/requests/\(name)")
        let decoded = try ResponsesCodec.parseRequest(Fixtures.bytes("Responses/requests/\(name)"))
        #expect(decoded.warnings.allSatisfy { $0.path == "vendor_flag" }, "\(decoded.warnings)")
        let built = ResponsesCodec.buildRequest(decoded.value)
        #expect(built.warnings.isEmpty, "\(built.warnings)")
        #expect(built.json.canonical == original.canonical)
    }

    @Test(arguments: requestFixtures)
    func encodingIsDeterministic(_ name: String) throws {
        let decoded = try ResponsesCodec.parseRequest(Fixtures.bytes("Responses/requests/\(name)")).value
        #expect(ResponsesCodec.buildRequest(decoded).body == ResponsesCodec.buildRequest(decoded).body)
        let again = try ResponsesCodec.parseRequest(ResponsesCodec.buildRequest(decoded).body).value
        #expect(again == decoded)
    }

    @Test func codexRequestDecodesToTheWireModel() throws {
        let decoded = try ResponsesCodec.parseRequest(Fixtures.bytes("Responses/requests/codex.json"))
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        let request = decoded.value
        #expect(request.instructions == [.text(WireText("You are Codex, a coding agent running in a terminal."))])
        #expect(request.messages.map(\.role) == [
            .developer, .user, .assistant, .assistant, .assistant, .assistant, .item, .item,
            .assistant, .item, .item, .item, .assistant, .user,
        ])
        #expect(request.messages[2].parts == [
            .reasoning(WireReasoning(text: "**Inspecting tests**", itemID: "rs_01", summaryIndex: 0, origin: "openai")),
            .reasoning(WireReasoning(
                text: "**Planning the fix**", encrypted: "gAAAAABoEncrypted01==", itemID: "rs_01", summaryIndex: 1,
                origin: "openai", extra: ["content": nil],
            )),
        ])
        #expect(request.messages[3].parts == [.text(WireText("Let me look at the tests.", itemID: "msg_01"))])
        #expect(request.messages[4].parts == [.toolCall(WireToolCall(
            id: "call_A", name: "shell", arguments: #"{"command":["ls"]}"#, itemID: "fc_01",
        ))])
        #expect(request.messages[7].parts == [.toolResult(WireToolResult(
            callID: "call_B", content: [.text(WireText("1 test failed"))], contentForm: .parts,
        ))])
        #expect(request.messages[8].parts == [.toolCall(WireToolCall(
            id: "call_C", name: "apply_patch", arguments: "*** Begin Patch\n*** End Patch",
            itemType: "custom_tool_call", itemID: "ctc_01",
        ))])
        guard case .opaque(let reference) = request.messages[10].parts.first else {
            Issue.record("item_reference should be opaque")
            return
        }
        #expect(reference == WireOpaque(protocol: .responses, value: ["type": "item_reference", "id": "msg_00"], slot: "item"))
        #expect(request.messages[12].parts == [
            .reasoning(WireReasoning(text: "", encrypted: "gAAAAABoEncrypted02==", origin: "openai")),
        ])
        #expect(request.reasoning == WireReasoningConfig(effort: "medium", summary: "auto"))
        #expect(request.extra.keys == ["include"])
        #expect(request.tools?.count == 3)
    }

    @Test func parametersDecode() throws {
        let decoded = try ResponsesCodec.parseRequest(Fixtures.bytes("Responses/requests/params.json"))
        #expect(decoded.warnings.map(\.code) == [.unknownField])
        let request = decoded.value
        #expect(request.messages == [WireMessage(role: .user, parts: [.text(WireText("Write a haiku about Swift."))], contentForm: .string)])
        #expect(request.spellings[.input] == "string")
        #expect(request.responseFormat?.kind == .jsonSchema)
        #expect(request.responseFormat?.name == "haiku")
        #expect(request.responseFormat?.strict == true)
        #expect(request.verbosity == "medium")
        #expect(request.toolChoice == .function("lookup"))
        #expect(request.temperature?.literal == "0.70")
        #expect(request.maxOutputTokens == 200)
        #expect(request.extra.keys == ["previous_response_id", "truncation", "metadata", "vendor_flag"])
    }

    @Test func errors() {
        #expect(throws: WireDecodingError(.missingField, path: "model")) {
            try ResponsesCodec.parseRequest(Array(#"{"input":"x"}"#.utf8))
        }
        #expect(throws: WireDecodingError(.typeMismatch(expected: "a string or an array"), path: "input")) {
            try ResponsesCodec.parseRequest(Array(#"{"model":"m","input":3}"#.utf8))
        }
        #expect(throws: WireDecodingError(.missingField, path: "input[0].role")) {
            try ResponsesCodec.parseRequest(Array(#"{"model":"m","input":[{"type":"message","content":"x"}]}"#.utf8))
        }
    }

    @Test func sealedReasoningIsRestored() throws {
        let sealed = ResponsesSeal.seal(.init(origin: "anthropic", signature: "EqQBsig==", encrypted: nil))
        #expect(sealed.hasPrefix("unladen-seal1:"))
        let body: JSONValue = ["model": "m", "input": [
            ["type": "reasoning", "id": "rs_x", "summary": [["type": "summary_text", "text": "Thinking."]], "encrypted_content": .string(sealed)],
            ["type": "reasoning", "summary": [], "encrypted_content": "unladen-seal1:%%%"],
        ]]
        let decoded = try ResponsesCodec.parseRequest(body)
        #expect(decoded.value.messages[0].parts == [
            .reasoning(WireReasoning(text: "Thinking.", signature: "EqQBsig==", summaryIndex: 0, origin: "anthropic")),
        ])
        #expect(decoded.value.messages[1].parts == [.reasoning(WireReasoning(text: ""))])
        #expect(decoded.warnings.map(\.code) == [.droppedContent], "unreadable envelope")
        // Never toward an OpenAI upstream, even as the same protocol.
        let built = ResponsesCodec.buildRequest(decoded.value)
        #expect(built.json["input"] == [])
        #expect(built.warnings.filter { $0.code == .droppedContent }.count == 2)
    }

    @Test func envelopeFormat() {
        let contents = ResponsesSeal.Contents(origin: "google-vertex", signature: "c2ln", encrypted: "ZGF0YQ==")
        let sealed = ResponsesSeal.seal(contents)
        #expect(ResponsesSeal.open(sealed) == .sealed(contents))
        #expect(ResponsesSeal.open("gAAAAABo") == .notSealed)
        #expect(ResponsesSeal.open("unladen-seal1:e30=") == .unreadable, "{} has no origin")
        #expect(sealed == ResponsesSeal.seal(contents), "deterministic")
    }

    @Test func trustedOriginsDecideReplay() {
        var request = WireRequest(model: "m", messages: [WireMessage(role: .assistant, parts: [
            .reasoning(WireReasoning(text: "S", encrypted: "gAAA", itemID: "rs_1", origin: "azure")),
            .text(WireText("Hi", itemID: "msg_1", origin: "azure")),
        ])], source: .anthropicMessages)
        request.stop = .single("END")
        let plain = ResponsesCodec.buildRequest(request)
        #expect(plain.json["input"] == [["type": "message", "role": "assistant", "content": "Hi"]])
        #expect(plain.warnings.map(\.code) == [.droppedContent, .droppedField])
        let trusting = ResponsesCodec.buildRequest(request, options: ResponsesRequestOptions(trustedReasoningOrigins: ["azure"]))
        #expect(trusting.json["input"] == [
            ["type": "reasoning", "id": "rs_1", "summary": [["type": "summary_text", "text": "S"]], "encrypted_content": "gAAA"],
            ["type": "message", "id": "msg_1", "role": "assistant", "content": "Hi"],
        ])
    }
}
