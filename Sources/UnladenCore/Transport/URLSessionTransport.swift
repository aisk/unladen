#if canImport(Darwin)
public import Foundation
public import HTTPTypes
import HTTPTypesFoundation

/// An ``HTTPTransport`` backed by `URLSession`, the default on Apple platforms.
///
/// Uses a per-task data delegate rather than `bytes(for:)`, so body chunks
/// arrive as URLSession delivers them instead of one byte at a time.
/// URLSession offers no read-side backpressure through this API, so chunks
/// are buffered until the consumer reads them.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest, body: [UInt8]?) async throws -> HTTPTransportResponse {
        guard var urlRequest = URLRequest(httpRequest: request) else {
            throw HTTPTransportError.invalidRequest("cannot convert request to URLRequest")
        }
        if let body { urlRequest.httpBody = Data(body) }
        try Task.checkCancellation()

        let (stream, continuation) = AsyncThrowingStream<ArraySlice<UInt8>, any Error>.makeStream()
        let delegate = StreamingDataDelegate(body: continuation)
        let task = session.dataTask(with: urlRequest)
        task.delegate = delegate
        // Fires when the body finishes, or when the consumer is cancelled or
        // drops the stream; cancelling a completed task is a no-op.
        continuation.onTermination = { _ in task.cancel() }

        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (head: CheckedContinuation<HTTPResponse, any Error>) in
                delegate.setHeadContinuation(head)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return HTTPTransportResponse(response: head, body: HTTPResponseBody(stream))
    }
}

private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // All mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var head: CheckedContinuation<HTTPResponse, any Error>?
    private let body: AsyncThrowingStream<ArraySlice<UInt8>, any Error>.Continuation

    init(body: AsyncThrowingStream<ArraySlice<UInt8>, any Error>.Continuation) {
        self.body = body
    }

    func setHeadContinuation(_ continuation: CheckedContinuation<HTTPResponse, any Error>) {
        lock.withLock { head = continuation }
    }

    private func takeHead() -> CheckedContinuation<HTTPResponse, any Error>? {
        lock.withLock {
            defer { head = nil }
            return head
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
    ) {
        guard let httpResponse = (response as? HTTPURLResponse)?.httpResponse else {
            takeHead()?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        takeHead()?.resume(returning: httpResponse)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.yield(ArraySlice(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        takeHead()?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error {
            body.finish(throwing: error)
        } else {
            body.finish()
        }
    }
}
#endif
