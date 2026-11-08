import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// Prompt-cache breakpoints through the gateway: same protocol byte for
/// byte, translated where the upstream honours them.
@Suite struct CacheControlGatewayTests {
    static let anthropicRequest = #"""
    {"model":"MODEL","messages":[{"role":"user","content":[{"type":"text","text":"doc","cache_control":{"type":"ephemeral","ttl":"1h"}},{"type":"text","text":"Summarise.","cache_control":{"ttl":"5m","type":"ephemeral"}}]}],"max_tokens":256,"system":[{"type":"text","text":"sys","cache_control":{"type":"ephemeral","ttl":"1h"}}],"tools":[{"name":"f","input_schema":{"type":"object"},"cache_control":{"type":"ephemeral","ttl":"1h"}}]}
    """#

    static func request(_ model: String) -> String {
        anthropicRequest.replacingOccurrences(of: "MODEL", with: model)
    }

    @Test func anthropicToAnthropicKeepsBreakpointsByteForByte() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/messages", Self.request("anthropic/claude-sonnet-4-5"))
            #expect(response.status == .ok)
        }
        let hit = try #require(upstream.requests.first)
        #expect(String(decoding: hit.body, as: UTF8.self) == Self.request("claude-sonnet-4-5"))
    }

    /// An Anthropic client's breakpoints reach a Chat-only relay whose
    /// Profile says it serves Claude and honours them.
    @Test func anthropicClientToChatRelayServingClaude() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        var configuration = GatewayConfiguration()
        configuration.registry.register(Provider(id: "relay", endpoints: [
            Endpoint(system: "relay", apiProtocol: .chatCompletions, baseURL: "https://relay.example/api/v1",
                     defaults: Profile(chatCacheControl: true, maxCacheBreakpoints: 4)),
        ]))
        configuration.keyPools = upstreamKeyPools(["relay": ["key-relay"]])
        let gateway = Gateway(configuration: configuration, transport: upstream.transport)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/messages", Self.request("relay/claude-sonnet-4-5"))
            #expect(response.status == .ok)
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.path == "/api/v1/chat/completions")
        let body = hit.json
        #expect(body["messages"]?[0] == [
            "role": "system", "content": [["type": "text", "text": "sys", "cache_control": ["type": "ephemeral", "ttl": "1h"]]],
        ])
        // Every breakpoint crosses over, `ttl`-first spelling included.
        #expect(body["messages"]?[1]?["content"] == [
            ["type": "text", "text": "doc", "cache_control": ["type": "ephemeral", "ttl": "1h"]],
            ["type": "text", "text": "Summarise.", "cache_control": ["ttl": "5m", "type": "ephemeral"]],
        ])
        #expect(body["tools"]?[0]?["cache_control"] == ["type": "ephemeral", "ttl": "1h"])
    }
}
