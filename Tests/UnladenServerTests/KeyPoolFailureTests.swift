import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// A Chat stream: `chunks` as SSE data lines, then `[DONE]` unless `done` is false.
private func chatStream(_ chunks: [String], done: Bool = true) -> HTTPTransportResponse {
    var text = chunks.map { "data: \($0)\n\n" }.joined()
    if done { text += "data: [DONE]\n\n" }
    return reply(text)
}

private let roleChunk = #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#
private let textChunk = #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#
private let stopChunk = #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
private let errorChunk = #"{"error":{"message":"overloaded","type":"server_error"}}"#

private func keyScope(_ secret: String) -> HealthScope { .key(provider: "together", keyName: UpstreamKey(secret: secret).name) }

@Suite struct KeyPoolFailureTests {
    let keys = ["together": ["k1", "k2"]]

    @Test func errorEventBeforeContentMovesToTheNextKey() async throws {
        let upstream = MockUpstream([
            { _ in chatStream([roleChunk, errorChunk], done: false) },
            { _ in chatStream([roleChunk, textChunk, stopChunk]) },
        ])
        let gateway = makeGateway(upstream, keys: keys)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .chatCompletions)
            #expect(stream.text == "Hi")
            #expect(stream.errors.isEmpty)
        }
        #expect(upstream.requests.map { $0.header("authorization") } == ["Bearer k1", "Bearer k2"])
    }

    @Test func emptyStreamMovesToTheNextKey() async throws {
        let upstream = MockUpstream([
            { _ in chatStream([roleChunk], done: false) },
            { _ in chatStream([roleChunk, textChunk, stopChunk]) },
        ])
        try await makeApp(makeGateway(upstream, keys: keys)).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "x", stream: true))
            #expect(response.status == .ok)
            #expect(decodeStream(response.body, as: .anthropicMessages).text == "Hi")
        }
        #expect(upstream.requests.count == 2)
    }

    @Test func doneWithoutContentOrReasonMovesToTheNextKey() async throws {
        let upstream = MockUpstream([
            { _ in chatStream([roleChunk]) },
            { _ in chatStream([roleChunk, textChunk, stopChunk]) },
        ])
        try await makeApp(makeGateway(upstream, keys: keys)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            #expect(decodeStream(response.body, as: .chatCompletions).text == "Hi")
        }
        #expect(upstream.requests.map { $0.header("authorization") } == ["Bearer k1", "Bearer k2"])
    }

    @Test func anEmptyReplyThatSaysWhyItStoppedIsAnswered() async throws {
        let upstream = MockUpstream { _ in chatStream([roleChunk, stopChunk]) }
        try await makeApp(makeGateway(upstream, keys: keys)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .chatCompletions)
            #expect(stream.text.isEmpty)
            #expect(stream.finish?.reason?.unified == .stop)
        }
        #expect(upstream.requests.count == 1)
    }

    @Test func everyKeyFailingBeforeContentIsAnHTTPError() async throws {
        let upstream = MockUpstream { _ in chatStream([roleChunk, errorChunk], done: false) }
        try await makeApp(makeGateway(upstream, keys: keys)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .badGateway)
            #expect(json(response.body)["error"]?["message"]?.stringValue?.contains("overloaded") == true)
        }
        #expect(upstream.requests.count == 2)
    }

    @Test func slowFirstContentMovesOnWithoutCooling() async throws {
        let upstream = MockUpstream([
            { _ in
                reply(streaming: AsyncStream { continuation in
                    let task = Task {
                        continuation.yield(Array("data: \(roleChunk)\n\n".utf8))
                        try? await Task.sleep(for: .seconds(5))
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                })
            },
            { _ in chatStream([roleChunk, textChunk, stopChunk]) },
        ])
        let gateway = makeGateway(upstream, keys: keys)
        gateway.configuration.headTimeout = .milliseconds(200)
        let start = ContinuousClock.now
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            #expect(decodeStream(response.body, as: .chatCompletions).text == "Hi")
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(upstream.requests.count == 2)
        #expect(!gateway.health.snapshot().isCooling(keyScope("k1")))
    }

    @Test func unreachableAddressIsNotTriedWithTheOtherKeys() async throws {
        struct Refused: Error {}
        let upstream = MockUpstream { _ in throw Refused() }
        let gateway = makeGateway(upstream, keys: ["together": ["k1", "k2", "k3"]])
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .badGateway)
        }
        // The other keys are not tried; the first is, again, as nothing else is left.
        #expect(upstream.requests.map { $0.header("authorization") } == ["Bearer k1", "Bearer k1", "Bearer k1"])
        let target = try ProviderRegistry.builtIn.resolve(chatOnlyModel)
        let candidate = Candidate(reference: chatOnlyModel, target: target, apiKey: "k2", keyName: "k2")
        #expect(gateway.health.snapshot().isCooling(candidate.endpointScope))
    }

    @Test func theLastCandidateIsTriedAgainAfterAServerError() async throws {
        let upstream = MockUpstream([
            { _ in reply(status: .serviceUnavailable, #"{"error":{"message":"down"}}"#) },
            { _ in reply(status: .init(code: 529), #"{"error":{"message":"overloaded"}}"#) },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        let pauses = Locked<[Duration]>([])
        var gateway = makeGateway(upstream, keys: ["together": ["k1"]])
        gateway.pause = { wait in pauses.withLock { $0.append(wait) } }
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .ok)
        }
        #expect(upstream.requests.count == 3)
        #expect(pauses.current == [.seconds(1), .seconds(2)])
        let record = try #require(gateway.activity.snapshot().recent.first)
        #expect(record.attempts.map(\.outcome) == ["503", "529", "ok"])
    }

    @Test func theLastCandidateIsTriedTwiceMoreAtMost() async throws {
        let upstream = MockUpstream { _ in reply(status: .badGateway, #"{"error":{"message":"down"}}"#) }
        try await makeApp(makeGateway(upstream, keys: ["together": ["k1"]])).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .badGateway)
        }
        #expect(upstream.requests.count == 3)
    }

    @Test func aTryAgainWaitsAsAskedUpToALimit() async throws {
        let pauses = Locked<[Duration]>([])
        let upstream = MockUpstream([
            { _ in reply(status: .serviceUnavailable, headers: [.retryAfter: "5"], #"{"error":{"message":"down"}}"#) },
            { _ in reply(status: .tooManyRequests, headers: [.retryAfter: "3"], #"{"error":{"message":"busy"}}"#) },
            { _ in reply(status: .serviceUnavailable, headers: [.retryAfter: "30"], #"{"error":{"message":"down"}}"#) },
        ])
        var gateway = makeGateway(upstream, keys: ["together": ["k1"]])
        gateway.pause = { wait in pauses.withLock { $0.append(wait) } }
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .serviceUnavailable)
        }
        // Two tries more at most: the third reply ends the request.
        #expect(pauses.current == [.seconds(5), .seconds(3)])
        #expect(upstream.requests.count == 3)

        let long = MockUpstream { _ in reply(status: .serviceUnavailable, headers: [.retryAfter: "30"], #"{"error":{"message":"down"}}"#) }
        try await makeApp(makeGateway(long, keys: ["together": ["k1"]])).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
        }
        #expect(long.requests.count == 1)
    }

    @Test func aRateLimitWithoutAWaitOrAClientErrorIsNotTriedAgain() async throws {
        let limited = MockUpstream { _ in reply(status: .tooManyRequests, #"{"error":{"message":"busy"}}"#) }
        try await makeApp(makeGateway(limited, keys: ["together": ["k1"]])).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
        }
        #expect(limited.requests.count == 1)
        let refused = MockUpstream { _ in reply(status: .forbidden, #"{"error":{"message":"no"}}"#) }
        try await makeApp(makeGateway(refused, keys: ["together": ["k1"]])).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
        }
        #expect(refused.requests.count == 1)
    }

    @Test func aStreamEndingEmptyIsTriedAgain() async throws {
        let upstream = MockUpstream([
            { _ in chatStream([roleChunk]) },
            { _ in chatStream([roleChunk, textChunk, stopChunk]) },
        ])
        try await makeApp(makeGateway(upstream, keys: ["together": ["k1"]])).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            #expect(decodeStream(response.body, as: .chatCompletions).text == "Hi")
        }
        #expect(upstream.requests.count == 2)
    }

    @Test func repeatedRefusalsDisableAKeyUntilReload() async throws {
        let upstream = MockUpstream { hit in
            hit.header("authorization") == "Bearer k1"
                ? reply(status: .unauthorized, #"{"error":{"message":"bad key"}}"#)
                : reply(fixture("Chat/responses/text.json"))
        }
        let gateway = makeGateway(upstream, keys: keys)
        // One refusal already counted; the next one disables k1.
        _ = gateway.health.recordUnauthorized(keyScope("k1"))
        try await makeApp(gateway).test(.router) { client in
            var response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .ok)
            #expect(gateway.health.snapshot().disabled.contains(keyScope("k1")))
            let before = upstream.requests.count
            response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .ok)
            #expect(upstream.requests[before...].map { $0.header("authorization") } == ["Bearer k2"])

            // A reload gives it another chance.
            gateway.replace(gateway.configuration)
            #expect(gateway.health.snapshot().disabled.isEmpty)
            response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .ok)
        }
    }

    @Test func notFoundMovesToTheNextKey() async throws {
        let upstream = MockUpstream([
            { _ in reply(status: .notFound, #"{"error":{"message":"model not available for this key"}}"#) },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        try await makeApp(makeGateway(upstream, keys: keys)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .ok)
        }
        #expect(upstream.requests.count == 2)
    }

    @Test func stalledStreamEndsWithAnErrorAndCools() async throws {
        let upstream = MockUpstream { _ in
            reply(streaming: AsyncStream { continuation in
                let task = Task {
                    continuation.yield(Array("data: \(roleChunk)\n\ndata: \(textChunk)\n\n".utf8))
                    try? await Task.sleep(for: .seconds(5))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            })
        }
        let gateway = makeGateway(upstream, keys: keys, keepalive: .milliseconds(50))
        gateway.configuration.idleTimeout = .milliseconds(300)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .chatCompletions)
            #expect(stream.text == "Hi")
            #expect(stream.errors.first?.message.contains("stalled") == true)
        }
        let target = try ProviderRegistry.builtIn.resolve(chatOnlyModel)
        let candidate = Candidate(reference: chatOnlyModel, target: target, apiKey: "k1", keyName: "k1")
        #expect(gateway.health.snapshot().isCooling(candidate.modelScope))
    }

    @Test func aRateLimitNamingTheModelCoolsTheModelThroughTheKey() async throws {
        let limited = #"{"error":{"message":"Rate limit reached for model `llama-3.3-70b` in organization `org_1` on tokens per day (TPD)","type":"tokens"}}"#
        let upstream = MockUpstream([
            { _ in reply(status: .tooManyRequests, limited) },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        let gateway = makeGateway(upstream, keys: keys)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .ok)
        }
        #expect(upstream.requests.count == 2)
        let health = gateway.health.snapshot()
        let k1 = UpstreamKey(secret: "k1").name
        #expect(health.isCooling(.keyModel(provider: "together", keyName: k1, model: "llama-3.3-70b")))
        #expect(!health.isCooling(keyScope("k1")))
        #expect(!health.isCooling(.keyModel(provider: "together", keyName: k1, model: "other-model")))
    }

    @Test func aRateLimitNotNamingTheModelCoolsTheKey() async throws {
        let upstream = MockUpstream([
            { _ in reply(status: .tooManyRequests, #"{"error":{"message":"Rate limit reached for llama-3.3-70b-versatile"}}"#) },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        let gateway = makeGateway(upstream, keys: keys)
        try await makeApp(gateway).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
        }
        #expect(gateway.health.snapshot().isCooling(keyScope("k1")))
    }

    @Test func errorBodiesNamingAModel() {
        func names(_ text: String, _ model: String) -> Bool { Gateway.names(Array(text.utf8), model: model) }
        #expect(names("Rate limit reached for gpt-4o in organization org-x on tokens per min (TPM).", "gpt-4o"))
        #expect(names("Quota exceeded for metric: generate_content_free_tier_requests, limit: 50, model: gemini-2.5-pro", "gemini-2.5-pro"))
        #expect(names("limit for models/gemini-2.5-flash.", "gemini-2.5-flash"))
        #expect(names("Rate limit for Claude-Sonnet-4-5 exceeded", "claude-sonnet-4-5"))
        #expect(!names("Rate limit reached for gpt-4o-mini in organization org-x", "gpt-4o"))
        #expect(!names("model: gemini-2.5-pro-preview", "gemini-2.5-pro"))
        #expect(!names("model: gemini-2.5.1", "gemini-2.5"))
        #expect(!names("Rate limit reached", ""))
    }

    @Test func aSuspendedAccountRestsForHours() async throws {
        let suspended = #"{"error":{"code":403,"message":"This service has been disabled in this account for violation of Terms of Service.","status":"PERMISSION_DENIED"}}"#
        let upstream = MockUpstream([
            { _ in reply(status: .forbidden, suspended) },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        let gateway = makeGateway(upstream, keys: keys)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .ok)
        }
        let health = gateway.health.snapshot()
        let until = try #require(health.cooldowns[keyScope("k1")])
        #expect(until - health.now > .seconds(3600))
        #expect(health.reasons[keyScope("k1")] == "403: suspended")
    }

    @Test func cooldownsDoubleAndRetryAfterWins() {
        let health = HealthStore()
        let scope = keyScope("k1")
        health.recordFailure(scope, base: .seconds(10))
        let first = health.snapshot().cooldowns[scope]!
        health.recordFailure(scope, base: .seconds(10))
        let second = health.snapshot().cooldowns[scope]!
        #expect(second - first > .seconds(9))
        health.recordFailure(scope, base: .seconds(10), retryAfter: .seconds(1000))
        let capped = health.snapshot().cooldowns[scope]! - ContinuousClock.now
        #expect(capped <= HealthStore.maxCooldown && capped > .seconds(290))
    }

    @Test func waitsUpstreamsAskFor() throws {
        let now = Date(timeIntervalSince1970: 784_111_717) // Sun, 06 Nov 1994 08:48:37 GMT
        func fields(_ pairs: [String: String]) -> HTTPFields {
            var fields = HTTPFields()
            for (name, value) in pairs { fields[HTTPField.Name(name)!] = value }
            return fields
        }
        #expect(HealthStore.retryAfter("120", now: now) == .seconds(120))
        #expect(HealthStore.retryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now: now) == .seconds(60))
        #expect(HealthStore.retryAfter("Sun, 06 Nov 1994 08:47:37 GMT", now: now) == nil)
        #expect(HealthStore.retryAfter("Sunday, 06-Nov-94 08:49:37 GMT", now: now) == nil)
        #expect(HealthStore.httpDate("Thu, 29 Feb 2024 23:59:59 GMT") == Date(timeIntervalSince1970: 1_709_251_199))

        #expect(HealthStore.goDuration("1s") == .seconds(1))
        #expect(HealthStore.goDuration("6m0s") == .seconds(360))
        #expect(HealthStore.goDuration("250ms") == .milliseconds(250))
        #expect(HealthStore.goDuration("1h2m3.5s") == .milliseconds(3_723_500))
        #expect(HealthStore.goDuration("soon") == nil)

        // Retry-After wins over the reset headers.
        #expect(HealthStore.retryAfter(fields(["retry-after": "7", "x-ratelimit-reset-tokens": "6m0s"]), now: now) == .seconds(7))
        // The exhausted limit decides.
        #expect(HealthStore.retryAfter(fields([
            "x-ratelimit-remaining-requests": "99", "x-ratelimit-reset-requests": "250ms",
            "x-ratelimit-remaining-tokens": "0", "x-ratelimit-reset-tokens": "6m0s",
        ]), now: now) == .seconds(360))
        // Without a count, the soonest.
        #expect(HealthStore.retryAfter(fields(["x-ratelimit-reset-requests": "2s", "x-ratelimit-reset-tokens": "1m"]), now: now) == .seconds(2))
        #expect(HealthStore.retryAfter(fields([
            "anthropic-ratelimit-tokens-remaining": "0", "anthropic-ratelimit-tokens-reset": "1994-11-06T08:49:07Z",
        ]), now: now) == .seconds(30))
        #expect(HealthStore.retryAfter(fields(["x-ratelimit-reset": "784111747000"]), now: now) == .seconds(30))
        #expect(HealthStore.retryAfter(fields(["x-ratelimit-reset": "784111747"]), now: now) == .seconds(30))
        #expect(HealthStore.retryAfter(fields([:]), now: now) == nil)
    }

    @Test func aRateLimitResetHeaderSetsTheCooldown() async throws {
        let upstream = MockUpstream([
            { _ in
                reply(status: .tooManyRequests, headers: [HTTPField.Name("x-ratelimit-reset-requests")!: "2m0s"], #"{"error":{"message":"busy"}}"#)
            },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        let gateway = makeGateway(upstream, keys: keys)
        try await makeApp(gateway).test(.router) { client in
            _ = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
        }
        let health = gateway.health.snapshot()
        let until = try #require(health.cooldowns[keyScope("k1")])
        #expect(until - health.now > .seconds(100) && until - health.now <= .seconds(120))
    }

    @Test func timeoutsCanBeTurnedOff() throws {
        let loaded = try ConfigFile.parse(#"{ "advanced": { "head_timeout": "off", "idle_timeout": "90s" } }"#) { _ in nil }
        #expect(loaded.gateway.headTimeout == nil)
        #expect(loaded.gateway.idleTimeout == .seconds(90))
        #expect(throws: ConfigError.self) { try ConfigFile.parse(#"{ "advanced": { "keepalive": "off" } }"#) { _ in nil } }
    }
}
