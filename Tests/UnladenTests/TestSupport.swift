import Foundation
import HTTPTypes
import Unladen

/// A fake provider: answers each request with the next canned reply and
/// records what was sent.
final class FakeProvider: @unchecked Sendable {
    struct Reply: Sendable {
        var status: HTTPResponse.Status = .ok
        var headers: HTTPFields = [:]
        var body: String

        static func json(_ body: String) -> Reply { Reply(body: body) }
        static func sse(_ body: String) -> Reply { Reply(headers: [.contentType: "text/event-stream"], body: body) }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var sent: [(HTTPRequest, [UInt8])] = []

    init(_ replies: Reply...) {
        self.replies = replies
    }

    var transport: MockTransport {
        MockTransport { [self] request, body in
            let reply = lock.withLock {
                sent.append((request, body ?? []))
                return replies.isEmpty ? Reply(status: .internalServerError, body: "no reply left") : replies.removeFirst()
            }
            let bytes = Array(reply.body.utf8)
            // Two chunks, to exercise incremental parsing.
            let middle = bytes.count / 2
            return HTTPTransportResponse(
                response: HTTPResponse(status: reply.status, headerFields: reply.headers),
                body: HTTPResponseBody(chunks: [Array(bytes[..<middle]), Array(bytes[middle...])]),
            )
        }
    }

    /// The HTTP requests sent so far.
    var requests: [HTTPRequest] { lock.withLock { sent.map(\.0) } }

    /// The JSON bodies sent so far.
    var bodies: [JSONValue] {
        lock.withLock { sent.map { (try? JSONValue(parsing: $0.1)) ?? .null } }
    }

    var lastBody: JSONValue { bodies.last ?? .null }
}

/// A client wired to `provider`, with dummy keys for every preset.
func client(_ provider: FakeProvider, policy: WarningPolicy = .strict) -> ModelClient {
    ModelClient(
        transport: provider.transport,
        apiKeys: ["anthropic": "sk-ant", "openai": "sk-openai", "deepseek": "sk-ds", "gemini": "g-key", "moonshot": "sk-moon"],
        environment: [:],
        warningPolicy: policy,
    )
}

/// SSE `data:` lines (and optional `event:` names) for a stream fixture.
func sse(_ events: [(event: String?, data: String)]) -> String {
    events.map { ($0.event.map { "event: \($0)\n" } ?? "") + "data: \($0.data)\n\n" }.joined()
}

func sse(_ data: [String]) -> String {
    sse(data.map { (event: nil, data: $0) })
}

/// Collects a stream's parts.
func parts(_ stream: ResponseStream) async throws -> [StreamPart] {
    var parts: [StreamPart] = []
    for try await part in stream { parts.append(part) }
    return parts
}

extension [StreamPart] {
    var text: String {
        compactMap { if case .textDelta(_, let delta) = $0 { delta } else { nil } }.joined()
    }

    var toolCalls: [ToolCall] {
        compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
    }

    var finish: FinishReason? {
        for case .finish(let reason, _) in self { return reason }
        return nil
    }
}

extension JSONValue {
    /// The body's member at a dotted path with `[i]` indices, e.g.
    /// `messages[1].content[0].signature`.
    func at(_ path: String) -> JSONValue? {
        var value: JSONValue? = self
        for component in path.split(separator: ".") {
            var name = Substring(component)
            var indices: [Int] = []
            while let open = name.lastIndex(of: "["), name.hasSuffix("]") {
                indices.insert(Int(name[name.index(after: open)..<name.index(before: name.endIndex)])!, at: 0)
                name = name[..<open]
            }
            if !name.isEmpty { value = value?[String(name)] }
            for index in indices { value = value?[index] }
        }
        return value
    }
}
