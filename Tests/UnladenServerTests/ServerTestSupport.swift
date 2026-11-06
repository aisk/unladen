import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// A value behind a lock, for test closures.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// A one-shot signal tests can wait for.
final class Flag: Sendable {
    private let state = Locked(false)

    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.current }

    /// Polls until set or `timeout` passes; returns whether it was set.
    func wait(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isSet { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isSet
    }
}

/// One request the mock upstream received.
struct UpstreamHit: Sendable {
    var request: HTTPRequest
    var body: [UInt8]

    var json: JSONValue { (try? JSONValue(parsing: body)) ?? .null }
    var path: String { request.path ?? "" }
    func header(_ name: String) -> String? { HTTPField.Name(name).flatMap { request.headerFields[$0] } }
}

/// A scripted upstream: records each request and answers with the
/// handler for its position (the last handler repeats).
final class MockUpstream: Sendable {
    typealias Handler = @Sendable (UpstreamHit) async throws -> HTTPTransportResponse

    private let hits = Locked<[UpstreamHit]>([])
    private let handlers: [Handler]

    init(_ handlers: [Handler]) {
        self.handlers = handlers
    }

    convenience init(_ handler: @escaping Handler) {
        self.init([handler])
    }

    var requests: [UpstreamHit] { hits.current }

    var transport: MockTransport {
        MockTransport { request, body in
            let hit = UpstreamHit(request: request, body: body ?? [])
            let index = self.hits.withLock { hits in
                hits.append(hit)
                return hits.count - 1
            }
            return try await self.handlers[min(index, self.handlers.count - 1)](hit)
        }
    }
}

/// A reply with `body` split in two chunks (exercises incremental parsing).
func reply(status: HTTPResponse.Status = .ok, headers: HTTPFields = [:], _ body: [UInt8]) -> HTTPTransportResponse {
    let middle = body.count / 2
    return HTTPTransportResponse(
        response: HTTPResponse(status: status, headerFields: headers),
        body: HTTPResponseBody(chunks: [Array(body[..<middle]), Array(body[middle...])]),
    )
}

func reply(status: HTTPResponse.Status = .ok, headers: HTTPFields = [:], _ text: String) -> HTTPTransportResponse {
    reply(status: status, headers: headers, Array(text.utf8))
}

/// A reply whose body chunks come from `stream`.
func reply(streaming stream: AsyncStream<[UInt8]>) -> HTTPTransportResponse {
    HTTPTransportResponse(
        response: HTTPResponse(status: .ok, headerFields: [.contentType: "text/event-stream"]),
        body: HTTPResponseBody(stream.map { $0[...] }),
    )
}

/// A fixture of the core tests (`Tests/UnladenCoreTests/Fixtures`).
func fixture(_ path: String) -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("UnladenCoreTests/Fixtures").appendingPathComponent(path)
    guard let data = FileManager.default.contents(atPath: url.path) else {
        Issue.record("missing fixture \(path)")
        return []
    }
    return Array(data)
}

func json(_ text: String) -> JSONValue {
    (try? JSONValue(parsing: text)) ?? .null
}

func json(_ buffer: ByteBuffer) -> JSONValue {
    (try? JSONValue(parsing: Array(buffer.readableBytesView))) ?? .null
}

/// The default model of test gateways: a provider with a Chat endpoint
/// only, so every non-Chat client is translated.
let chatOnlyModel = "together/llama-3.3-70b"

/// A gateway over `upstream` with a key for every provider.
func makeGateway(
    _ upstream: MockUpstream,
    model: String? = chatOnlyModel,
    fallbacks: [String] = [],
    keys: [String: [String]]? = nil,
    apiKey: String? = nil,
    strict: Bool = false,
    keepalive: Duration = .seconds(15),
) -> Gateway {
    var configuration = GatewayConfiguration()
    configuration.defaultModel = model
    configuration.fallbacks = fallbacks
    configuration.apiKey = apiKey
    configuration.strict = strict
    configuration.keepaliveInterval = keepalive
    configuration.upstreamKeys = keys ?? Dictionary(
        uniqueKeysWithValues: configuration.registry.providers.keys.map { ($0, ["key-\($0)"]) },
    )
    return Gateway(configuration: configuration, transport: upstream.transport)
}

func makeApp(_ gateway: Gateway) -> some ApplicationProtocol {
    Application(router: buildRouter(gateway: gateway), configuration: .init(address: .hostname("127.0.0.1", port: 0)))
}

// MARK: - Client requests

enum ClientRequest {
    static func chat(model: String, stream: Bool = false, extra: String = "") -> String {
        #"{"model":"\#(model)","messages":[{"role":"user","content":"Hi"}]\#(stream ? #","stream":true"# : "")\#(extra)}"#
    }

    static func responses(model: String, stream: Bool = false) -> String {
        #"{"model":"\#(model)","input":"Hi"\#(stream ? #","stream":true"# : "")}"#
    }

    static func anthropic(model: String, stream: Bool = false) -> String {
        #"{"model":"\#(model)","max_tokens":256,"messages":[{"role":"user","content":"Hi"}]\#(stream ? #","stream":true"# : "")}"#
    }

    static let gemini = #"{"contents":[{"role":"user","parts":[{"text":"Hi"}]}]}"#

    static func geminiPath(model: String, stream: Bool = false) -> String {
        stream ? "/v1beta/models/\(model):streamGenerateContent?alt=sse" : "/v1beta/models/\(model):generateContent"
    }
}

extension TestClientProtocol {
    func post(_ uri: String, _ body: String, headers: HTTPFields = [:]) async throws -> TestResponse {
        var fields = headers
        fields[.contentType] = "application/json"
        return try await executeRequest(uri: uri, method: .post, headers: fields, body: ByteBuffer(string: body))
    }
}

// MARK: - Checking streams

/// What a client-protocol SSE body decodes to with the core's own stream
/// decoder (a strict check that the gateway's output is a valid stream).
struct DecodedStream {
    var elements: [SSEElement] = []
    var events: [WireEvent] = []
    var text = ""
    var finish: WireFinish?
    var errors: [WireStreamError] = []

    var eventNames: [String] {
        elements.compactMap { if case .event(let event) = $0 { event.event } else { nil } }
    }

    var comments: [String] {
        elements.compactMap { if case .comment(let text) = $0 { text } else { nil } }
    }

    var dataObjects: [JSONValue] {
        elements.compactMap { if case .event(let event) = $0 { try? JSONValue(parsing: event.data) } else { nil } }
    }
}

func decodeStream(_ body: ByteBuffer, as wire: WireProtocol) -> DecodedStream {
    decodeStream(Array(body.readableBytesView), as: wire)
}

func decodeStream(_ bytes: [UInt8], as wire: WireProtocol) -> DecodedStream {
    var result = DecodedStream()
    var parser = SSEParser()
    do {
        result.elements = try parser.parse(bytes)
    } catch {
        Issue.record("SSE parse error: \(error)")
        return result
    }
    parser.finish()
    var decoder = AnyWireStreamDecoder(for: wire, origin: nil)
    do {
        for element in result.elements { result.events += try decoder.decode(element) }
    } catch {
        Issue.record("stream decode error: \(error)")
    }
    result.events += decoder.finish()
    for event in result.events {
        switch event {
        case .textDelta(_, let delta): result.text += delta
        case .finish(let finish): result.finish = finish
        case .error(let error): result.errors.append(error)
        default: break
        }
    }
    return result
}

/// The text of a complete reply in `wire`'s shape.
func replyText(_ body: ByteBuffer, as wire: WireProtocol) -> String {
    let bytes = Array(body.readableBytesView)
    let decoded: WireDecoded<WireResponse>?
    switch wire {
    case .chatCompletions: decoded = try? ChatCompletionsCodec.parseResponse(bytes, origin: nil)
    case .responses: decoded = try? ResponsesCodec.parseResponse(bytes, origin: nil)
    case .anthropicMessages: decoded = try? AnthropicMessagesCodec.parseResponse(bytes, origin: nil)
    case .gemini: decoded = try? GeminiCodec.parseResponse(bytes, origin: nil)
    }
    guard let response = decoded?.value else {
        Issue.record("not a \(wire) reply: \(String(decoding: bytes, as: UTF8.self))")
        return ""
    }
    return response.message.parts.compactMap { if case .text(let text) = $0 { text.text } else { nil } }.joined()
}
