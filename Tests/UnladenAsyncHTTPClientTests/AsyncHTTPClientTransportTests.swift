import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
import UnladenAsyncHTTPClient
import UnladenCore

/// Records whether the server-side streaming handler stopped.
private actor StreamProbe {
    private var ended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markEnded() {
        ended = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func waitForEnd() async {
        if ended { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func makeApplication(probe: StreamProbe) -> some ApplicationProtocol {
    let router = Router()
    router.post("echo") { request, _ -> Response in
        let body = try await request.body.collect(upTo: 1 << 20)
        var headers: HTTPFields = [.contentType: "application/octet-stream"]
        headers[HTTPField.Name("x-echo")!] = request.headers[HTTPField.Name("x-test")!]
        return Response(status: .created, headers: headers, body: ResponseBody(byteBuffer: body))
    }
    router.get("error") { _, _ -> Response in
        Response(
            status: .tooManyRequests,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: #"{"error":{"message":"rate limited"}}"#)),
        )
    }
    router.get("stream") { _, _ -> Response in
        Response(
            status: .ok,
            headers: [.contentType: "text/event-stream"],
            body: ResponseBody { writer in
                // Never finishes on its own: only a client disconnect stops it.
                var i = 0
                do {
                    while true {
                        try await writer.write(ByteBuffer(string: "data: \(i)\n\n"))
                        i += 1
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } catch {
                    await probe.markEnded()
                    throw error
                }
            },
        )
    }
    router.get("slow-head") { _, _ -> Response in
        // Hummingbird waits for in-flight handlers at shutdown, so keep this short.
        try await Task.sleep(for: .seconds(3))
        return Response(status: .ok)
    }
    // The live test framework binds to localhost on an ephemeral port.
    return Application(router: router)
}

private func request(_ method: HTTPRequest.Method, _ path: String, port: Int) -> HTTPRequest {
    HTTPRequest(method: method, scheme: "http", authority: "localhost:\(port)", path: path)
}

@Suite(.timeLimit(.minutes(1)))
struct AsyncHTTPClientTransportTests {
    @Test func sendsBodyAndHeaders() async throws {
        try await makeApplication(probe: StreamProbe()).test(.live) { client in
            let port = try #require(client.port)
            var outgoing = request(.post, "/echo", port: port)
            outgoing.headerFields[HTTPField.Name("x-test")!] = "hello"
            let payload = Array(#"{"model":"m","temperature":1.0}"#.utf8)
            let response = try await AsyncHTTPClientTransport(timeout: .seconds(20)).send(outgoing, body: payload)
            #expect(response.status == .created)
            #expect(response.response.headerFields[HTTPField.Name("x-echo")!] == "hello")
            #expect(try await response.body.collect(upTo: 1 << 20) == payload)
        }
    }

    @Test func non2xxIsReturnedNotThrown() async throws {
        try await makeApplication(probe: StreamProbe()).test(.live) { client in
            let port = try #require(client.port)
            let transport = AsyncHTTPClientTransport(timeout: .seconds(20))
            let response = try await transport.send(request(.get, "/error", port: port), body: nil)
            #expect(response.status == .tooManyRequests)
            #expect(response.response.headerFields[.contentType] == "application/json")
            let body = try await response.body.collect(upTo: 1 << 20)
            #expect(String(decoding: body, as: UTF8.self) == #"{"error":{"message":"rate limited"}}"#)
        }
    }

    @Test func cancellingConsumerCancelsUpstream() async throws {
        let probe = StreamProbe()
        try await makeApplication(probe: probe).test(.live) { client in
            let port = try #require(client.port)
            // No deadline: only cancellation can end this request.
            let transport = AsyncHTTPClientTransport()
            let (progress, progressContinuation) = AsyncStream<Int>.makeStream()

            let consumer = Task {
                let response = try await transport.send(request(.get, "/stream", port: port), body: nil)
                #expect(response.status == .ok)
                var received = 0
                for try await element in response.body.sseElements() {
                    guard case .event(let event) = element else { continue }
                    #expect(event.data == String(received))
                    received += 1
                    progressContinuation.yield(received)
                }
            }

            // Wait for a few streamed events, proving the body is incremental.
            for await count in progress where count >= 3 {
                break
            }
            let clock = ContinuousClock()
            let cancelledAt = clock.now
            consumer.cancel()
            _ = await consumer.result

            // The server's write loop only ends when the connection goes away.
            await probe.waitForEnd()
            #expect(clock.now - cancelledAt < .seconds(5))
        }
    }

    @Test func cancellingWhileAwaitingHeadThrows() async throws {
        try await makeApplication(probe: StreamProbe()).test(.live) { client in
            let port = try #require(client.port)
            let transport = AsyncHTTPClientTransport(timeout: .seconds(20))
            let clock = ContinuousClock()
            let start = clock.now
            let task = Task {
                try await transport.send(request(.get, "/slow-head", port: port), body: nil)
            }
            try await Task.sleep(for: .milliseconds(200))
            task.cancel()
            await #expect(throws: (any Error).self) {
                try await task.value
            }
            #expect(clock.now - start < .seconds(2))
        }
    }

    @Test func timeoutCoversTheExchange() async throws {
        try await makeApplication(probe: StreamProbe()).test(.live) { client in
            let port = try #require(client.port)
            let transport = AsyncHTTPClientTransport(timeout: .milliseconds(200))
            let clock = ContinuousClock()
            let start = clock.now
            await #expect(throws: (any Error).self) {
                try await transport.send(request(.get, "/slow-head", port: port), body: nil)
            }
            #expect(clock.now - start < .seconds(2))
        }
    }

    @Test func requestWithoutAuthorityIsRejected() async throws {
        let bad = HTTPRequest(method: .get, scheme: "http", authority: nil, path: "/")
        await #expect(throws: HTTPTransportError.self) {
            try await AsyncHTTPClientTransport(timeout: .seconds(20)).send(bad, body: nil)
        }
    }
}
