import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private let claudeCode: HTTPFields = [
    .userAgent: "claude-cli/2.1.0 (external, cli)",
    HTTPField.Name("x-claude-code-session-id")!: "s-1",
]

private func chatStream(_ chunks: [String]) -> HTTPTransportResponse {
    reply(chunks.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n")
}

@Suite struct ActivityTests {
    @Test func aRepliedRequestIsRecordedWithItsAccountAndTokens() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        let gateway = makeGateway(upstream, keys: ["together": ["k1"]])
        try await makeApp(gateway).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"), headers: claudeCode)
        }
        let snapshot = gateway.activity.snapshot()
        #expect(snapshot.inFlight.isEmpty)
        let record = try #require(snapshot.recent.first)
        #expect(record.origin.program == "Claude Code")
        #expect(record.origin.session == "s-1")
        #expect(record.model == "x")
        #expect(record.provider == "together" && record.account == UpstreamKey(secret: "k1").name)
        #expect(record.served == "together/llama-3.3-70b")
        #expect(record.status == 200 && !record.failed)
        #expect(record.tokens == TokenCounts(input: 19, output: 10))
        #expect(record.attempts.map(\.outcome) == ["ok"])
        let session = try #require(snapshot.sessions.first)
        #expect(session.id == "s-1" && session.requests == 1 && session.tokens.output == 10)
    }

    @Test func eachAttemptIsRecorded() async throws {
        let upstream = MockUpstream([
            { _ in reply(status: .tooManyRequests, #"{"error":{"message":"slow down"}}"#) },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        let gateway = makeGateway(upstream, keys: ["together": ["k1", "k2"]])
        try await makeApp(gateway).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
        }
        let record = try #require(gateway.activity.snapshot().recent.first)
        #expect(record.attempts.map(\.outcome) == ["429", "ok"])
        #expect(record.attempts.map(\.account) == [UpstreamKey(secret: "k1").name, UpstreamKey(secret: "k2").name])
        #expect(record.account == UpstreamKey(secret: "k2").name)
    }

    @Test func aStreamAsksItsUpstreamForUsage() async throws {
        let upstream = MockUpstream { _ in
            chatStream([
                #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":null}]}"#,
                #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
                #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#,
            ])
        }
        let gateway = makeGateway(upstream)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            // The client did not ask for usage, so it is not sent one.
            #expect(!String(buffer: response.body).contains("prompt_tokens"))
        }
        #expect(upstream.requests.first?.json["stream_options"]?["include_usage"] == true)
        let record = try #require(gateway.activity.snapshot().recent.first)
        #expect(record.stream && record.status == 200)
        #expect(record.tokens == TokenCounts(input: 5, output: 2))
        #expect(record.firstContentMilliseconds != nil)
    }

    @Test func aFailedRequestIsCounted() async throws {
        let upstream = MockUpstream { _ in reply(status: .badRequest, #"{"error":{"message":"bad"}}"#) }
        let gateway = makeGateway(upstream)
        try await makeApp(gateway).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            _ = try await client.post("/v1/chat/completions", "not json")
        }
        let recent = gateway.activity.snapshot().recent
        #expect(recent.map(\.status) == [400, 400])
        #expect(recent.allSatisfy { $0.failed })
        // The upstream's refusal is counted against the account that refused.
        #expect(recent.map(\.provider) == [nil, "together"])
        let usage = gateway.activity.usage(days: 1).values
        #expect(usage.reduce(0) { $0 + $1.failures } == 2)
    }

    @Test func aSessionNotesWhenItsAccountChanges() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        let gateway = makeGateway(upstream, keys: ["together": ["k1", "k2"]], strategy: .rotate)
        try await makeApp(gateway).test(.router) { client in
            for _ in 0..<3 { _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"), headers: claudeCode) }
        }
        let session = try #require(gateway.activity.snapshot().sessions.first)
        #expect(session.requests == 3)
        #expect(session.accounts.count == 2)
        #expect(session.switches == 2)
        #expect(session.tokens == TokenCounts(input: 57, output: 30))
    }

    @Test func sessionIDs() throws {
        #expect(RequestOrigin.claudeCodeSession("user_abc_account_1234_session_5678-90") == "5678-90")
        #expect(RequestOrigin.claudeCodeSession(#"{"device_id":"d","session_id":"s-9"}"#) == "s-9")
        #expect(RequestOrigin.claudeCodeSession("someone") == nil)

        var request = try ChatCompletionsCodec.parseRequest(Array(ClientRequest.chat(model: "x").utf8)).value
        #expect(RequestOrigin.session(headers: [HTTPField.Name("session_id")!: "codex-1"], request: request) == "codex-1")
        // Without an id, how the conversation opens: the same for its later turns.
        let opening = RequestOrigin.session(headers: [:], request: request)
        #expect(opening?.hasPrefix("h-") == true)
        request.messages.append(WireMessage(role: .assistant, parts: [.text(WireText("Hello"))]))
        request.messages.append(WireMessage(role: .user, parts: [.text(WireText("More"))]))
        #expect(RequestOrigin.session(headers: [:], request: request) == opening)
        request.promptCacheKey = "cache-key"
        #expect(RequestOrigin.session(headers: [:], request: request) == "cache-key")

        #expect(RequestOrigin.program(userAgent: "codex_cli_rs/0.162.0 (Mac OS)") == "Codex")
        #expect(RequestOrigin.program(userAgent: "opencode/1.0") == "OpenCode")
        #expect(RequestOrigin.program(userAgent: "python-httpx/0.27") == "python-httpx")
        #expect(RequestOrigin.program(userAgent: nil) == "unknown")
    }

    @Test func usageIsLoggedAndReadBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unladen-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let activity = Activity(log: UsageLog(directory: directory))
        for (account, tokens) in [("work", 10), ("work", 20), ("personal", 5)] {
            var record = RequestRecord(
                started: LocalDay.nowMilliseconds(), origin: RequestOrigin(program: "Codex", session: "s-\(account)"),
                clientProtocol: "responses", model: "gpt-5", stream: true,
            )
            record.provider = "openai"
            let tracker = activity.begin(record)
            activity.update(tracker.id) { $0.account = account; $0.provider = "openai"; $0.served = "openai/gpt-5" }
            tracker.finish(status: 200, tokens: TokenCounts(input: tokens, output: 1))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        #expect(files.count == 1 && files[0].hasPrefix("usage-") && files[0].hasSuffix(".jsonl"))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory + "/" + files[0])[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let restored = Activity(log: UsageLog(directory: directory))
        restored.restore()
        let byAccount = Dictionary(grouping: restored.usage(days: 1)) { $0.key.account }.mapValues { buckets in
            buckets.reduce(TokenCounts()) { sum, bucket in
                var sum = sum
                sum += bucket.value.tokens
                return sum
            }
        }
        #expect(byAccount["work"] == TokenCounts(input: 30, output: 2))
        #expect(byAccount["personal"] == TokenCounts(input: 5, output: 1))
        #expect(Set(restored.snapshot().sessions.map(\.id)) == ["s-work", "s-personal"])
        // In memory only: not read back.
        #expect(restored.snapshot().recent.isEmpty)
    }
}
