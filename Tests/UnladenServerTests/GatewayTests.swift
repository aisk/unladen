import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private let warningsHeader = HTTPField.Name("x-unladen-warnings")!
private let modelHeader = HTTPField.Name("x-unladen-model")!

/// `body` with its `model` replaced, keys sorted (structural comparison).
private func withModel(_ body: JSONValue, _ model: String) -> JSONValue {
    guard case .object(var object) = body else { return body }
    object["model"] = .string(model)
    return canonical(.object(object))
}

/// `value` with object keys sorted, recursively.
private func canonical(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
        return .object(JSONObject(object.keys.sorted().map { ($0, canonical(object[$0]!)) }))
    case .array(let items):
        return .array(items.map(canonical))
    default:
        return value
    }
}

@Suite struct PassthroughTests {
    @Test func chatToChat() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        let request = ClientRequest.chat(model: "openai/gpt-4o")
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", request)
            #expect(response.status == .ok)
            #expect(response.headers[modelHeader] == "openai/gpt-4o")
            #expect(replyText(response.body, as: .chatCompletions) == "Hello! How can I assist you today?")
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.path == "/v1/chat/completions")
        #expect(hit.header("authorization") == "Bearer key-openai")
        #expect(canonical(hit.json) == withModel(json(request), "gpt-4o"))
    }

    @Test func responsesToResponses() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Responses/responses/text.json")) }
        let request = ClientRequest.responses(model: "openai/gpt-5")
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/responses", request)
            #expect(response.status == .ok)
            #expect(!replyText(response.body, as: .responses).isEmpty)
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.path == "/v1/responses")
        #expect(canonical(hit.json) == withModel(json(request), "gpt-5"))
    }

    @Test func anthropicToAnthropic() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        let request = ClientRequest.anthropic(model: "anthropic/claude-sonnet-4-5")
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/messages", request, headers: [HTTPField.Name("anthropic-beta")!: "x-1"])
            #expect(response.status == .ok)
            #expect(!replyText(response.body, as: .anthropicMessages).isEmpty)
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.path == "/v1/messages")
        #expect(hit.header("x-api-key") == "key-anthropic")
        #expect(hit.header("anthropic-beta") == "x-1")
        #expect(canonical(hit.json) == withModel(json(request), "claude-sonnet-4-5"))
    }

    @Test func geminiToGemini() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Gemini/responses/text.json")) }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post(ClientRequest.geminiPath(model: "gemini/gemini-2.5-flash"), ClientRequest.gemini)
            #expect(response.status == .ok)
            #expect(replyText(response.body, as: .gemini) == "Hello! How can I help you today?")
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.path == "/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(hit.header("x-goog-api-key") == "key-gemini")
        #expect(canonical(hit.json) == canonical(json(ClientRequest.gemini)))
    }

    @Test func streamingSameProtocolIsReencoded() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/streams/text.sse")) }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "anthropic/claude-sonnet-4-5", stream: true))
            #expect(response.status == .ok)
            #expect(response.headers[.contentType] == "text/event-stream")
            let stream = decodeStream(response.body, as: .anthropicMessages)
            #expect(stream.text == "Hello world")
            #expect(stream.finish?.reason?.unified == .stop)
            #expect(stream.eventNames.first == "message_start")
            #expect(stream.eventNames.last == "message_stop")
        }
        #expect(upstream.requests.first?.json["stream"] == .bool(true))
    }
}

@Suite struct CrossProtocolTests {
    /// Claude Code style: an unresolvable model goes to the default model.
    @Test func anthropicClientOverChatStream() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/streams/text_usage.sse")) }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "claude-sonnet-4-5", stream: true))
            #expect(response.status == .ok)
            #expect(response.headers[modelHeader] == chatOnlyModel)
            let stream = decodeStream(response.body, as: .anthropicMessages)
            let expected = decodeStream(fixture("Chat/streams/text_usage.sse"), as: .chatCompletions)
            #expect(!stream.text.isEmpty)
            #expect(stream.text == expected.text)
            #expect(stream.finish?.reason?.unified == .stop)
            #expect(stream.eventNames.first == "message_start")
            #expect(stream.eventNames.last == "message_stop")
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.path == "/v1/chat/completions")
        #expect(hit.json["model"] == "llama-3.3-70b")
        #expect(hit.json["messages"]?[0]?["content"] == "Hi")
    }

    @Test func responsesClientOverAnthropicStream() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/streams/text.sse")) }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-4-5")).test(.router) { client in
            let response = try await client.post("/v1/responses", ClientRequest.responses(model: "gpt-5", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .responses)
            #expect(stream.text == "Hello world")
            #expect(stream.eventNames.first == "response.created")
            #expect(stream.eventNames.last == "response.completed")
            let numbers = stream.dataObjects.compactMap { $0["sequence_number"]?.numberValue?.int }
            #expect(numbers == Array(0..<numbers.count))
        }
        #expect(upstream.requests.first?.path == "/v1/messages")
    }

    @Test func geminiClientOverChatStream() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/streams/text_usage.sse")) }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post(ClientRequest.geminiPath(model: "gemini-2.5-flash", stream: true), ClientRequest.gemini)
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .gemini)
            #expect(!stream.text.isEmpty)
            #expect(stream.finish?.reason?.unified == .stop)
            #expect(stream.comments.isEmpty)
        }
        #expect(upstream.requests.first?.json["stream"] == .bool(true))
    }

    @Test func chatClientOverGeminiStream() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Gemini/streams/text.sse")) }
        try await makeApp(makeGateway(upstream, model: "gemini/gemini-3-pro-preview")).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .chatCompletions)
            #expect(stream.text == "Hello! How can I help you today?")
            #expect(String(buffer: response.body).hasSuffix("data: [DONE]\n\n"))
        }
        #expect(upstream.requests.first?.path == "/v1beta/models/gemini-3-pro-preview:streamGenerateContent?alt=sse")
    }

    @Test func chatClientOverAnthropicComplete() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-4-5")).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o"))
            #expect(response.status == .ok)
            let body = json(response.body)
            #expect(body["object"] == "chat.completion")
            #expect(!replyText(response.body, as: .chatCompletions).isEmpty)
        }
        #expect(upstream.requests.first?.json["max_tokens"] != nil)
    }

    /// A client that does not stream, over an upstream that only streams,
    /// and the reverse (UpstreamCall bridges both).
    @Test func streamingBridges() async throws {
        let streamOnly = MockUpstream { _ in reply(fixture("Anthropic/streams/text.sse")) }
        var gateway = makeGateway(streamOnly, model: "anthropic/claude-sonnet-4-5")
        var anthropic = gateway.configuration.registry["anthropic"]!
        anthropic.endpoints[0].defaults.streaming = .always
        gateway.configuration.registry.register(anthropic)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o"))
            #expect(response.status == .ok)
            #expect(replyText(response.body, as: .chatCompletions) == "Hello world")
        }
        #expect(streamOnly.requests.first?.json["stream"] == .bool(true))

        let completeOnly = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        gateway = makeGateway(completeOnly)
        var together = gateway.configuration.registry["together"]!
        together.endpoints[0].defaults.streaming = .never
        gateway.configuration.registry.register(together)
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "claude-x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .anthropicMessages)
            #expect(stream.text == "Hello! How can I assist you today?")
        }
        #expect(completeOnly.requests.first?.json["stream"] != .bool(true))
    }
}

@Suite struct ErrorTests {
    @Test func invalidRequestIsA400InTheClientShape() async throws {
        let upstream = MockUpstream { _ in reply("{}") }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            var response = try await client.post("/v1/messages", #"{"model":"x","messages":[]}"#)
            #expect(response.status == .badRequest)
            #expect(json(response.body)["type"] == "error")
            #expect(json(response.body)["error"]?["type"] == "invalid_request_error")

            response = try await client.post("/v1/chat/completions", "not json")
            #expect(response.status == .badRequest)
            #expect(json(response.body)["error"]?["type"] == "invalid_request_error")

            response = try await client.post(ClientRequest.geminiPath(model: "m"), "[]")
            #expect(response.status == .badRequest)
            #expect(json(response.body)["error"]?["status"] == "INVALID_ARGUMENT")
            #expect(json(response.body)["error"]?["code"] == 400)
        }
        #expect(upstream.requests.isEmpty)
    }

    @Test func sameProtocolErrorIsForwardedVerbatim() async throws {
        let body = #"{"error":{"message":"bad things","type":"invalid_request_error","param":"messages","code":"weird"},"extra":1}"#
        let upstream = MockUpstream { _ in
            reply(status: .badRequest, headers: [.contentType: "application/json", HTTPField.Name("x-request-id")!: "req-9"], body)
        }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "openai/gpt-4o"))
            #expect(response.status == .badRequest)
            #expect(String(buffer: response.body) == body)
            #expect(response.headers[HTTPField.Name("x-request-id")!] == "req-9")
        }
        #expect(upstream.requests.count == 1)
    }

    @Test func crossProtocolErrorIsTranslated() async throws {
        // OpenAI-shaped upstream error → Anthropic client.
        let openAIError = #"{"error":{"message":"slow down","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#
        let chatUpstream = MockUpstream { _ in reply(status: .tooManyRequests, headers: [.retryAfter: "7"], openAIError) }
        try await makeApp(makeGateway(chatUpstream)).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "claude-x"))
            #expect(response.status == .tooManyRequests)
            #expect(json(response.body) == json(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#))
            #expect(response.headers[.retryAfter] == "7")
        }

        // Anthropic-shaped upstream error → Chat and Gemini clients.
        let anthropicError = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let anthropicUpstream = MockUpstream { _ in reply(status: HTTPResponse.Status(code: 529), anthropicError) }
        try await makeApp(makeGateway(anthropicUpstream, model: "anthropic/claude-sonnet-4-5")).test(.router) { client in
            var response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o"))
            #expect(response.status.code == 529)
            #expect(json(response.body)["error"]?["message"] == "Overloaded")
            #expect(json(response.body)["error"]?["type"] == "server_error")

            response = try await client.post(ClientRequest.geminiPath(model: "gemini-x"), ClientRequest.gemini)
            #expect(response.status.code == 529)
            #expect(json(response.body) == json(#"{"error":{"code":529,"message":"Overloaded","status":"UNAVAILABLE"}}"#))
        }
    }

    @Test func midStreamUpstreamErrorUsesTheClientEncoder() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/streams/error.sse")) }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-opus-4-5")).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .chatCompletions)
            #expect(stream.text == "Partial")
            #expect(stream.errors.first?.message == "Overloaded")
        }
    }

    @Test func unknownModelWithoutDefault() async throws {
        let upstream = MockUpstream { _ in reply("{}") }
        try await makeApp(makeGateway(upstream, model: nil)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o"))
            #expect(response.status == .notFound)
            #expect(json(response.body)["error"]?["code"] == "model_not_found")
        }
        #expect(upstream.requests.isEmpty)
    }

    @Test func missingUpstreamKey() async throws {
        let upstream = MockUpstream { _ in reply("{}") }
        try await makeApp(makeGateway(upstream, keys: [:])).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o"))
            #expect(response.status == .serviceUnavailable)
            // The client is not told which variables the gateway reads; the log is.
            let message = json(response.body)["error"]?["message"]?.stringValue ?? ""
            #expect(message.contains("gpt-4o"))
            #expect(!message.contains("API_KEY"))
        }
    }

    @Test func countTokensIsNotImplemented() async throws {
        let upstream = MockUpstream { _ in reply("{}") }
        try await makeApp(makeGateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/messages/count_tokens", ClientRequest.anthropic(model: "x"))
            #expect(response.status == .notImplemented)
            #expect(json(response.body)["type"] == "error")
        }
    }
}

@Suite struct FallbackTests {
    static func keyName(_ secret: String) -> String { UpstreamKey(secret: secret).name }

    @Test func rateLimitedKeyFallsBackToTheNextKey() async throws {
        let upstream = MockUpstream([
            { _ in reply(status: .tooManyRequests, headers: [.retryAfter: "60"], #"{"error":{"message":"busy"}}"#) },
            { _ in reply(fixture("Chat/responses/text.json")) },
        ])
        let gateway = makeGateway(upstream, keys: ["together": ["k1", "k2"]])
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o"))
            #expect(response.status == .ok)
            #expect(response.headers[modelHeader] == chatOnlyModel)
        }
        #expect(upstream.requests.map { $0.header("authorization") } == ["Bearer k1", "Bearer k2"])
        // The rate-limited key cools down: the next request starts elsewhere.
        #expect(gateway.health.snapshot().isCooling(.key(provider: "together", keyName: Self.keyName("k1"))))
    }

    @Test func keyFailoverStaysOnTheRoutesModel() async throws {
        // Every key fails: the client gets the error, no other provider is tried.
        let upstream = MockUpstream { _ in reply(status: .serviceUnavailable, #"{"error":{"message":"down"}}"#) }
        let gateway = makeGateway(upstream, keys: ["together": ["k1", "k2"], "anthropic": ["a"], "openai": ["o"]])
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .serviceUnavailable)
        }
        #expect(upstream.requests.map(\.path) == ["/v1/chat/completions", "/v1/chat/completions"])
        #expect(upstream.requests.map { $0.header("authorization") } == ["Bearer k1", "Bearer k2"])
    }

    @Test func orderedPoolStaysOnTheFirstHealthyKey() async throws {
        let upstream = MockUpstream { hit in
            hit.header("authorization") == "Bearer k1"
                ? reply(status: .tooManyRequests, #"{"error":{"message":"busy"}}"#)
                : reply(fixture("Chat/responses/text.json"))
        }
        let gateway = makeGateway(upstream, keys: ["together": ["k1", "k2", "k3"]])
        try await makeApp(gateway).test(.router) { client in
            for _ in 0..<3 {
                let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
                #expect(response.status == .ok)
            }
        }
        // First request: k1 (429) then k2; afterwards k1 is cooling, so k2 first.
        #expect(upstream.requests.map { $0.header("authorization") } == ["Bearer k1", "Bearer k2", "Bearer k2", "Bearer k2"])
    }

    @Test func rotatingPoolTakesTurns() {
        let strategy = KeyPoolOrdering()
        let target = try! ProviderRegistry.builtIn.resolve("deepseek/deepseek-chat")
        let candidates = (0..<3).map {
            Candidate(reference: "deepseek/deepseek-chat", target: target, apiKey: "k\($0)", keyName: "k\($0)", poolStrategy: .rotate)
        }
        let health = HealthSnapshot(now: .now, cooldowns: [:])
        let context = RoutingContext(clientProtocol: .chatCompletions, stream: false)
        let firsts = (0..<4).map { _ in strategy.order(candidates, context: context, health: health).first!.apiKey }
        #expect(firsts == ["k0", "k1", "k2", "k0"])
        let ordered = candidates.map { var c = $0; c.poolStrategy = .order; return c }
        let orderFirsts = (0..<3).map { _ in strategy.order(ordered, context: context, health: health).first!.apiKey }
        #expect(orderFirsts == ["k0", "k0", "k0"])
    }

    @Test func clientErrorsDoNotFallBack() async throws {
        let upstream = MockUpstream { _ in reply(status: .badRequest, #"{"error":{"message":"bad"}}"#) }
        try await makeApp(makeGateway(upstream, keys: ["together": ["k1", "k2"]])).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .badRequest)
        }
        #expect(upstream.requests.count == 1)
    }

    @Test func noFallbackAfterTheFirstByte() async throws {
        // The first upstream streams a little, then its connection drops.
        struct Dropped: Error {}
        let first = Array(#"data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Par"},"finish_reason":null}]}"#.utf8) + [10, 10]
        let dropping: MockUpstream.Handler = { _ in
            HTTPTransportResponse(
                response: HTTPResponse(status: .ok),
                body: HTTPResponseBody(AsyncThrowingStream<ArraySlice<UInt8>, any Error> { continuation in
                    continuation.yield(first[...])
                    continuation.finish(throwing: Dropped())
                }),
            )
        }
        let healthy: MockUpstream.Handler = { _ in reply(fixture("Anthropic/streams/text.sse")) }
        let upstream = MockUpstream([dropping, healthy])
        try await makeApp(makeGateway(upstream, keys: ["together": ["k1", "k2"]])).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "x", stream: true))
            #expect(response.status == .ok)
            let stream = decodeStream(response.body, as: .anthropicMessages)
            #expect(stream.text == "Par")
            #expect(!stream.errors.isEmpty)
            #expect(stream.eventNames.last == "error")
        }
        #expect(upstream.requests.count == 1)
    }
}

@Suite struct AuthTests {
    @Test func gatewayKeyIsRequired() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        try await makeApp(makeGateway(upstream, apiKey: "secret")).test(.router) { client in
            var response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.status == .unauthorized)
            #expect(json(response.body)["error"]?["type"] == "authentication_error")

            response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "x"), headers: [HTTPField.Name("x-api-key")!: "wrong"])
            #expect(response.status == .unauthorized)
            #expect(json(response.body)["error"]?["type"] == "authentication_error")

            response = try await client.post(ClientRequest.geminiPath(model: "x"), ClientRequest.gemini)
            #expect(response.status == .unauthorized)
            #expect(json(response.body)["error"]?["status"] == "UNAUTHENTICATED")

            response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"), headers: [.authorization: "Bearer secret"])
            #expect(response.status == .ok)
            response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "x"), headers: [HTTPField.Name("x-api-key")!: "secret"])
            #expect(response.status == .ok)
            response = try await client.post(ClientRequest.geminiPath(model: "x"), ClientRequest.gemini, headers: [HTTPField.Name("x-goog-api-key")!: "secret"])
            #expect(response.status == .ok)
            response = try await client.post(ClientRequest.geminiPath(model: "x") + "?key=secret", ClientRequest.gemini)
            #expect(response.status == .ok)

            response = try await client.executeRequest(uri: "/health", method: .get, headers: [:], body: nil)
            #expect(response.status == .ok)
        }
        // The gateway's key never reaches the upstream; the upstream's key does.
        #expect(upstream.requests.count == 4)
        for hit in upstream.requests {
            #expect(hit.header("authorization") == "Bearer key-together")
            #expect(hit.header("x-api-key") == nil)
            #expect(hit.header("x-goog-api-key") == nil)
        }
    }

    @Test func modelList() async throws {
        let upstream = MockUpstream { _ in reply("{}") }
        let routes = [
            Route(name: "sonnet", targets: [RouteTarget(model: "anthropic/claude-sonnet-4-5")]),
            Route(name: "claude-*", targets: [RouteTarget(model: "anthropic/$model")]),
        ]
        try await makeApp(makeGateway(upstream, routes: routes)).test(.router) { client in
            let response = try await client.executeRequest(uri: "/v1/models", method: .get, headers: [:], body: nil)
            #expect(response.status == .ok)
            let ids = json(response.body)["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue }
            // Exact routes, then the `*` route's model; patterns cannot be listed.
            #expect(ids == ["sonnet", chatOnlyModel])
        }
    }
}

@Suite struct WarningTests {
    /// A Chat request field Anthropic cannot carry.
    static let lossy = ClientRequest.chat(model: "x", extra: #","logit_bias":{"50256":-100}"#)

    @Test func warningsHeaderOnCompleteReplies() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-4-5")).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", Self.lossy)
            #expect(response.status == .ok)
            let header = try #require(response.headers[warningsHeader])
            #expect(header.contains("logit_bias"))
        }
    }

    @Test func warningsCommentLeadsStreams() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/streams/text.sse")) }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-4-5")).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true, extra: #","logit_bias":{"50256":-100}"#))
            #expect(response.status == .ok)
            #expect(response.headers[warningsHeader] != nil)
            #expect(String(buffer: response.body).hasPrefix(": unladen-warnings: "))
            #expect(decodeStream(response.body, as: .chatCompletions).text == "Hello world")
        }
    }

    @Test func strictModeRejects() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-4-5", strict: true)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", Self.lossy)
            #expect(response.status == .badRequest)
            #expect(json(response.body)["error"]?["message"]?.stringValue?.contains("strict") == true)
        }
        #expect(upstream.requests.isEmpty)
    }
}

@Suite struct KeepaliveTests {
    /// An upstream that sends `head`, stalls, then sends `tail`.
    static func stalling(_ bytes: [UInt8], splitAt marker: String, occurrence: Int = 0, stall: Duration = .milliseconds(600)) -> MockUpstream {
        let text = String(decoding: bytes, as: UTF8.self)
        let range = text.ranges(of: marker)[occurrence]
        let head = Array(text[..<range.lowerBound].utf8)
        let tail = Array(text[range.lowerBound...].utf8)
        return MockUpstream { _ in
            reply(streaming: AsyncStream { continuation in
                let task = Task {
                    continuation.yield(head)
                    try? await Task.sleep(for: stall)
                    continuation.yield(tail)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            })
        }
    }

    @Test func anthropicGetsPings() async throws {
        let upstream = Self.stalling(fixture("Anthropic/streams/text.sse"), splitAt: "event: content_block_delta")
        let gateway = makeGateway(upstream, model: "anthropic/claude-sonnet-4-5", keepalive: .milliseconds(100))
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "x", stream: true))
            let stream = decodeStream(response.body, as: .anthropicMessages)
            // The fixture has one ping of its own.
            #expect(stream.eventNames.filter { $0 == "ping" }.count >= 3)
            #expect(stream.text == "Hello world")
        }
    }

    @Test func responsesGetsInProgressEvents() async throws {
        let upstream = Self.stalling(fixture("Anthropic/streams/text.sse"), splitAt: "event: content_block_delta")
        let gateway = makeGateway(upstream, model: "anthropic/claude-sonnet-4-5", keepalive: .milliseconds(100))
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/responses", ClientRequest.responses(model: "x", stream: true))
            let stream = decodeStream(response.body, as: .responses)
            #expect(stream.eventNames.filter { $0 == "response.in_progress" }.count >= 3)
            let numbers = stream.dataObjects.compactMap { $0["sequence_number"]?.numberValue?.int }
            #expect(numbers == Array(0..<numbers.count))
            #expect(stream.text == "Hello world")
            #expect(stream.eventNames.last == "response.completed")
        }
    }

    // Keepalives start with the response, at the upstream's first content:
    // the stalls below come after it.
    @Test func chatGetsComments() async throws {
        let upstream = Self.stalling(fixture("Chat/streams/text_usage.sse"), splitAt: "data: ", occurrence: 2)
        let gateway = makeGateway(upstream, keepalive: .milliseconds(100))
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x", stream: true))
            let stream = decodeStream(response.body, as: .chatCompletions)
            #expect(stream.comments.count >= 3)
            #expect(!stream.text.isEmpty)
        }
    }

    @Test func geminiGetsNothing() async throws {
        let upstream = Self.stalling(fixture("Chat/streams/text_usage.sse"), splitAt: "data: ", occurrence: 2)
        let gateway = makeGateway(upstream, keepalive: .milliseconds(100))
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post(ClientRequest.geminiPath(model: "x", stream: true), ClientRequest.gemini)
            let stream = decodeStream(response.body, as: .gemini)
            #expect(stream.comments.isEmpty)
            let body = String(buffer: response.body)
            #expect(!body.hasPrefix(":") && !body.contains("\n:"))
            #expect(!stream.text.isEmpty)
        }
    }
}
