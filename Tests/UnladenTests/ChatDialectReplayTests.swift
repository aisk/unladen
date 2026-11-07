import Foundation
import Testing
import Unladen

/// Chat dialect replay data (OpenRouter `reasoning_details`, Gemini
/// `extra_content`) survives a library history, saved and loaded, back to
/// the Chat endpoint that produced it.
@Suite struct ChatDialectReplayTests {
    private func openRouter(_ provider: FakeProvider) -> ModelClient {
        ModelClient(transport: provider.transport, apiKeys: ["openrouter": "sk-or"], environment: [:], warningPolicy: .strict)
    }

    private static let reply = """
    {"id":"gen-1","object":"chat.completion","created":1,"model":"google/gemini-3-pro","choices":[{"index":0,"finish_reason":"stop",
     "message":{"role":"assistant","content":"10","reasoning":"Counting.","reasoning_details":[
      {"type":"reasoning.text","text":"Counting.","signature":"GEMSIG","format":"google-gemini-v1","index":0}]}}],
     "usage":{"prompt_tokens":3,"completion_tokens":4}}
    """

    @Test func reasoningDetailsGoBackToOpenRouterChat() async throws {
        let provider = FakeProvider(.json(Self.reply), .json(Self.reply))
        let model = try openRouter(provider).model("openrouter/google/gemini-3-pro")
        let first = try await model.generate([.user("Primes between 100 and 150?")])

        // Saved and loaded: the opaque token keeps the entry's shape.
        let history: [Message] = [.user("Primes between 100 and 150?"), first.message, .user("And below 100?")]
        let loaded = try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(history))
        _ = try await model.generate(loaded)

        let assistant = try #require(provider.lastBody["messages"]?[1])
        #expect(assistant["reasoning_details"] == [[
            "type": "reasoning.text", "format": "google-gemini-v1", "index": 0, "text": "Counting.", "signature": "GEMSIG",
        ]])
    }

    /// A token written before the dialect field existed still reads.
    @Test func tokensWithoutDialectStillDecode() throws {
        let old = Data(#"{"v":1,"system":"openrouter","signature":"s","origin":"openrouter"}"#.utf8).base64EncodedString()
        let json = #"{"role":"assistant","content":[{"type":"reasoning","text":"t","replay":"\#(old)"}]}"#
        let message = try JSONDecoder().decode(Message.self, from: Data(json.utf8))
        guard case .reasoning(let text, let token?) = message.content.first else {
            Issue.record("\(message)")
            return
        }
        #expect(text == "t")
        #expect(token.hasSignedData)
    }
}
