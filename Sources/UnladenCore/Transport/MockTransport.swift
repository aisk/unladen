public import HTTPTypes

/// A transport that answers requests with a closure, without any networking.
///
/// It is public (not `package`) because library users need the same thing to
/// test their own code against Unladen, and a closure-backed transport is
/// small enough to keep stable. Record requests by capturing an actor or other
/// `Sendable` state in the handler.
///
/// ```swift
/// let transport = MockTransport { request, body in
///     HTTPTransportResponse(response: HTTPResponse(status: .ok), body: HTTPResponseBody(bytes: Array("{}".utf8)))
/// }
/// ```
public struct MockTransport: HTTPTransport {
    public typealias Handler = @Sendable (HTTPRequest, [UInt8]?) async throws -> HTTPTransportResponse

    private let handler: Handler

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Always responds with the given status, headers and body chunks.
    public init(status: HTTPResponse.Status = .ok, headerFields: HTTPFields = [:], chunks: [[UInt8]]) {
        self.handler = { _, _ in
            HTTPTransportResponse(
                response: HTTPResponse(status: status, headerFields: headerFields),
                body: HTTPResponseBody(chunks: chunks),
            )
        }
    }

    public func send(_ request: HTTPRequest, body: [UInt8]?) async throws -> HTTPTransportResponse {
        try await handler(request, body)
    }
}
