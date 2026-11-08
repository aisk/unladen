import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// `--strict` with real clients talking to their own vendor: what the
/// client sends is carried exactly (unknown fields kept), so strict mode
/// must not turn it away.
@Suite struct StrictModeReplayTests {
    static let sameProtocol: [(client: String, upstream: String, uri: String)] = [
        ("clients/claude-code", "anthropic/thinking-stream-sonnet-5-5", "/v1/messages"),
        ("clients/codex", "openai/responses-stream-annotations-gpt-5.2", "/v1/responses"),
        ("clients/opencode-chat", "deepseek/reasoning-stream", "/v1/chat/completions"),
    ]

    @Test(arguments: sameProtocol.indices)
    func realClientPassesStrictOnItsOwnProtocol(_ index: Int) async throws {
        let (client, upstream, uri) = Self.sameProtocol[index]
        let recording = Recording.named(upstream)
        let target = try #require(recording.target)
        let replay = ReplayTransport([recording])
        let gateway = replayGateway(defaultModel: target, registry: registry(target, speaking: recording.wire), transport: replay)
        gateway.configuration.strict = true
        let request = Recording.named(client)
        let response = try await Application(router: buildRouter(gateway: gateway)).test(.router) { http in
            try await http.post(uri, bytes: try #require(request.requestBytes))
        }
        #expect(response.status == .ok, "\(client): \(String(buffer: response.body).prefix(600))")
        #expect(replay.requests.count == 1)
    }
}
