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
/// - `POST /v1/messages/count_tokens`: an estimate of the request's input
///   tokens, without calling an upstream;
/// - `GET /v1/models`: the configured models, in a shape OpenAI and
///   Anthropic clients both read;
/// - `GET /health`: `ok`, without authentication.
/// - `/admin` and `/admin/api/*` with a `manager`: the control panel.
func buildRouter(gateway: Gateway, manager: ConfigManager? = nil) -> Router<GatewayRequestContext> {
    let router = Router(context: GatewayRequestContext.self)
    if let manager { addAdminRoutes(to: router, manager: manager) }

    router.get("/health") { _, _ in
        Response(status: .ok, headers: [.contentType: "text/plain"], body: ResponseBody(byteBuffer: ByteBuffer(string: "ok\n")))
    }

    router.get("/v1/models") { request, _ in
        let configuration = gateway.configuration
        switch authenticate(request, configuration: configuration, as: .chatCompletions) {
        case .denied(let response): return response
        case .allowed(let access): return modelList(await gateway.modelNames(configuration, access: access))
        }
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
        await countTokens(request, gateway: gateway)
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
    let configuration = gateway.configuration
    let access: ClientAccess
    switch authenticate(request, configuration: configuration, as: clientProtocol) {
    case .denied(let response): return response
    case .allowed(let allowed): access = allowed
    }
    let body: [UInt8]
    switch await readBody(request, clientProtocol, configuration: configuration) {
    case .success(let bytes): body = bytes
    case .failure(let refusal): return refusal.response
    }
    let monitor = await DisconnectMonitor.install(on: context.channel)
    let logger = context.logger
    return await gateway.handle(
        clientProtocol,
        body: body,
        geminiPath: geminiPath,
        headers: request.headers,
        access: access,
        configuration: configuration,
        monitor: monitor,
        log: RequestLog { logger.info("\($0)") },
    )
}

/// An error response, as a `Result` failure.
private struct Refusal: Error {
    var response: Response
}

/// The request's body, up to the configuration's limit.
private func readBody(
    _ request: Request, _ clientProtocol: WireProtocol, configuration: GatewayConfiguration,
) async -> Result<[UInt8], Refusal> {
    var request = request
    do {
        let buffer = try await request.collectBody(upTo: configuration.maxRequestBytes)
        return .success(Array(buffer.readableBytesView))
    } catch is NIOTooManyBytesError {
        return .failure(Refusal(response: Gateway.errorResponse(
            clientProtocol, status: 413, message: "request body larger than \(configuration.maxRequestBytes) bytes",
        )))
    } catch {
        return .failure(Refusal(response: Gateway.errorResponse(clientProtocol, status: 400, message: "cannot read the request body: \(error)")))
    }
}

/// `POST /v1/messages/count_tokens`: a Messages request without
/// `max_tokens`, answered with `{"input_tokens": N}`, N being
/// ``ConversationContext/estimatedTokens(_:)`` of it. The client's key must
/// be allowed the model, as for `/v1/messages`; no upstream is called.
private func countTokens(_ request: Request, gateway: Gateway) async -> Response {
    let configuration = gateway.configuration
    let access: ClientAccess
    switch authenticate(request, configuration: configuration, as: .anthropicMessages) {
    case .denied(let response): return response
    case .allowed(let allowed): access = allowed
    }
    let body: [UInt8]
    switch await readBody(request, .anthropicMessages, configuration: configuration) {
    case .success(let bytes): body = bytes
    case .failure(let refusal): return refusal.response
    }
    // The Messages decoder requires `max_tokens`, which a count has no
    // use for.
    guard var object = (try? JSONValue(parsing: body))?.objectValue else {
        return Gateway.errorResponse(.anthropicMessages, status: 400, message: "invalid request: expected a JSON object")
    }
    if object["max_tokens"] == nil { object["max_tokens"] = 1 }
    let decoded: WireRequest
    do {
        decoded = try ClientCodec.parseRequest(.anthropicMessages, body: JSONValue.object(object).encoded()).value
    } catch {
        return Gateway.errorResponse(.anthropicMessages, status: 400, message: "invalid request: \(error)")
    }
    do {
        _ = try CandidatePlanner(configuration: configuration).plan(for: decoded.model, access: access)
    } catch {
        return Gateway.errorResponse(.anthropicMessages, status: error.status, message: error.message)
    }
    let reply: JSONValue = ["input_tokens": .number(JSONNumber(ConversationContext.estimatedTokens(decoded)))]
    return Response(
        status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: reply.encoded())),
    )
}

enum Authentication {
    case allowed(ClientAccess)
    /// A 401 in the client's error shape.
    case denied(Response)
}

/// Who the request comes from: any client when no client is configured,
/// else the key it presents. Clients that are all disabled let nobody in.
private func authenticate(_ request: Request, configuration: GatewayConfiguration, as clientProtocol: WireProtocol) -> Authentication {
    let configured = configuration.clientKeys
    guard !configuration.isOpen else { return .allowed(.open) }
    let presented = presentedKeys(request, acceptingQueryKey: clientProtocol == .gemini)
    // Every configured key is compared, so the time taken does not tell
    // which one matched.
    var match: ClientKey?
    for key in configured where presented.contains(where: { constantTimeEqual($0, key.secret) }) {
        match = match ?? key
    }
    if let match { return .allowed(.key(match)) }
    return .denied(Gateway.errorResponse(clientProtocol, status: 401, message: "invalid or missing gateway API key"))
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

