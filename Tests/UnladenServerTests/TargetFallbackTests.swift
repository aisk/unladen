import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private let primary = "together/llama-3.3-70b"
private let secondary = "deepseek/deepseek-chat"

/// A route to `primary`, then `secondary`, keeping conversations past
/// `limit` tokens where they are.
private func fallbackGateway(_ upstream: MockUpstream, limit: Int? = 1000) -> Gateway {
    makeGateway(upstream, model: nil, routes: [
        Route(name: "m", targets: [RouteTarget(model: primary), RouteTarget(model: secondary)], fallbackMaxContext: limit),
    ])
}

/// Which provider a request went to, by its key (`key-<provider>`).
private func provider(_ hit: UpstreamHit) -> String {
    String((hit.header("authorization") ?? "").dropFirst("Bearer key-".count))
}

/// The primary rate limited, the secondary answering.
private func primaryRateLimited() -> MockUpstream {
    MockUpstream { hit in
        provider(hit) == "together"
            ? reply(status: .tooManyRequests, headers: [.retryAfter: "70"], #"{"error":{"message":"rate limited"}}"#)
            : reply(fixture("Chat/responses/text.json"))
    }
}

/// A Chat request whose last user message is `text`; with `earlier`, after
/// a turn of the model.
private func chat(_ text: String, earlier: Bool = true) -> String {
    let turns = earlier ? #"{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"},"# : ""
    return #"{"model":"m","messages":[\#(turns){"role":"user","content":"\#(text)"}]}"#
}

private let long = String(repeating: "word ", count: 2000)

private let session: HTTPFields = [HTTPField.Name("x-session-id")!: "s-1"]

@Suite struct TargetFallbackTests {
    @Test func aFailingTargetFallsBackToTheNext() async throws {
        let upstream = primaryRateLimited()
        try await makeApp(fallbackGateway(upstream, limit: nil)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", chat(long))
            #expect(response.status == .ok)
            #expect(response.headers[Gateway.modelHeader] == secondary)
        }
        #expect(upstream.requests.map(provider) == ["together", "deepseek"])
    }

    @Test func aShortConversationFallsBack() async throws {
        let upstream = primaryRateLimited()
        try await makeApp(fallbackGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", chat("Go on"))
            #expect(response.status == .ok)
        }
        #expect(upstream.requests.map(provider) == ["together", "deepseek"])
    }

    @Test func aLongConversationWaitsForItsTarget() async throws {
        let upstream = primaryRateLimited()
        try await makeApp(fallbackGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", chat(long))
            #expect(response.status == .tooManyRequests)
            #expect(response.headers[.retryAfter] == "70")
        }
        #expect(upstream.requests.map(provider) == ["together"])
    }

    @Test func aLongNewConversationFallsBack() async throws {
        let upstream = primaryRateLimited()
        try await makeApp(fallbackGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", chat(long, earlier: false))
            #expect(response.status == .ok)
        }
        #expect(upstream.requests.map(provider) == ["together", "deepseek"])
    }

    @Test func aLongConversationStaysWhereItWasLastAnswered() async throws {
        let failing = Locked(true)
        let upstream = MockUpstream { hit in
            provider(hit) == "together" && failing.current
                ? reply(status: .tooManyRequests, #"{"error":{"message":"rate limited"}}"#)
                : reply(fixture("Chat/responses/text.json"))
        }
        let gateway = fallbackGateway(upstream)
        try await makeApp(gateway).test(.router) { client in
            // Short: it moves to the secondary.
            var response = try await client.post("/v1/chat/completions", chat("Go on"), headers: session)
            #expect(response.status == .ok)
            // The primary is back, but the conversation has grown: it stays.
            failing.withLock { $0 = false }
            gateway.health.forget { _ in true }
            response = try await client.post("/v1/chat/completions", chat(long), headers: session)
            #expect(response.status == .ok)
            #expect(response.headers[Gateway.modelHeader] == secondary)
            // Another conversation starts on the primary.
            response = try await client.post("/v1/chat/completions", chat(long), headers: [HTTPField.Name("x-session-id")!: "s-2"])
            #expect(response.headers[Gateway.modelHeader] == primary)
        }
        #expect(upstream.requests.map(provider) == ["together", "deepseek", "deepseek", "together"])
    }

    @Test func theInputReportedForTheLastTurnCounts() async throws {
        // A short request whose upstream counted 50000 tokens of input.
        let counted = #"{"id":"c","object":"chat.completion","created":1,"model":"x","choices":[{"index":0,"#
            + #""message":{"role":"assistant","content":"Hi"},"finish_reason":"stop"}],"#
            + #""usage":{"prompt_tokens":50000,"completion_tokens":2,"total_tokens":50002}}"#
        let failing = Locked(false)
        let upstream = MockUpstream { hit in
            provider(hit) == "together" && failing.current
                ? reply(status: .tooManyRequests, #"{"error":{"message":"rate limited"}}"#)
                : reply(counted)
        }
        let gateway = fallbackGateway(upstream)
        try await makeApp(gateway).test(.router) { client in
            var response = try await client.post("/v1/chat/completions", chat("Go on"), headers: session)
            #expect(response.status == .ok)
            let conversation = try #require(Placements.conversation(RequestOrigin(program: "x", session: "s-1"), model: "m"))
            #expect(gateway.placements.placement(for: conversation)?.reportedInput == 50000)
            // Short as it looks, it is long: it waits.
            failing.withLock { $0 = true }
            response = try await client.post("/v1/chat/completions", chat("Go on, please"), headers: session)
            #expect(response.status == .tooManyRequests)
        }
        #expect(upstream.requests.map(provider) == ["together", "together"])
    }

    @Test func aStreamsReportedInputCounts() async throws {
        let chunks = [
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"x","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":null}]}"#,
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"x","choices":[],"usage":{"prompt_tokens":42000,"completion_tokens":2,"total_tokens":42002}}"#,
        ]
        let upstream = MockUpstream { _ in
            reply(streaming: AsyncStream { continuation in
                continuation.yield(Array((chunks.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8))
                continuation.finish()
            })
        }
        let gateway = fallbackGateway(upstream)
        try await makeApp(gateway).test(.router) { client in
            let body = #"{"model":"m","stream":true,"messages":[{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"},{"role":"user","content":"Go on"}]}"#
            let response = try await client.post("/v1/chat/completions", body, headers: session)
            #expect(response.status == .ok)
        }
        let conversation = try #require(Placements.conversation(RequestOrigin(program: "x", session: "s-1"), model: "m"))
        let placement = gateway.placements.placement(for: conversation)
        #expect(placement?.reference == primary)
        #expect(placement?.reportedInput == 42000)
    }

    @Test func keptPlaces() throws {
        func request(_ protocol: WireProtocol, _ body: String) throws -> WireRequest {
            try ClientCodec.parseRequest(`protocol`, body: Array(body.utf8), geminiPath: nil).value
        }
        let target = try ProviderRegistry.builtIn.resolve(primary)
        let other = try ProviderRegistry.builtIn.resolve(secondary)
        let candidates = [
            Candidate(reference: primary, target: target, apiKey: "a", keyName: "a"),
            Candidate(reference: secondary, target: other, apiKey: "b", keyName: "b"),
        ]
        let now = ContinuousClock.now
        func keep(_ request: WireRequest, limit: Int? = 1000, placement: Placement? = nil, on: [Candidate] = candidates) -> KeptPlace? {
            KeptPlace.keep(
                request, estimate: ConversationContext.estimatedTokens(request), candidates: on, limit: limit,
                placement: placement, now: now,
            )
        }
        func placed(_ reference: String, ago: Duration = .seconds(10), estimate: Int? = nil, input: Int? = nil) -> Placement {
            Placement(reference: reference, at: now - ago, estimate: estimate, reportedInput: input)
        }

        let longChat = try request(.chatCompletions, chat(long))
        let estimate = ConversationContext.estimatedTokens(longChat)
        #expect(keep(longChat)?.reference == primary)
        #expect(keep(longChat)?.reported == nil)
        #expect(keep(longChat, placement: placed(secondary))?.reference == secondary)
        // A place that is no candidate any more: the first.
        #expect(keep(longChat, placement: placed("openai/gpt-4o"))?.reference == primary)
        #expect(keep(longChat, limit: 100_000) == nil)
        #expect(keep(longChat, limit: nil) == nil)
        #expect(keep(longChat, on: [candidates[0]]) == nil)

        // The upstream's count of the last turn, plus the estimate of what came since.
        let counted = keep(longChat, placement: placed(primary, estimate: estimate - 100, input: 40000))
        #expect(counted?.context == 40100)
        #expect(counted?.reported == 40000)
        // It can tell a long-looking conversation is short.
        #expect(keep(longChat, placement: placed(primary, estimate: estimate - 100, input: 500)) == nil)
        // Without the estimate of the last turn, the whole is estimated.
        #expect(keep(longChat, placement: placed(primary, input: 500))?.context == estimate)

        // A cache gone cold has nothing to lose: five minutes, an hour at
        // some providers and when the request asks for an hour.
        #expect(keep(longChat, placement: placed(primary, ago: .seconds(400))) == nil)
        #expect(keep(longChat, placement: placed(secondary, ago: .seconds(400)))?.reference == secondary)
        #expect(keep(longChat, placement: placed(secondary, ago: .seconds(4000))) == nil)
        let hour = try request(.anthropicMessages, #"""
        {"model":"m","max_tokens":10,"messages":[{"role":"user","content":"Hi"},{"role":"assistant","content":"Hello"},
          {"role":"user","content":[{"type":"text","text":"\#(long)","cache_control":{"type":"ephemeral","ttl":"1h"}}]}]}
        """#)
        #expect(keep(hour, placement: placed(primary, ago: .seconds(400)))?.reference == primary)

        // A reply the upstream keeps holds the context: kept however short,
        // where it was answered, however long ago. Not knowing where, it is not kept.
        let stored = try request(.responses, #"{"model":"m","input":"Go on","previous_response_id":"resp_1"}"#)
        #expect(keep(stored, placement: placed(secondary, ago: .seconds(4000)))?.storedReply == true)
        #expect(keep(stored, placement: placed(secondary, ago: .seconds(4000)))?.reference == secondary)
        #expect(keep(stored) == nil)
        #expect(keep(try request(.responses, #"{"model":"m","input":"Go on"}"#), limit: 1) == nil)

        // A tool result is an earlier turn of the model.
        let tool = try request(.anthropicMessages, #"""
        {"model":"m","max_tokens":10,"messages":[{"role":"user","content":[
          {"type":"tool_result","tool_use_id":"t1","content":"\#(long)"}]}]}
        """#)
        #expect(ConversationContext.continues(tool))
        #expect(keep(tool) != nil)
    }

    @Test func aReplyEndingLateDoesNotOverwriteALaterRequestsPlacement() throws {
        let placements = Placements()
        let first = placements.ticket(for: "c")
        let second = placements.ticket(for: "c")
        placements.answering(primary, estimate: 100_000, for: first)
        placements.answering(primary, estimate: 5000, for: second)
        placements.answered(first, input: 100_000)
        #expect(placements.placement(for: "c")?.estimate == 5000)
        #expect(placements.placement(for: "c")?.reportedInput == nil)
        placements.answered(second, input: 5200)
        #expect(placements.placement(for: "c")?.reportedInput == 5200)
    }

    @Test func hourLongCachesAreKnownUnderAnyProviderName() throws {
        let loaded = try ConfigFile.parse(#"""
        { "accounts": {
            "ds-work": { "preset": "deepseek", "key": "sk-1" },
            "ds-relay": { "endpoints": { "chat": "https://api.deepseek.com/v1" }, "key": "sk-2" },
            "elsewhere": { "endpoints": { "chat": "https://llm.example.com/v1" }, "key": "sk-3" },
        } }
        """#) { _ in nil }
        let registry = loaded.gateway.registry
        #expect(ConversationContext.cachesForAnHour(try registry.resolve("deepseek/deepseek-chat")))
        #expect(ConversationContext.cachesForAnHour(try registry.resolve("ds-work/deepseek-chat")))
        #expect(ConversationContext.cachesForAnHour(try registry.resolve("ds-relay/deepseek-chat")))
        #expect(ConversationContext.cachesForAnHour(try registry.resolve("chatgpt/gpt-5")))
        #expect(!ConversationContext.cachesForAnHour(try registry.resolve("elsewhere/deepseek-chat")))
        #expect(!ConversationContext.cachesForAnHour(try registry.resolve("anthropic/claude-sonnet-4-5")))
    }

    @Test func aConversationTakenUpAfterAWeekendIsStillPlaced() {
        let placements = Placements()
        placements.answering(primary, estimate: 100_000, for: placements.ticket(for: "c"))
        let now = ContinuousClock.now
        #expect(placements.placement(for: "c", now: now + .seconds(3 * 24 * 3600))?.reference == primary)
        #expect(placements.placement(for: "c", now: now + .seconds(31 * 24 * 3600)) == nil)
    }

    @Test func theRecordSaysWhyATargetWasPassedOver() async throws {
        let upstream = primaryRateLimited()
        let gateway = fallbackGateway(upstream)
        try await makeApp(gateway).test(.router) { client in
            // Tried and refused: an attempt.
            var response = try await client.post("/v1/chat/completions", chat("Go on"))
            #expect(response.status == .ok)
            // Cooling down now: passed over without a try.
            response = try await client.post("/v1/chat/completions", chat("Go on, please"))
            #expect(response.status == .ok)
            // Long: kept on the primary, the secondary left out.
            response = try await client.post("/v1/chat/completions", chat(long), headers: [HTTPField.Name("x-session-id")!: "s-9"])
            #expect(response.status == .tooManyRequests)
        }
        let records = gateway.activity.snapshot().recent.sorted { $0.id < $1.id }
        try #require(records.count == 3)
        #expect(records[0].route == "m")
        #expect(records[0].targets == [primary, secondary])
        #expect(records[0].target == 2)
        #expect(records[0].attempts.map(\.outcome) == ["429", "ok"])
        #expect(records[0].passedOver.isEmpty)

        #expect(records[1].attempts.map(\.model) == [secondary])
        let passed = try #require(records[1].passedOver.first)
        #expect(passed.reference == primary && passed.why == "cooling" && passed.last == "429")
        #expect((passed.seconds ?? 0) > 0)

        #expect(records[2].kept?.reference == primary)
        // The primary was tried; the secondary, left out, came after it.
        #expect(records[2].passedOver.map(\.why) == ["kept"])
        let json = AdminActivity.json(records[2])
        #expect(json["kept"]?["limit"]?.numberValue?.int == 1000)
        #expect(json["passed_over"]?[0]?["why"]?.stringValue == "kept")
    }

    @Test func changesAreGroupedByKindAndPlace() {
        let changes = RequestRecord.Change.summary(
            request: [
                WireWarning(.droppedField, "reasoning_content cannot be carried", path: "messages[1].reasoning_content"),
                WireWarning(.droppedField, "reasoning_content cannot be carried", path: "messages[3].reasoning_content"),
                WireWarning(.adjusted, "clamped", path: "max_tokens"),
            ],
            reply: [WireWarning(.droppedField, "x", path: "choices[0].logprobs")],
        )
        #expect(changes.map(\.path) == ["messages[*].reasoning_content", "max_tokens", "choices[*].logprobs"])
        #expect(changes.map(\.count) == [2, 1, 1])
        #expect(changes.map(\.side) == ["request", "request", "reply"])
    }

    @Test func contextEstimates() {
        #expect(ConversationContext.estimatedTokens("abcdefgh") == 2)
        #expect(ConversationContext.estimatedTokens("你好世界") == 4)
        #expect(ConversationContext.estimatedTokens("ab你好") == 3)
        #expect(ConversationContext.estimatedTokens("") == 0)
    }
}
