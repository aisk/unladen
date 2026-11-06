public import HTTPTypes

/// Sends HTTP requests on behalf of Unladen.
///
/// Implementations must follow these rules:
/// - **Status codes are data.** Any response whose head was received is
///   returned, whatever its status, so callers can forward provider error
///   bodies verbatim. Throw only when no response head was obtained
///   (connection failure, TLS error, cancellation, timeout).
/// - **Streaming.** `send` returns as soon as the response head arrives; the
///   body is delivered incrementally through ``HTTPResponseBody``.
/// - **Cancellation.** Cancelling the task awaiting `send`, or the task
///   iterating the body, cancels the upstream request. Dropping the body
///   without reading it to the end must also release the request.
/// - The request carries scheme, authority and path in `HTTPRequest`.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest, body: [UInt8]?) async throws -> HTTPTransportResponse
}

/// A response head plus its (possibly still arriving) body.
public struct HTTPTransportResponse: Sendable {
    public var response: HTTPResponse
    public var body: HTTPResponseBody

    public init(response: HTTPResponse, body: HTTPResponseBody) {
        self.response = response
        self.body = body
    }

    public var status: HTTPResponse.Status { response.status }
}

/// A single-pass async sequence of response body chunks.
///
/// This is a type-erased wrapper so that transports can expose their native
/// body streams without buffering. Iterate it at most once: transports
/// generally stream from the network and cannot replay.
public struct HTTPResponseBody: AsyncSequence, Sendable {
    public typealias Element = ArraySlice<UInt8>
    public typealias Failure = any Error

    private let makeIterator: @Sendable () -> AsyncIterator

    /// Wraps an async sequence of byte chunks.
    public init<Chunks: AsyncSequence & Sendable>(_ chunks: Chunks) where Chunks.Element == ArraySlice<UInt8> {
        makeIterator = {
            var iterator = chunks.makeAsyncIterator()
            return AsyncIterator { try await iterator.next(isolation: #isolation) }
        }
    }

    /// A body that yields the given chunks (empty chunks are skipped).
    public init(chunks: [[UInt8]]) {
        makeIterator = {
            var remaining = chunks.filter { !$0.isEmpty }.makeIterator()
            return AsyncIterator { remaining.next()?[...] }
        }
    }

    /// A body consisting of a single chunk (or none if `bytes` is empty).
    public init(bytes: [UInt8]) {
        self.init(chunks: [bytes])
    }

    /// An empty body.
    public static var empty: HTTPResponseBody { HTTPResponseBody(chunks: []) }

    public func makeAsyncIterator() -> AsyncIterator {
        makeIterator()
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let nextChunk: nonisolated(nonsending) () async throws -> ArraySlice<UInt8>?

        init(_ nextChunk: nonisolated(nonsending) @escaping () async throws -> ArraySlice<UInt8>?) {
            self.nextChunk = nextChunk
        }

        public mutating func next() async throws -> ArraySlice<UInt8>? {
            try await nextChunk()
        }
    }

    /// Reads the whole body, throwing ``HTTPResponseBodyTooLargeError`` if it
    /// exceeds `maxBytes`.
    public func collect(upTo maxBytes: Int) async throws -> [UInt8] {
        var result: [UInt8] = []
        for try await chunk in self {
            guard result.count + chunk.count <= maxBytes else { throw HTTPResponseBodyTooLargeError(maxBytes: maxBytes) }
            result.append(contentsOf: chunk)
        }
        return result
    }
}

public struct HTTPResponseBodyTooLargeError: Error, Hashable, Sendable {
    public var maxBytes: Int

    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }
}

/// Errors raised by transports before any response was received.
public enum HTTPTransportError: Error, Hashable, Sendable {
    /// The request cannot be sent, e.g. it has no scheme or authority.
    case invalidRequest(String)
}
