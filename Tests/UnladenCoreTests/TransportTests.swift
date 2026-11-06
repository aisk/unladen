import HTTPTypes
import Testing
import UnladenCore

@Suite struct TransportTests {
    @Test func mockTransportReturnsNon2xxWithBody() async throws {
        let transport: any HTTPTransport = MockTransport(
            status: .tooManyRequests,
            headerFields: [.contentType: "application/json"],
            chunks: [Array(#"{"error":"#.utf8), Array(#""slow down"}"#.utf8)],
        )
        let request = HTTPRequest(method: .post, scheme: "https", authority: "api.example.com", path: "/v1/chat/completions")
        let response = try await transport.send(request, body: Array("{}".utf8))
        #expect(response.status == .tooManyRequests)
        #expect(response.response.headerFields[.contentType] == "application/json")
        #expect(try await response.body.collect(upTo: 1024) == Array(#"{"error":"slow down"}"#.utf8))
    }

    @Test func mockTransportSeesRequest() async throws {
        let transport = MockTransport { request, body in
            #expect(request.path == "/echo")
            return HTTPTransportResponse(response: HTTPResponse(status: .ok), body: HTTPResponseBody(bytes: body ?? []))
        }
        let request = HTTPRequest(method: .post, scheme: "https", authority: "x", path: "/echo")
        let response = try await transport.send(request, body: [1, 2, 3])
        #expect(try await response.body.collect(upTo: 3) == [1, 2, 3])
    }

    @Test func collectEnforcesLimit() async throws {
        let body = HTTPResponseBody(chunks: [[1, 2], [3, 4]])
        await #expect(throws: HTTPResponseBodyTooLargeError(maxBytes: 3)) {
            try await body.collect(upTo: 3)
        }
    }

    @Test func bodyWrapsAsyncSequenceAndFeedsSSE() async throws {
        let (stream, continuation) = AsyncThrowingStream<ArraySlice<UInt8>, any Error>.makeStream()
        continuation.yield(Array("data: a\n".utf8)[...])
        continuation.yield(Array("\n: keepalive\n".utf8)[...])
        continuation.finish()
        var elements: [SSEElement] = []
        for try await element in HTTPResponseBody(stream).sseElements() {
            elements.append(element)
        }
        #expect(elements == [.event(SSEEvent(data: "a")), .comment("keepalive")])
    }
}
