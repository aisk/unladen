import Testing
import Unladen

/// Gemini upstream: thought signatures on reasoning and on function calls.
@Suite struct GeminiTests {
    let weather = Tool(name: "get_weather", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

    static let thoughtReply = """
    {"candidates":[{"content":{"role":"model","parts":[
        {"text":"**Planning** I will call the tool.","thought":true,"thoughtSignature":"sigThought=="},
        {"functionCall":{"name":"get_weather","args":{"city":"Paris"}},"thoughtSignature":"sigCall=="}
      ]},"finishReason":"STOP"}],
     "usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":7,"totalTokenCount":59,"thoughtsTokenCount":40},
     "modelVersion":"gemini-2.5-flash","responseId":"resp-g1"}
    """

    @Test func generateText() async throws {
        let provider = FakeProvider(.json("""
        {"candidates":[{"content":{"role":"model","parts":[{"text":"Hello!"}]},"finishReason":"STOP"}],
         "usageMetadata":{"promptTokenCount":2,"candidatesTokenCount":2,"totalTokenCount":4},"modelVersion":"gemini-2.5-flash","responseId":"r0"}
        """))
        let model = try client(provider).model("gemini/gemini-2.5-flash")

        let response = try await model.generate([.system("Be nice."), .user("Hi")], settings: GenerationSettings(topK: 40))

        #expect(response.text == "Hello!")
        #expect(response.metadata.id == "r0")
        let request = try #require(provider.requests.first)
        #expect(request.path == "/v1beta/models/gemini-2.5-flash:generateContent")
        let body = provider.lastBody
        #expect(body.at("systemInstruction.parts[0].text") == "Be nice.")
        #expect(body.at("contents[0].parts[0].text") == "Hi")
        #expect(body.at("generationConfig.topK") == 40)
    }

    @Test func thoughtSignaturesReplay() async throws {
        let provider = FakeProvider(
            .json(Self.thoughtReply),
            .json(#"{"candidates":[{"content":{"role":"model","parts":[{"text":"18°C."}]},"finishReason":"STOP"}],"responseId":"r2"}"#),
        )
        let model = try client(provider).model("gemini/gemini-2.5-flash")
        let settings = GenerationSettings(reasoning: ReasoningSettings(budgetTokens: 1024, visibility: .full))

        var history: [Message] = [.user("Weather in Paris?")]
        let first = try await model.generate(history, tools: [weather], settings: settings)
        #expect(first.reasoningText == "**Planning** I will call the tool.")
        #expect(first.usage.reasoningTokens == 40)
        #expect(provider.lastBody.at("generationConfig.thinkingConfig") == ["includeThoughts": true, "thinkingBudget": 1024])
        let call = try #require(first.toolCalls.first)
        #expect(try call.parsedArguments() == ["city": "Paris"])

        history.append(first.message)
        history.append(.tool(ToolResult(call: call, json: ["temperature": 18])))
        _ = try await model.generate(history, tools: [weather], settings: settings)

        let contents = provider.lastBody["contents"]
        #expect(contents?.at("[1].role") == "model")
        #expect(contents?.at("[1].parts[0].thoughtSignature") == "sigThought==")
        #expect(contents?.at("[1].parts[1].thoughtSignature") == "sigCall==")
        #expect(contents?.at("[1].parts[1].functionCall.name") == "get_weather")
        #expect(contents?.at("[2].parts[0].functionResponse.name") == "get_weather")
    }

    @Test func streamParallelFunctionCalls() async throws {
        let provider = FakeProvider(.sse(sse([
            #"{"candidates":[{"content":{"parts":[{"text":"Checking "}],"role":"model"}}],"modelVersion":"gemini-2.5-flash","responseId":"rs"}"#,
            #"{"candidates":[{"content":{"parts":[{"text":"both."}],"role":"model"}}],"modelVersion":"gemini-2.5-flash","responseId":"rs"}"#,
            #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"city":"Paris"}},"thoughtSignature":"sigFirst=="},{"functionCall":{"name":"get_weather","args":{"city":"Rome"}}}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":20,"totalTokenCount":70},"modelVersion":"gemini-2.5-flash","responseId":"rs"}"#,
        ])))
        let model = try client(provider).model("gemini/gemini-2.5-flash")

        let all = try await parts(model.stream([.user("Paris and Rome?")], tools: [weather]))

        #expect(provider.requests.first?.path == "/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
        #expect(all.text == "Checking both.")
        #expect(all.toolCalls.map(\.name) == ["get_weather", "get_weather"])
        #expect(all.toolCalls.map(\.arguments) == [#"{"city":"Paris"}"#, #"{"city":"Rome"}"#])
        #expect(all.toolCalls[0].replay?.hasSignedData == true)
        #expect(all.finish?.kind == .toolCalls)
    }
}
