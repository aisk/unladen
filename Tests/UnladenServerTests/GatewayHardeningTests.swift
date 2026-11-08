import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private let warningsHeader = HTTPField.Name("x-unladen-warnings")!
private let modelHeader = HTTPField.Name("x-unladen-model")!

private func message(_ response: TestResponse) -> String {
    json(response.body)["error"]?["message"]?.stringValue ?? ""
}

@Suite struct ModelIDInjectionTests {
    static let evil = "gemini/../../v1beta/cachedContents?key=EVIL#"

    @Test func traversalModelIsA400AndNeverReachesAnUpstream() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Gemini/responses/text.json")) }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            var response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: Self.evil))
            #expect(response.status == .badRequest)
            #expect(message(response).contains("model"))
            response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "openai/gpt-4o\\n"))
            #expect(response.status == .badRequest)
            #expect(json(response.body)["type"] == "error")
        }
        #expect(upstream.requests.isEmpty)
    }
}

@Suite struct UpstreamCredentialErrorTests {
    static let openAI401 = #"{"error":{"message":"Incorrect API key provided: sk-proj-****************************************FAKE. You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#

    @Test(arguments: [401, 402, 403])
    func credentialRejectionIsA502WithoutKeyMaterial(_ status: Int) async throws {
        let upstream = MockUpstream { _ in reply(status: HTTPResponse.Status(code: status), headers: [.contentType: "application/json"], Self.openAI401) }
        let gateway = makeGateway(upstream, keys: ["openai": ["k1", "k2"]])
        try await makeApp(gateway).test(.router) { client in
            // Same protocol: no verbatim forwarding.
            var response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "openai/gpt-4o"))
            #expect(response.status == .badGateway)
            #expect(message(response) == "upstream rejected the gateway's credentials for openai/gpt-4o")
            #expect(!String(buffer: response.body).contains("sk-proj"))
            #expect(!String(buffer: response.body).contains("FAKE"))
            #expect(response.headers[modelHeader] == "openai/gpt-4o")
            // Another client protocol: same, in its shape.
            response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "openai/gpt-4o"))
            #expect(response.status == .badGateway)
            #expect(json(response.body)["type"] == "error")
            #expect(!String(buffer: response.body).contains("sk-proj"))
        }
        // Both keys were tried, for each request.
        #expect(upstream.requests.count == 4)
    }

    @Test func keysAreRedactedFromLoggedMessages() {
        let redacted = Gateway.redactingSecrets("Incorrect API key provided: sk-proj-****FAKE. You can find your API key at https://platform.openai.com/account/api-keys.")
        #expect(!redacted.contains("sk-proj") && !redacted.contains("FAKE"))
        #expect(redacted.contains("Incorrect API key provided"))
        #expect(redacted.contains("https://platform.openai.com/account/api-keys"))
        for secret in ["AIza-FAKE-gemini-test-key", "sk-ant-api03-FAKE-test-key", "xai-FAKE-test-key", "gsk_FAKE_test_key"] {
            #expect(!Gateway.redactingSecrets("API key not valid: \(secret).").contains(secret), "\(secret)")
        }
        #expect(Gateway.redactingSecrets("model `gpt-4o` not found") == "model `gpt-4o` not found")
    }
}

@Suite struct StrictModeTests {
    static let chatReply = fixture("Chat/responses/text.json")

    /// Same-protocol: unknown fields are kept, nothing is lost.
    @Test func sameProtocolUnknownFieldsPassStrict() async throws {
        let upstream = MockUpstream { _ in reply(Self.chatReply) }
        try await makeApp(makeGateway(upstream, strict: true)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "openai/gpt-4o", extra: #","vendor_flag":{"a":1}"#))
            #expect(response.status == .ok, "\(String(buffer: response.body))")
        }
        #expect(upstream.requests.first?.json["vendor_flag"] == ["a": 1])
    }

    /// A route whose model carries the request exactly serves it.
    @Test func exactCandidatePassesStrict() async throws {
        let upstream = MockUpstream { _ in reply(Self.chatReply) }
        let gateway = makeGateway(upstream, model: "openai/gpt-4o", strict: true)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", WarningTests.lossy)
            #expect(response.status == .ok, "\(String(buffer: response.body))")
            #expect(response.headers[modelHeader] == "openai/gpt-4o")
        }
        #expect(upstream.requests.map(\.path) == ["/v1/chat/completions"])
    }

    @Test func everyCandidateRejectedIsA400ListingTheWarnings() async throws {
        let upstream = MockUpstream { _ in reply(Self.chatReply) }
        let gateway = makeGateway(upstream, model: "anthropic/claude-sonnet-4-5", keys: ["anthropic": ["k1", "k2"]], strict: true)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", WarningTests.lossy)
            #expect(response.status == .badRequest)
            #expect(message(response).contains("logit_bias"))
            #expect(message(response).contains("dropped_field"))
            #expect(!message(response).contains("unknown_field"))
        }
        #expect(upstream.requests.isEmpty)
    }

    /// Anthropic `budget_tokens` to an effort-only model over Chat.
    @Test func thinkingBudgetToGPT5OverChatPassesStrict() async throws {
        let upstream = MockUpstream { _ in reply(Self.chatReply) }
        let gateway = makeGateway(upstream, model: "openai/gpt-5", strict: true)
        var registry = gateway.configuration.registry
        var openAI = try #require(registry["openai"])
        openAI.endpoints = openAI.endpoints.filter { $0.apiProtocol == .chatCompletions }
        registry.register(openAI)
        gateway.configuration.registry = registry
        let request = #"{"model":"claude-sonnet-4-5","max_tokens":4096,"thinking":{"type":"enabled","budget_tokens":2048},"messages":[{"role":"user","content":"Hi"}]}"#
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/messages", request)
            #expect(response.status == .ok, "\(String(buffer: response.body))")
            #expect(response.headers[warningsHeader]?.contains("request: dropped_field") != true, "\(response.headers[warningsHeader] ?? "")")
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.path == "/v1/chat/completions")
        #expect(hit.json["reasoning_effort"]?.stringValue != nil)
    }
}

@Suite struct WarningHeaderTests {
    /// A field the target cannot carry is reported once, as dropped (not
    /// also as "kept" by the decoder).
    @Test func crossProtocolUnknownFieldWarnsOnce() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        let request = ClientRequest.chat(model: "x", extra: #","vendor_flag":true"#)
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-4-5")).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", request)
            #expect(response.status == .ok)
            let header = try #require(response.headers[warningsHeader])
            #expect(header.split(separator: "; ").filter { $0.contains("vendor_flag") }.count == 1, "\(header)")
            #expect(header.contains("dropped_field"))
            #expect(!header.contains("unknown_field at vendor_flag"))
        }
    }

    @Test func requestAndResponseWarningsAreLabelled() async throws {
        let chatReply = #"{"id":"c1","object":"chat.completion","created":1,"model":"m","vendor_echo":"x","choices":[{"index":0,"message":{"role":"assistant","content":"Hi."},"finish_reason":"stop"}]}"#
        let upstream = MockUpstream { _ in reply(chatReply) }
        let request = #"{"model":"x","max_tokens":64,"vendor_flag":true,"messages":[{"role":"user","content":"Hi"}]}"#
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/messages", request)
            #expect(response.status == .ok)
            let header = try #require(response.headers[warningsHeader])
            #expect(header.contains("request: dropped_field at vendor_flag"), "\(header)")
            #expect(header.contains("response: "), "\(header)")
            #expect(header.contains("vendor_echo"), "\(header)")
        }
    }
}

@Suite struct GatewayEdgeCaseTests {
    @Test func queryKeyIsOnlyAcceptedOnGeminiRoutes() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        try await makeApp(makeGateway(upstream, apiKey: "secret")).test(.router) { client in
            var response = try await client.post("/v1/chat/completions?key=secret", ClientRequest.chat(model: "x"))
            #expect(response.status == .unauthorized)
            response = try await client.post("/v1/messages?key=secret", ClientRequest.anthropic(model: "x"))
            #expect(response.status == .unauthorized)
            response = try await client.post("/v1/responses?key=secret", ClientRequest.responses(model: "x"))
            #expect(response.status == .unauthorized)
            response = try await client.executeRequest(uri: "/v1/models?key=secret", method: .get, headers: [:], body: nil)
            #expect(response.status == .unauthorized)
            response = try await client.post(ClientRequest.geminiPath(model: "x") + "?key=secret", ClientRequest.gemini)
            #expect(response.status == .ok)
        }
    }

    @Test func oversizedReplyIsReportedAsSuch() async throws {
        let upstream = MockUpstream { _ in throw HTTPResponseBodyTooLargeError(maxBytes: 1024) }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .badGateway)
            #expect(!message(response).contains("unreachable"))
            #expect(message(response).contains("larger than 1024 bytes"))
        }
    }

    @Test func exposedWithoutAKeyWarns() {
        #expect(UnladenCommand.exposureWarning(host: "0.0.0.0", apiKey: nil) != nil)
        #expect(UnladenCommand.exposureWarning(host: "192.168.1.5", apiKey: nil) != nil)
        #expect(UnladenCommand.exposureWarning(host: "::", apiKey: nil) != nil)
        #expect(UnladenCommand.exposureWarning(host: "0.0.0.0", apiKey: "k") == nil)
        for host in ["127.0.0.1", "127.0.0.2", "localhost", "::1", "[::1]"] {
            #expect(UnladenCommand.exposureWarning(host: host, apiKey: nil) == nil, "\(host)")
        }
    }

    @Test func helpExplainsHalfCloseIsADisconnect() {
        #expect(Serve.configuration.discussion.contains("half-close"))
    }
}
