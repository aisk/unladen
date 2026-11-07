import Foundation
import Testing
import Unladen

@Suite struct ModelIDValidationLibraryTests {
    @Test func pathTraversalModelIsRejectedBeforeAnythingIsSent() async throws {
        let provider = FakeProvider(.json("{}"))
        do {
            _ = try client(provider).model("gemini/../../v1beta/cachedContents?key=EVIL#")
            Issue.record("the model reference was accepted")
        } catch {
            guard case .invalidModelReference(_, .invalidModelID) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        #expect(provider.requests.isEmpty)
    }

    @Test func nestedOpenRouterIDsStillResolve() throws {
        let provider = FakeProvider(.json("{}"))
        let client = ModelClient(transport: provider.transport, apiKeys: ["openrouter": "sk-or"], environment: [:])
        let model = try client.model("openrouter/anthropic/claude-sonnet-4-5")
        #expect(model.target.model == "anthropic/claude-sonnet-4-5")
    }
}

@Suite struct ReasoningBudgetOnChatTests {
    /// A budget on an effort-only model sent through Chat: converted to an
    /// effort, which says everything; strict does not object.
    @Test func budgetOnGPT5OverChatIsNotAnError() async throws {
        let provider = FakeProvider(.json("""
        {"id":"c1","object":"chat.completion","created":1,"model":"gpt-5",
         "choices":[{"index":0,"message":{"role":"assistant","content":"Hi."},"finish_reason":"stop"}],
         "usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
        """))
        let model = try client(provider, policy: .strict).model("openai/gpt-5", preferring: .chatCompletions)
        let response = try await model.generate("Hello", settings: GenerationSettings(reasoning: .budget(4096)))
        #expect(response.text == "Hi.")
        #expect(provider.requests.first?.path == "/v1/chat/completions")
        #expect(provider.lastBody["reasoning_effort"]?.stringValue != nil)
        #expect(response.warnings.allSatisfy { $0.code == .adjusted })
    }
}

/// A history saved with `Codable` and loaded again replays exactly as the
/// original: signatures, encrypted reasoning, item ids, synthesized ids.
@Suite struct MessageCodableTests {
    let weather = Tool(name: "get_weather", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

    /// `history` → JSON → `[Message]`.
    func roundTrip(_ history: [Message]) throws -> [Message] {
        let data = try JSONEncoder().encode(history)
        return try JSONDecoder().decode([Message].self, from: data)
    }

    /// Runs one tool turn on `reference` and returns the history after it,
    /// plus the body a second turn sends with the original history and
    /// with the decoded copy.
    func replay(
        _ reference: String,
        first: String,
        second: String,
        settings: GenerationSettings = GenerationSettings(),
    ) async throws -> (history: [Message], original: JSONValue, decoded: JSONValue) {
        let provider = FakeProvider(.json(first), .json(second), .json(second))
        let model = try client(provider, policy: .lenient).model(reference)
        var history: [Message] = [.system("Be brief."), .user("Weather in Paris?")]
        let response = try await model.generate(history, tools: [weather], settings: settings)
        history.append(response.message)
        for call in response.toolCalls {
            history.append(.tool(ToolResult(call: call, output: "18°C")))
        }
        _ = try await model.generate(history, tools: [weather], settings: settings)
        let original = provider.lastBody
        let decoded = try roundTrip(history)
        #expect(decoded == history)
        _ = try await model.generate(decoded, tools: [weather], settings: settings)
        return (history, original, provider.lastBody)
    }

    @Test func anthropicSignatureSurvives() async throws {
        let done = #"{"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"18°C."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
        let (_, original, decoded) = try await replay(
            "anthropic/claude-sonnet-4-5", first: AnthropicTests.thinkingReply, second: done,
            settings: GenerationSettings(reasoning: .budget(2048)),
        )
        #expect(original.at("messages[1].content[0].signature") == "sig-abc==")
        #expect(decoded == original)
    }

    @Test func responsesEncryptedReasoningAndItemIDsSurvive() async throws {
        let done = #"{"id":"resp_2","object":"response","created_at":2,"status":"completed","model":"gpt-5","output":[{"id":"msg_2","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","annotations":[],"text":"18°C."}]}]}"#
        let (_, original, decoded) = try await replay(
            "openai/gpt-5", first: ResponsesTests.reasoningReply, second: done,
            settings: GenerationSettings(providerOptions: ["responses": ["include": ["reasoning.encrypted_content"], "store": false]]),
        )
        let input = original["input"]?.arrayValue ?? []
        #expect(input.contains { $0["encrypted_content"] == "gAAAA-encrypted==" && $0["id"] == "rs_1" })
        #expect(input.contains { $0["id"] == "fc_1" })
        #expect(decoded == original)
    }

    @Test func geminiThoughtSignaturesAndSynthesizedIDsSurvive() async throws {
        let done = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"18°C."}]},"finishReason":"STOP"}],"responseId":"r2"}"#
        let (history, original, decoded) = try await replay(
            "gemini/gemini-2.5-flash", first: GeminiTests.thoughtReply, second: done,
            settings: GenerationSettings(reasoning: ReasoningSettings(budgetTokens: 1024, visibility: .full)),
        )
        #expect(original.at("contents[1].parts[0].thoughtSignature") == "sigThought==")
        #expect(original.at("contents[1].parts[1].thoughtSignature") == "sigCall==")
        #expect(history.flatMap(\.toolCalls).count == 1)
        #expect(decoded == original)
    }

    @Test func everyPartKindRoundTrips() throws {
        let history: [Message] = [
            .system("S"),
            .user([
                .text("look"),
                .image(Media(.url("https://example.com/a.png"), mediaType: "image/png", detail: "high")),
                .file(Media(.base64("JVBERi0="), mediaType: "application/pdf", filename: "a.pdf")),
                .image(Media(.fileID("file-1"))),
            ]),
            .assistant([.reasoning(""), .refusal("no"), .text("ok"), .toolCall(ToolCall(id: "c1", name: "f", arguments: "{"))]),
            .tool(ToolResult(callID: "c1", toolName: nil, output: [.text("bad"), .image(.url("https://x/y.png"))], isError: true)),
        ]
        #expect(try roundTrip(history) == history)
    }

    @Test func replayTokenIsOpaqueAndVersioned() async throws {
        let provider = FakeProvider(.json(AnthropicTests.thinkingReply))
        let model = try client(provider, policy: .lenient).model("anthropic/claude-sonnet-4-5")
        let response = try await model.generate([.user("Weather?")], tools: [weather])
        let json = try JSONValue(parsing: Array(try JSONEncoder().encode(response.message)))
        let reasoning = try #require(json["content"]?[0])
        // One opaque string; the signature is not readable as a field.
        let token = try #require(reasoning["replay"]?.stringValue)
        #expect(!token.contains("sig-abc"))
        #expect(reasoning["signature"] == nil)

        // Unknown version, garbage, or a non-string: decoding fails.
        let base = Array(try JSONEncoder().encode(response.message))
        let text = String(decoding: base, as: UTF8.self)
        let payload = try #require(Data(base64Encoded: token))
        let future = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: #""v":1"#, with: #""v":99"#)
        #expect(future != String(decoding: payload, as: UTF8.self))
        for replacement in [Data(future.utf8).base64EncodedString(), "%%%not base64", Data("{}".utf8).base64EncodedString()] {
            let bad = text.replacingOccurrences(of: token, with: replacement)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Message.self, from: Data(bad.utf8)) }
        }
        let notString = text.replacingOccurrences(of: "\"\(token)\"", with: "{}")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Message.self, from: Data(notString.utf8)) }
    }
}
