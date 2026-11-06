import Foundation
import HTTPTypes
@_spi(Wire) import UnladenCore

/// A value behind a lock, for transport closures.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// One request the replay transport received.
struct SentRequest: Sendable {
    var head: HTTPRequest
    var body: [UInt8]

    var json: JSONValue { (try? JSONValue(parsing: body)) ?? .null }
    var path: String { head.path ?? "" }
    /// The path without its query.
    var route: String { String(path.split(separator: "?", maxSplits: 1).first ?? "") }
    func header(_ name: String) -> String? { HTTPField.Name(name).flatMap { head.headerFields[$0] } }
}

/// A transport that answers each request with the next recording's
/// response (status, kept headers, body), the body cut into small chunks so
/// decoders see it arrive piecemeal, and records what it was sent. The last
/// recording repeats.
final class ReplayTransport: Sendable {
    private let replies: [Recording]
    private let sent = Guarded<[SentRequest]>([])
    /// Bytes per body chunk.
    let chunkSize: Int

    init(_ replies: [Recording], chunkSize: Int = 61) {
        precondition(!replies.isEmpty)
        self.replies = replies
        self.chunkSize = chunkSize
    }

    convenience init(_ ids: String..., chunkSize: Int = 61) {
        self.init(ids.map(Recording.named), chunkSize: chunkSize)
    }

    var requests: [SentRequest] { sent.withLock { $0 } }

    var transport: MockTransport {
        MockTransport { [self] head, body in
            let index = sent.withLock { list in
                list.append(SentRequest(head: head, body: body ?? []))
                return list.count - 1
            }
            let recording = replies[min(index, replies.count - 1)]
            return Self.response(recording, chunkSize: chunkSize)
        }
    }

    static func response(_ recording: Recording, chunkSize: Int = 61) -> HTTPTransportResponse {
        let bytes = recording.responseBytes ?? []
        var headers = recording.responseHeaders
        if headers[.contentType] == nil {
            headers[.contentType] = recording.isStream ? "text/event-stream" : "application/json"
        }
        let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map { Array(bytes[$0..<min($0 + chunkSize, bytes.count)]) }
        return HTTPTransportResponse(
            response: HTTPResponse(status: HTTPResponse.Status(code: recording.status), headerFields: headers),
            body: HTTPResponseBody(chunks: chunks),
        )
    }
}

extension WireProtocol {
    var apiProtocol: APIProtocol {
        APIProtocol.allCases.first { $0.wire == self }!
    }
}
