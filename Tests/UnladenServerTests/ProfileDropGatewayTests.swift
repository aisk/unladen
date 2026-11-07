import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// `--strict` and Profile-declared drops: reported, not refused.
@Suite struct ProfileDropGatewayTests {
    @Test func declaredDropsPassStrict() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        let request = ClientRequest.chat(model: "anthropic/claude-sonnet-5", extra: #","temperature":0.5,"seed":7,"presence_penalty":0.2"#)
        try await makeApp(makeGateway(upstream, strict: true)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", request)
            #expect(response.status == .ok, "\(String(buffer: response.body))")
            let header = try #require(response.headers[HTTPField.Name("x-unladen-warnings")!])
            #expect(header.contains("request: unsupported_by_model at seed"), "\(header)")
            #expect(header.contains("request: unsupported_by_model at temperature"), "\(header)")
            #expect(!header.contains("request: dropped_field"), "\(header)")
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.json["seed"] == nil && hit.json["temperature"] == nil)
    }

    @Test func undeclaredLossIsStillRefused() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-5", strict: true)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", WarningTests.lossy)
            #expect(response.status == .badRequest)
        }
        #expect(upstream.requests.isEmpty)
    }
}
