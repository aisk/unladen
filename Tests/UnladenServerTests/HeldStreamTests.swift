import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private let roleChunk = #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#
private let textChunk = #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#
private let stopChunk = #"{"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#

/// A Chat stream whose content comes after `delay`.
private func slowStream(_ delay: Duration) -> HTTPTransportResponse {
    reply(streaming: AsyncStream { continuation in
        let task = Task {
            continuation.yield(Array("data: \(roleChunk)\n\n".utf8))
            try? await Task.sleep(for: delay)
            continuation.yield(Array("data: \(textChunk)\n\ndata: \(stopChunk)\n\ndata: [DONE]\n\n".utf8))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    })
}

/// An error status after `delay`.
private func slowError(_ delay: Duration, status: HTTPResponse.Status, _ body: String) -> MockUpstream.Handler {
    { _ in
        try await Task.sleep(for: delay)
        return reply(status: status, body)
    }
}

private func quickHolds(_ gateway: inout Gateway) {
    gateway.heldStreams = Gateway.HeldStreams(headersAfter: .milliseconds(100), commentEvery: .milliseconds(100))
}

@Suite struct HeldStreamTests {
    @Test func slowContentGetsHeadersAndCommentsFirst() async throws {
        let upstream = MockUpstream { _ in slowStream(.milliseconds(500)) }
        var gateway = makeGateway(upstream)
        quickHolds(&gateway)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "x", stream: true))
            #expect(response.status == .ok)
            // Sent before anyone answered: no model to name.
            #expect(response.headers[Gateway.modelHeader] == nil)
            let stream = decodeStream(response.body, as: .anthropicMessages)
            #expect(String(buffer: response.body).ranges(of: ": keepalive\n").count >= 2, "\(String(buffer: response.body).prefix(200))")
            #expect(stream.text == "Hi")
            #expect(stream.errors.isEmpty)
            // Only comments came before the reply's first event.
            #expect(stream.eventNames.first == "message_start")
        }
    }

    @Test func aLaterKeyStillAnswersInTheSameResponse() async throws {
        let upstream = MockUpstream([
            slowError(.milliseconds(300), status: .tooManyRequests, #"{"error":{"message":"busy"}}"#),
            { _ in slowStream(.milliseconds(100)) },
        ])
        var gateway = makeGateway(upstream, keys: ["together": ["k1", "k2"]])
        quickHolds(&gateway)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .chatCompletions)
            #expect(!stream.comments.isEmpty)
            #expect(stream.text == "Hi")
            #expect(stream.errors.isEmpty)
        }
        #expect(upstream.requests.count == 2)
    }

    @Test func failureAfterTheHeadersIsTheStreamsError() async throws {
        let upstream = MockUpstream(slowError(.milliseconds(300), status: HTTPResponse.Status(code: 529), #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        var gateway = makeGateway(upstream, model: "anthropic/claude-sonnet-4-5")
        quickHolds(&gateway)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .anthropicMessages)
            #expect(!stream.comments.isEmpty)
            #expect(stream.errors.first?.message == "Overloaded")
            #expect(stream.errors.first?.type == "overloaded_error")
            #expect(stream.text.isEmpty)
        }
    }

    @Test func aQuickFailureIsStillAStatus() async throws {
        let upstream = MockUpstream { _ in reply(status: .tooManyRequests, headers: [.retryAfter: "7"], #"{"error":{"message":"busy"}}"#) }
        var gateway = makeGateway(upstream)
        quickHolds(&gateway)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .tooManyRequests)
            #expect(response.headers[.retryAfter] == "7")
        }
    }

    @Test func geminiClientsAreNeverSentComments() async throws {
        let upstream = MockUpstream(slowError(.milliseconds(300), status: .serviceUnavailable, #"{"error":{"message":"down"}}"#))
        var gateway = makeGateway(upstream)
        quickHolds(&gateway)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post(ClientRequest.geminiPath(model: "x", stream: true), ClientRequest.gemini)
            #expect(response.status == .serviceUnavailable)
            #expect(!String(buffer: response.body).contains(": keepalive"))
        }
    }

    @Test func streamErrorCodes() throws {
        let target = try ProviderRegistry.builtIn.resolve("openai/gpt-4o")
        let candidate = Candidate(reference: "openai/gpt-4o", target: target, apiKey: "k", keyName: "k")
        func failure(_ status: Int, _ message: String) -> Gateway.AttemptFailure {
            .upstream(candidate, UpstreamHTTPError(
                status: HTTPResponse.Status(code: status), headerFields: [:], body: Array(#"{"error":{"message":"\#(message)"}}"#.utf8),
            ))
        }
        #expect(Gateway.streamError(failure(400, "This model's maximum context length is 128000 tokens")).error.code == "context_length_exceeded")
        #expect(Gateway.streamError(failure(529, "Overloaded")).error.code == "server_is_overloaded")
        #expect(Gateway.streamError(failure(429, "slow down")).error.type == "rate_limit_error")
        let refused = Gateway.streamError(failure(401, "bad key sk-secret"))
        #expect(refused.status == 502)
        #expect(!refused.error.message.contains("sk-secret"))
        #expect(Gateway.streamError(.gateway(status: 504, message: "slow", candidate: nil)).error.code == "server_error")
    }
}
