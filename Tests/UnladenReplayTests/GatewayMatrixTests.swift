import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer
import UnladenTestSupport

/// A real client's request, as the client sends it to the gateway.
struct GatewayClient: Sendable, CustomTestStringConvertible {
    let name: String
    /// The recording holding the client's request.
    let recording: String
    let wire: WireProtocol
    var testDescription: String { name }

    func uri(model: String) -> String {
        switch wire {
        case .chatCompletions: "/v1/chat/completions"
        case .responses: "/v1/responses"
        case .anthropicMessages: "/v1/messages"
        case .gemini: "/v1beta/models/\(model):streamGenerateContent?alt=sse"
        }
    }

    static let all: [GatewayClient] = [
        GatewayClient(name: "Claude Code 2.1.296", recording: "clients/claude-code", wire: .anthropicMessages),
        GatewayClient(name: "Codex 0.162.0", recording: "clients/codex", wire: .responses),
        GatewayClient(name: "OpenCode (OpenAI SDK, Chat)", recording: "clients/opencode-chat", wire: .chatCompletions),
        // No gemini-cli capture in the references: the Google SDK's request
        // of a recorded Gemini 3 conversation (signed call, result).
        GatewayClient(name: "Google GenAI SDK", recording: "gemini/3-signature-stream-turn2", wire: .gemini),
    ]
}

/// Recorded vendor streams the gateway is pointed at.
let gatewayUpstreams: [String] = [
    "anthropic/thinking-stream-sonnet-5-5",
    "anthropic/tool-thinking-turn1-sonnet-5-5",
    "gemini/3-tool-call-stream",
    "gemini/3-reasoning-stream",
    "deepseek/reasoning-stream",
    "deepseek/tool-call-stream",
    "mistral/glm-thinking-parts-stream",
    "mistral/parallel-tools-stream",
    "groq/tool-call-stream",
    "moonshot/tool-call-stream",
    "moonshot/indexless-tool-calls-stream",
    "xai/responses-reasoning-then-call",
    "openai/responses-stream-annotations-gpt-5.2",
]

/// Every client against every upstream.
let gatewayMatrix: [(GatewayClient, String)] = GatewayClient.all.flatMap { client in gatewayUpstreams.map { (client, $0) } }

/// `registry` with `target`'s provider reduced to its endpoints of
/// `wire`, so the gateway calls the upstream in the recorded protocol.
func registry(_ target: String, speaking wire: WireProtocol) -> ProviderRegistry {
    var registry = ProviderRegistry.builtIn
    let provider = String(target.prefix { $0 != "/" })
    if var preset = registry[provider] {
        preset.endpoints = preset.endpoints.filter { $0.apiProtocol.wire == wire }
        registry.register(preset)
    }
    return registry
}

/// A gateway serving `defaultModel` (then `fallbacks`) over `transport`,
/// with a key for every provider.
func replayGateway(defaultModel: String, fallbacks: [String] = [], registry: ProviderRegistry, transport: ReplayTransport) -> Gateway {
    var configuration = GatewayConfiguration()
    configuration.defaultModel = defaultModel
    configuration.fallbacks = fallbacks
    configuration.registry = registry
    configuration.upstreamKeys = Dictionary(uniqueKeysWithValues: registry.providers.keys.map { ($0, ["key-\($0)"]) })
    return Gateway(configuration: configuration, transport: transport.transport)
}

extension TestClientProtocol {
    func post(_ uri: String, bytes: [UInt8]) async throws -> TestResponse {
        try await executeRequest(uri: uri, method: .post, headers: [.contentType: "application/json"], body: ByteBuffer(bytes: bytes))
    }
}

/// Layer D: the gateway end to end. A real client's request (Claude Code,
/// Codex, OpenCode, the Google SDK) goes in; the gateway routes it to its
/// default model, whose upstream answers with a recorded stream; the client
/// gets a stream in its own protocol.
///
/// The client stream must pass its protocol's checker (event order, block
/// indices, terminal events), decode to a well-formed event sequence, and
/// say what the vendor said: the same text, tool calls and finish, and the
/// reasoning when the vendor's was readable.
@Suite struct GatewayMatrixTests {
    @Test(arguments: gatewayMatrix)
    func clientStreamSaysWhatTheVendorSaid(_ client: GatewayClient, _ upstream: String) async throws {
        let recording = Recording.named(upstream)
        let target = try #require(recording.target)
        let request = Recording.named(client.recording)
        let replay = ReplayTransport([recording])
        let gateway = replayGateway(defaultModel: target, registry: registry(target, speaking: recording.wire), transport: replay)

        let response = try await Application(router: buildRouter(gateway: gateway)).test(.router) { http in
            try await http.post(client.uri(model: request.model ?? "gemini-3-pro-preview"), bytes: try #require(request.requestBytes))
        }
        #expect(response.status == .ok, "\(String(buffer: response.body).prefix(500))")
        #expect(response.headers[Gateway.modelHeader] == target)
        #expect(response.headers[.contentType] == "text/event-stream")

        // The upstream got the client's conversation in its own protocol.
        let sent = try #require(replay.requests.first)
        #expect(replay.requests.count == 1)
        let suffix = switch recording.wire {
        case .chatCompletions: "/chat/completions"
        case .responses: "/responses"
        case .anthropicMessages: "/v1/messages"
        case .gemini: ":streamGenerateContent"
        }
        #expect(sent.route.hasSuffix(suffix), "\(sent.route)")

        // A valid stream for the client, saying what the vendor said.
        var parser = SSEParser()
        let elements = try parser.parse(Array(response.body.readableBytesView))
        parser.finish()
        #expect(Codecs.checkStream(elements, as: client.wire) == [])
        let (events, _) = try Codecs.decodeStream(elements, as: client.wire, origin: nil)
        #expect(checkEventSequence(events) == [])
        let accumulated = WireResponseAccumulator(events)
        let got = ReplySummary(accumulated.response, errors: accumulated.errors)
        let facts = try #require(recording.facts)
        #expect(got.text == facts["text"]?.stringValue)
        #expect(got.toolCalls.map(\.name) == (facts["toolCalls"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
        #expect(got.toolCalls.map(\.arguments) == (facts["toolCalls"]?.arrayValue ?? []).map { $0["arguments"]?.canonical ?? .null })
        #expect(got.unifiedFinish == ReplySummary(try recording.decodeReply().response).unifiedFinish)
        if let reasoning = facts["reasoning"]?.stringValue, !reasoning.isEmpty {
            #expect(!got.reasoning.isEmpty, "the vendor's reasoning did not reach the client")
        }
        #expect(got.error == nil)
    }

    // MARK: Fallback

    /// Claude Code against Claude, overloaded (529, `Retry-After`): the
    /// gateway falls back to each other vendor in turn, and Claude Code
    /// gets that vendor's answer as an Anthropic stream.
    @Test(arguments: ["deepseek/reasoning-stream", "gemini/3-tool-call-stream", "xai/responses-reasoning-then-call", "mistral/parallel-tools-stream"])
    func claudeCodeFallsBackWhenClaudeIsOverloaded(_ fallback: String) async throws {
        let overloaded = Recording.named("anthropic/error-overloaded-529")
        let next = Recording.named(fallback)
        let target = try #require(next.target)
        let replay = ReplayTransport([overloaded, next])
        let gateway = replayGateway(
            defaultModel: try #require(overloaded.target), fallbacks: [target],
            registry: registry(target, speaking: next.wire), transport: replay,
        )
        let claudeCode = Recording.named("clients/claude-code")
        let response = try await Application(router: buildRouter(gateway: gateway)).test(.router) { http in
            try await http.post("/v1/messages", bytes: try #require(claudeCode.requestBytes))
        }
        #expect(response.status == .ok)
        #expect(response.headers[Gateway.modelHeader] == target)
        #expect(replay.requests.count == 2)
        #expect(replay.requests.first?.header("x-api-key") == "key-anthropic")

        var parser = SSEParser()
        let elements = try parser.parse(Array(response.body.readableBytesView))
        parser.finish()
        #expect(Codecs.checkStream(elements, as: .anthropicMessages) == [])
        let (events, _) = try Codecs.decodeStream(elements, as: .anthropicMessages, origin: nil)
        let got = ReplySummary(WireResponseAccumulator(events).response)
        #expect(got.text == next.facts?["text"]?.stringValue)
        #expect(got.toolCalls.map(\.name) == (next.facts?["toolCalls"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
    }

    /// Every candidate fails: the client gets the last vendor's status and
    /// message in its own protocol's error shape (verbatim, with
    /// `Retry-After`, when the protocols match).
    @Test(arguments: GatewayClient.all)
    func lastUpstreamErrorReachesTheClient(_ client: GatewayClient) async throws {
        let overloaded = Recording.named("anthropic/error-overloaded-529")
        let limited = Recording.named("gemini/error-429-retry-info")
        let replay = ReplayTransport([overloaded, limited])
        let fallback = try #require(limited.target)
        let gateway = replayGateway(
            defaultModel: try #require(overloaded.target), fallbacks: [fallback],
            registry: registry(fallback, speaking: .gemini), transport: replay,
        )
        let request = Recording.named(client.recording)
        let response = try await Application(router: buildRouter(gateway: gateway)).test(.router) { http in
            try await http.post(client.uri(model: "gemini-3-pro-preview"), bytes: try #require(request.requestBytes))
        }
        #expect(response.status.code == 429)
        #expect(replay.requests.count == 2)
        let body = Array(response.body.readableBytesView)
        let message = try #require(limited.facts?["error"]?.stringValue)
        if client.wire == .gemini {
            #expect(body == limited.responseBytes)
        } else {
            #expect(String(decoding: body, as: UTF8.self).contains(String(message.prefix(60))))
            let json = try JSONValue(parsing: body)
            switch client.wire {
            case .anthropicMessages: #expect(json["type"] == "error" && json["error"]?["message"] != nil)
            case .chatCompletions, .responses: #expect(json["error"]?["message"] != nil)
            case .gemini: break
            }
        }
    }
}
