import Foundation
import HTTPTypes
import Testing
@_spi(Wire) import UnladenCore

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
}

/// Records what a ``MockTransport`` was asked to send.
final class Recorder: Sendable {
    private let state = Locked<[(HTTPRequest, [UInt8])]>([])

    func record(_ request: HTTPRequest, _ body: [UInt8]?) {
        state.withLock { $0.append((request, body ?? [])) }
    }

    var requests: [HTTPRequest] { state.withLock { $0.map(\.0) } }
    var bodies: [JSONValue] { state.withLock { $0.map { (try? JSONValue(parsing: $0.1)) ?? .null } } }
}

private func transport(
    _ recorder: Recorder,
    status: HTTPResponse.Status = .ok,
    headers: HTTPFields = [:],
    body: [UInt8],
) -> MockTransport {
    MockTransport { request, bytes in
        recorder.record(request, bytes)
        // Split the body to exercise incremental SSE parsing.
        let middle = body.count / 2
        return HTTPTransportResponse(
            response: HTTPResponse(status: status, headerFields: headers),
            body: HTTPResponseBody(chunks: [Array(body[..<middle]), Array(body[middle...])]),
        )
    }
}

private func ask(_ text: String = "Hello") -> WireRequest {
    WireRequest(model: "client-alias", messages: [WireMessage(role: .user, parts: [.text(WireText(text))])])
}

private func events(_ reply: UpstreamReply) async throws -> [WireEvent] {
    guard case .events(let stream) = reply.body else {
        Issue.record("expected a stream")
        return []
    }
    var out: [WireEvent] = []
    for try await event in stream { out.append(event) }
    return out
}

private func response(_ reply: UpstreamReply) throws -> WireResponse {
    guard case .response(let response) = reply.body else { throw UpstreamTestError.notAResponse }
    return response
}

private enum UpstreamTestError: Error { case notAResponse }

private func replyText(_ response: WireResponse) -> String {
    response.message.parts.compactMap { if case .text(let t) = $0 { t.text } else { nil } }.joined()
}

private func streamedText(_ events: [WireEvent]) -> String {
    events.compactMap { if case .textDelta(_, let d) = $0 { d } else { nil } }.joined()
}

@Suite struct UpstreamCallTests {
    let registry = ProviderRegistry.builtIn

    @Test func chatNonStreaming() async throws {
        let recorder = Recorder()
        let target = try registry.resolve("deepseek/deepseek-chat")
        var request = ask()
        request.maxOutputTokens = 100
        request.temperature = 0.2
        let call = UpstreamCall(
            target: target, apiKey: "sk-test",
            transport: transport(recorder, body: try Fixtures.bytes("Chat/responses/text.json")),
        )
        let reply = try await call.send(request, stream: false)
        let sent = try #require(recorder.requests.first)
        #expect(sent.method == .post)
        #expect(sent.scheme == "https")
        #expect(sent.authority == "api.deepseek.com")
        #expect(sent.path == "/v1/chat/completions")
        #expect(sent.headerFields[.authorization] == "Bearer sk-test")
        #expect(sent.headerFields[.contentType] == "application/json")
        #expect(sent.headerFields[.accept] == "application/json")
        let body = try #require(recorder.bodies.first)
        #expect(body["model"] == "deepseek-chat")
        #expect(body["max_tokens"] == 100)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["stream"] == nil)
        #expect(body["temperature"] == 0.2)
        #expect(replyText(try response(reply)) == "Hello! How can I assist you today?")
    }

    @Test func responsesStreaming() async throws {
        let recorder = Recorder()
        let call = UpstreamCall(
            target: try registry.resolve("openai/gpt-4.1"), apiKey: "sk-test",
            transport: transport(recorder, body: try Fixtures.bytes("Responses/streams/text.sse")),
        )
        let reply = try await call.send(ask(), stream: true)
        let sent = try #require(recorder.requests.first)
        #expect(sent.path == "/v1/responses")
        #expect(sent.headerFields[.accept] == "text/event-stream")
        #expect(recorder.bodies.first?["stream"] == true)
        let all = try await events(reply)
        #expect(streamedText(all) == "Hello world!")
        guard case .finish? = all.last else { Issue.record("no finish"); return }
        if case .responseMetadata(let metadata)? = all.first { #expect(metadata.source == .responses) }
    }

    @Test func anthropicHeadersAndStreaming() async throws {
        let recorder = Recorder()
        let call = UpstreamCall(
            target: try registry.resolve("anthropic/claude-sonnet-4-5"), apiKey: "sk-ant",
            transport: transport(recorder, body: try Fixtures.bytes("Anthropic/streams/text.sse")),
        )
        let client: HTTPFields = [
            HTTPField.Name("anthropic-beta")!: "context-1m-2025-08-07",
            HTTPField.Name("x-api-key")!: "client-key",
            .authorization: "Bearer client",
            HTTPField.Name("x-custom")!: "nope",
        ]
        let reply = try await call.send(ask(), stream: true, clientHeaders: client)
        let sent = try #require(recorder.requests.first)
        #expect(sent.authority == "api.anthropic.com")
        #expect(sent.path == "/v1/messages")
        #expect(sent.headerFields[HTTPField.Name("x-api-key")!] == "sk-ant")
        #expect(sent.headerFields[HTTPField.Name("anthropic-version")!] == "2023-06-01")
        #expect(sent.headerFields[HTTPField.Name("anthropic-beta")!] == "context-1m-2025-08-07")
        #expect(sent.headerFields[.authorization] == nil)
        #expect(sent.headerFields[HTTPField.Name("x-custom")!] == nil)
        let body = try #require(recorder.bodies.first)
        #expect(body["model"] == "claude-sonnet-4-5")
        // The Profile's default output limit fills Anthropic's required field.
        #expect(body["max_tokens"] == 16000)
        #expect(body["stream"] == true)
        #expect(streamedText(try await events(reply)) == "Hello world")
    }

    @Test func geminiPathsAndKey() async throws {
        let recorder = Recorder()
        let target = try registry.resolve("gemini/gemini-2.5-flash")
        let streaming = UpstreamCall(
            target: target, apiKey: "AIza",
            transport: transport(recorder, body: try Fixtures.bytes("Gemini/streams/text.sse")),
        )
        let streamed = try await events(try await streaming.send(ask(), stream: true))
        #expect(streamedText(streamed) == "Hello! How can I help you today?")

        let whole = UpstreamCall(
            target: target, apiKey: "AIza",
            transport: transport(recorder, body: try Fixtures.bytes("Gemini/responses/text.json")),
        )
        let reply = try await whole.send(ask(), stream: false)
        #expect(replyText(try response(reply)) == "Hello! How can I help you today?")

        let sent = recorder.requests
        #expect(sent.map(\.authority) == ["generativelanguage.googleapis.com", "generativelanguage.googleapis.com"])
        #expect(sent.map(\.path) == [
            "/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
            "/v1beta/models/gemini-2.5-flash:generateContent",
        ])
        #expect(sent.allSatisfy { $0.headerFields[HTTPField.Name("x-goog-api-key")!] == "AIza" })
        #expect(recorder.bodies.allSatisfy { $0["model"] == nil && $0["stream"] == nil })
    }

    @Test func non2xxIsSurfacedVerbatim() async throws {
        let recorder = Recorder()
        let errorBody = Array(#"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}"#.utf8)
        let headers: HTTPFields = [.retryAfter: "17", HTTPField.Name("request-id")!: "req_011", .contentType: "application/json"]
        let call = UpstreamCall(
            target: try registry.resolve("anthropic/claude-opus-4-6"), apiKey: "k",
            transport: transport(recorder, status: .tooManyRequests, headers: headers, body: errorBody),
        )
        do {
            _ = try await call.send(ask(), stream: true)
            Issue.record("expected an error")
        } catch UpstreamError.http(let error) {
            #expect(error.status == .tooManyRequests)
            #expect(error.body == errorBody)
            #expect(error.retryAfter == "17")
            #expect(error.requestID == "req_011")
            #expect(error.headerFields == headers)
        }
    }

    @Test func undecodableBodyKeepsTheBytes() async throws {
        let call = UpstreamCall(
            target: try registry.resolve("openai/gpt-4.1", preferring: .chatCompletions), apiKey: "k",
            transport: transport(Recorder(), body: Array("<html>bad gateway</html>".utf8)),
        )
        await #expect(throws: UpstreamError.self) { try await call.send(ask(), stream: false) }
    }

    @Test func forcedStreamIsAccumulated() async throws {
        let recorder = Recorder()
        var target = try registry.resolve("openai/gpt-4.1", preferring: .chatCompletions)
        target.profile.streaming = .always
        let call = UpstreamCall(
            target: target, apiKey: "k",
            transport: transport(recorder, body: try Fixtures.bytes("Chat/streams/text_usage.sse")),
        )
        let reply = try await call.send(ask(), stream: false)
        #expect(recorder.bodies.first?["stream"] == true)
        #expect(recorder.requests.first?.headerFields[.accept] == "text/event-stream")
        let accumulated = try response(reply)
        #expect(replyText(accumulated) == "Hello world")
        #expect(accumulated.finishReason?.unified == .stop)
        #expect(accumulated.usage?.inputTokens == 9)
    }

    @Test func forcedCompleteReplyIsReplayedAsEvents() async throws {
        let recorder = Recorder()
        var target = try registry.resolve("openai/gpt-4.1", preferring: .chatCompletions)
        target.profile.streaming = .never
        var request = ask()
        request.streamOptions = WireStreamOptions(includeUsage: true)
        request.stream = true
        let call = UpstreamCall(
            target: target, apiKey: "k",
            transport: transport(recorder, body: try Fixtures.bytes("Chat/responses/text.json")),
        )
        let all = try await events(try await call.send(request, stream: true))
        #expect(recorder.bodies.first?["stream"] == false)
        #expect(recorder.bodies.first?["stream_options"] == nil)
        #expect(streamedText(all) == "Hello! How can I assist you today?")
        guard case .finish? = all.last else { Issue.record("no finish"); return }
    }

    @Test func trustSetDropsSignaturesTheEndpointCannotVerify() throws {
        let signed = WireReasoning(text: "Let me think.", signature: "EqQBCkgIBRABGAIiQLsig", origin: "anthropic")
        let request = WireRequest(model: "m", messages: [
            WireMessage(role: .user, parts: [.text(WireText("hi"))]),
            WireMessage(role: .assistant, parts: [.reasoning(signed), .text(WireText("Hello."))], contentForm: .parts),
            WireMessage(role: .user, parts: [.text(WireText("more"))]),
        ], source: .anthropicMessages)
        let bedrock = Endpoint(
            system: "bedrock", apiProtocol: .anthropicMessages, baseURL: "https://bedrock-mantle.us-east-1.api.aws/anthropic",
            auth: .bearer,
        )
        #expect(bedrock.trustedOrigins == ["bedrock"])
        let noop = MockTransport { _, _ in fatalError() }

        let toBedrock = try UpstreamCall(
            target: ResolvedModel(provider: "bedrock", model: "anthropic.claude-opus-4-6", endpoint: bedrock, profile: Profile()),
            apiKey: "k", transport: noop,
        ).prepare(request, stream: false)
        let bedrockBody = try JSONValue(parsing: toBedrock.body)
        #expect(bedrockBody["messages"]?[1]?["content"]?.arrayValue?.map { $0["type"] } == ["text"])
        #expect(toBedrock.warnings.contains { $0.code == .droppedContent })

        let toAnthropic = try UpstreamCall(target: try registry.resolve("anthropic/claude-opus-4-6"), apiKey: "k", transport: noop)
            .prepare(request, stream: false)
        let anthropicBody = try JSONValue(parsing: toAnthropic.body)
        #expect(anthropicBody["messages"]?[1]?["content"]?[0]?["signature"] == "EqQBCkgIBRABGAIiQLsig")

        // A Bedrock endpoint that trusts Anthropic's signatures keeps them.
        var trusting = bedrock
        trusting.trustedOrigins = ["bedrock", "anthropic"]
        let kept = try UpstreamCall(
            target: ResolvedModel(provider: "bedrock", model: "x", endpoint: trusting, profile: Profile()), apiKey: "k", transport: noop,
        ).prepare(request, stream: false)
        #expect(try JSONValue(parsing: kept.body)["messages"]?[1]?["content"]?[0]?["type"] == "thinking")
    }

    @Test func strictUpstreamDropsUnknownFields() throws {
        var request = ask()
        request.source = .chatCompletions
        request.extra["safe_prompt"] = true
        request.messages[0].extra["name"] = "alice"
        request.maxOutputTokens = 9_999_999
        let prepared = try UpstreamCall(
            target: try registry.resolve("mistral/mistral-large-latest"), apiKey: "k", transport: MockTransport { _, _ in fatalError() },
        ).prepare(request, stream: false)
        let body = try JSONValue(parsing: prepared.body)
        #expect(body["safe_prompt"] == nil)
        #expect(body["messages"]?[0]?["name"] == nil)
        #expect(body["max_tokens"] == 9_999_999)
        #expect(prepared.warnings.filter { $0.code == .droppedField }.count == 2)

        // Without the flag the same protocol writes bags back.
        let lenient = try UpstreamCall(
            target: try registry.resolve("together/meta-llama/Llama-3.3-70B"), apiKey: "k", transport: MockTransport { _, _ in fatalError() },
        ).prepare(request, stream: false)
        #expect(try JSONValue(parsing: lenient.body)["safe_prompt"] == true)
    }

    @Test func outputTokensAreCappedAndOllamaHasNoAuth() throws {
        var request = ask()
        request.maxOutputTokens = 500_000
        let capped = try UpstreamCall(
            target: try registry.resolve("anthropic/claude-opus-4-8"), apiKey: "k", transport: MockTransport { _, _ in fatalError() },
        ).prepare(request, stream: false)
        #expect(try JSONValue(parsing: capped.body)["max_tokens"] == 128_000)

        let local = try UpstreamCall(
            target: try registry.resolve("ollama/qwen3:8b"), apiKey: nil, transport: MockTransport { _, _ in fatalError() },
        ).prepare(request, stream: false)
        #expect(local.http.scheme == "http")
        #expect(local.http.authority == "localhost:11434")
        #expect(local.http.path == "/v1/chat/completions")
        #expect(local.http.headerFields[.authorization] == nil)
    }

    @Test func customToolCallsComeBackFromAChatUpstream() async throws {
        let reply = Array(#"""
        {"id":"chatcmpl-9","object":"chat.completion","created":1,"model":"deepseek-chat",
         "choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_7","type":"function",
         "function":{"name":"apply_patch","arguments":"{\"input\":\"*** Begin Patch\"}"}}]},"finish_reason":"tool_calls"}]}
        """#.utf8)
        var request = ask()
        request.source = .responses
        request.tools = [.opaque(WireOpaque(protocol: .responses, value: ["type": "custom", "name": "apply_patch"]))]
        let recorder = Recorder()
        let call = UpstreamCall(target: try registry.resolve("deepseek/deepseek-chat"), apiKey: "k", transport: transport(recorder, body: reply))
        let result = try response(try await call.send(request, stream: false))
        #expect(recorder.bodies.first?["tools"]?[0]?["function"]?["name"] == "apply_patch")
        guard case .toolCall(let custom)? = result.message.parts.first else { Issue.record("no call"); return }
        #expect(custom.itemType == "custom_tool_call")
        #expect(custom.arguments == "*** Begin Patch")
    }

    @Test func cancellationStopsTheStream() async throws {
        let terminated = Locked(false)
        let (chunks, continuation) = AsyncThrowingStream<ArraySlice<UInt8>, any Error>.makeStream()
        continuation.onTermination = { _ in terminated.withLock { $0 = true } }
        let first = #"data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#
        continuation.yield(Array((first + "\n\n").utf8)[...])
        let mock = MockTransport { _, _ in
            HTTPTransportResponse(response: HTTPResponse(status: .ok), body: HTTPResponseBody(chunks))
        }
        let call = UpstreamCall(target: try registry.resolve("together/m"), apiKey: "k", transport: mock)
        let reply = try await call.send(ask(), stream: true)
        guard case .events(let stream) = reply.body else { Issue.record("expected a stream"); return }

        let (seen, seenContinuation) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var received: [WireEvent] = []
            do {
                for try await event in stream {
                    received.append(event)
                    if case .textDelta = event { seenContinuation.yield() }
                }
                return (received, false)
            } catch is CancellationError {
                return (received, true)
            }
        }
        for await _ in seen { break }
        consumer.cancel()
        let (received, cancelled) = try await consumer.value
        #expect(cancelled)
        #expect(terminated.withLock { $0 })
        #expect(!received.contains { if case .finish = $0 { true } else { false } })
    }
}
