// HTTP surface: the request context, client authentication and routes.

import HTTPTypes
import Hummingbird
import NIOCore
@_spi(Wire) import UnladenCore

/// Request context that keeps the connection, for disconnect detection.
struct GatewayRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    let channel: any Channel

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        channel = source.channel
    }
}

/// Builds the gateway's router.
///
/// Routes:
/// - `POST /v1/chat/completions` (Chat), `POST /v1/responses` (Responses),
///   `POST /v1/messages` (Anthropic), `POST /v1beta/models/{model}:generateContent`
///   and `:streamGenerateContent` (Gemini; also under `/v1/models/`);
/// - `POST /v1/messages/count_tokens`: 501 (not supported);
/// - `GET /v1/models`: the configured models, in a shape OpenAI and
///   Anthropic clients both read;
/// - `GET /health`: `ok`, without authentication.
func buildRouter(gateway: Gateway) -> Router<GatewayRequestContext> {
    let router = Router(context: GatewayRequestContext.self)

    router.get("/health") { _, _ in
        Response(status: .ok, headers: [.contentType: "text/plain"], body: ResponseBody(byteBuffer: ByteBuffer(string: "ok\n")))
    }

    router.get("/v1/models") { request, _ in
        if let denied = authenticate(request, gateway: gateway, as: .chatCompletions) { return denied }
        return modelList(gateway.configuration)
    }

    router.post("/v1/chat/completions") { request, context in
        try await serve(.chatCompletions, request: request, context: context, gateway: gateway)
    }
    router.post("/v1/responses") { request, context in
        try await serve(.responses, request: request, context: context, gateway: gateway)
    }
    router.post("/v1/messages") { request, context in
        try await serve(.anthropicMessages, request: request, context: context, gateway: gateway)
    }
    router.post("/v1/messages/count_tokens") { request, _ in
        if let denied = authenticate(request, gateway: gateway, as: .anthropicMessages) { return denied }
        return Gateway.errorResponse(.anthropicMessages, status: 501, message: "count_tokens is not supported by this gateway")
    }
    for prefix in ["/v1beta/models/**", "/v1/models/**"] {
        router.post(RouterPath(prefix)) { request, context in
            guard let path = GeminiCodec.parsePath(request.uri.path) else {
                return Gateway.errorResponse(.gemini, status: 404, message: "unknown method \(request.uri.path)")
            }
            return try await serve(.gemini, request: request, context: context, gateway: gateway, geminiPath: path)
        }
    }
    return router
}

/// Reads the body, checks the client's key and hands the request to the
/// gateway under a disconnect monitor.
private func serve(
    _ clientProtocol: WireProtocol,
    request: Request,
    context: GatewayRequestContext,
    gateway: Gateway,
    geminiPath: (model: String, stream: Bool)? = nil,
) async throws -> Response {
    if let denied = authenticate(request, gateway: gateway, as: clientProtocol) { return denied }
    var request = request
    let body: [UInt8]
    do {
        let buffer = try await request.collectBody(upTo: gateway.configuration.maxRequestBytes)
        body = Array(buffer.readableBytesView)
    } catch {
        return Gateway.errorResponse(clientProtocol, status: 413, message: "request body larger than \(gateway.configuration.maxRequestBytes) bytes")
    }
    let monitor = await DisconnectMonitor.install(on: context.channel)
    let logger = context.logger
    return await gateway.handle(
        clientProtocol,
        body: body,
        geminiPath: geminiPath,
        headers: request.headers,
        monitor: monitor,
        log: RequestLog { logger.info("\($0)") },
    )
}

/// `nil` if the request may use the gateway; else a 401 in the client's
/// error shape.
private func authenticate(_ request: Request, gateway: Gateway, as clientProtocol: WireProtocol) -> Response? {
    guard let expected = gateway.configuration.apiKey else { return nil }
    let keys = presentedKeys(request, acceptingQueryKey: clientProtocol == .gemini)
    if keys.contains(where: { constantTimeEqual($0, expected) }) { return nil }
    return Gateway.errorResponse(clientProtocol, status: 401, message: "invalid or missing gateway API key")
}

/// Keys a client may present: `Authorization: Bearer`, `x-api-key`,
/// `x-goog-api-key`, and, with `acceptingQueryKey` (Gemini routes only:
/// no other protocol's clients send it, and a key in a URL ends up in
/// logs), `?key=`.
func presentedKeys(_ request: Request, acceptingQueryKey: Bool) -> [String] {
    var keys: [String] = []
    if let authorization = request.headers[.authorization] {
        let parts = authorization.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].lowercased() == "bearer" { keys.append(parts[1].trimmingBlanks()) }
    }
    for name in ["x-api-key", "x-goog-api-key"] {
        if let field = HTTPField.Name(name), let value = request.headers[field] { keys.append(value) }
    }
    if acceptingQueryKey, let key = request.uri.queryParameters.get("key") { keys.append(key) }
    return keys
}

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var difference = UInt8(x.count == y.count ? 0 : 1)
    for i in 0..<max(x.count, y.count) {
        difference |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return difference == 0
}

/// The configured models (default first, then fallbacks), readable by
/// OpenAI clients (`object`, `data[].id`, `owned_by`) and Anthropic clients
/// (`data[].type`, `display_name`, `has_more`).
func modelList(_ configuration: GatewayConfiguration) -> Response {
    var references: [String] = []
    for reference in [configuration.defaultModel].compactMap({ $0 }) + configuration.fallbacks where !references.contains(reference) {
        references.append(reference)
    }
    let data: [JSONValue] = references.map { reference in
        let provider = reference.split(separator: "/", maxSplits: 1).first.map(String.init) ?? reference
        return [
            "id": .string(reference),
            "object": "model",
            "type": "model",
            "display_name": .string(reference),
            "owned_by": .string(provider),
            "created": 0,
            "created_at": "1970-01-01T00:00:00Z",
        ]
    }
    let json: JSONValue = [
        "object": "list",
        "data": .array(data),
        "has_more": false,
        "first_id": references.first.map(JSONValue.string) ?? .null,
        "last_id": references.last.map(JSONValue.string) ?? .null,
    ]
    return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: json.encoded())))
}
