public import AsyncHTTPClient
public import HTTPTypes
import NIOCore
import NIOHTTP1
public import UnladenCore

/// An ``HTTPTransport`` backed by AsyncHTTPClient, for Linux and the gateway.
///
/// The response body is streamed straight from AsyncHTTPClient, with its
/// backpressure: if the consumer stops reading, the connection stops reading.
/// Cancelling the task awaiting ``send(_:body:)`` or iterating the body, or
/// dropping the body iterator, cancels the request.
public struct AsyncHTTPClientTransport: HTTPTransport {
    public let client: HTTPClient
    /// Deadline for the whole exchange, **including reading the body**.
    /// `nil` (the default) means no overall deadline, which suits long model
    /// streams; connect and read-idle timeouts come from the client's
    /// configuration.
    public var timeout: Duration?

    /// - Parameters:
    ///   - client: The client to use; defaults to the process-wide
    ///     `HTTPClient.shared`. The caller owns the client's lifecycle.
    ///   - timeout: See ``timeout``.
    public init(client: HTTPClient = .shared, timeout: Duration? = nil) {
        self.client = client
        self.timeout = timeout
    }

    public func send(_ request: HTTPRequest, body: [UInt8]?) async throws -> HTTPTransportResponse {
        let clientRequest = try Self.makeClientRequest(request, body: body)
        let deadline: NIODeadline = timeout.map { .now() + Self.timeAmount($0) } ?? .distantFuture
        let response = try await client.execute(clientRequest, deadline: deadline)
        return HTTPTransportResponse(
            response: Self.makeResponse(response),
            body: HTTPResponseBody(ByteBufferChunks(base: response.body)),
        )
    }

    static func makeClientRequest(_ request: HTTPRequest, body: [UInt8]?) throws -> HTTPClientRequest {
        guard let authority = request.authority, !authority.isEmpty else {
            throw HTTPTransportError.invalidRequest("request has no authority")
        }
        let scheme = request.scheme ?? "https"
        var clientRequest = HTTPClientRequest(url: "\(scheme)://\(authority)\(request.path ?? "/")")
        clientRequest.method = HTTPMethod(rawValue: request.method.rawValue)
        for field in request.headerFields {
            clientRequest.headers.add(name: field.name.rawName, value: field.value)
        }
        if let body {
            clientRequest.body = .bytes(body)
        }
        return clientRequest
    }

    static func makeResponse(_ response: HTTPClientResponse) -> HTTPResponse {
        var fields = HTTPFields()
        fields.reserveCapacity(response.headers.count)
        for (name, value) in response.headers {
            // Header names AsyncHTTPClient accepted are valid tokens; skip any that are not.
            if let fieldName = HTTPField.Name(name) {
                fields.append(HTTPField(name: fieldName, value: value))
            }
        }
        let status = HTTPResponse.Status(code: Int(response.status.code), reasonPhrase: response.status.reasonPhrase)
        return HTTPResponse(status: status, headerFields: fields)
    }

    static func timeAmount(_ duration: Duration) -> TimeAmount {
        let (seconds, attoseconds) = duration.components
        let (nanosFromSeconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return .nanoseconds(seconds < 0 ? .min : .max) }
        let (total, overflow2) = nanosFromSeconds.addingReportingOverflow(attoseconds / 1_000_000_000)
        guard !overflow2 else { return .nanoseconds(seconds < 0 ? .min : .max) }
        return .nanoseconds(total)
    }
}

/// Adapts AsyncHTTPClient's `ByteBuffer` body to byte-array chunks.
struct ByteBufferChunks: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>

    let base: HTTPClientResponse.Body

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: HTTPClientResponse.Body.AsyncIterator

        mutating func next() async throws -> ArraySlice<UInt8>? {
            while let buffer = try await base.next(isolation: #isolation) {
                if buffer.readableBytes > 0 {
                    return Array(buffer.readableBytesView)[...]
                }
            }
            return nil
        }
    }
}
