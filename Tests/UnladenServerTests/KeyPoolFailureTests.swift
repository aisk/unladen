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
        var gateway = makeGateway(upstream, keys: keys)
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
        #expect(upstream.requests.count == 1)
        let target = try ProviderRegistry.builtIn.resolve(chatOnlyModel)
        let candidate = Candidate(reference: chatOnlyModel, target: target, apiKey: "k2", keyName: "k2")
        #expect(gateway.health.snapshot().isCooling(candidate.endpointScope))
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
        var gateway = makeGateway(upstream, keys: keys, keepalive: .milliseconds(50))
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

    @Test func timeoutsCanBeTurnedOff() throws {
        let loaded = try ConfigFile.parse(#"{ "server": { "head_timeout": "off", "idle_timeout": "90s" } }"#) { _ in nil }
        #expect(loaded.gateway.headTimeout == nil)
        #expect(loaded.gateway.idleTimeout == .seconds(90))
        #expect(throws: ConfigError.self) { try ConfigFile.parse(#"{ "server": { "keepalive": "off" } }"#) { _ in nil } }
    }
}
