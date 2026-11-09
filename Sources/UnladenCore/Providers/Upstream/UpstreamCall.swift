public import HTTPTypes

/// A non-2xx upstream reply, kept verbatim so a same-protocol gateway can
/// forward it as is (status, headers and body bytes).
public struct UpstreamHTTPError: Error, Hashable, Sendable, CustomStringConvertible {
    public var status: HTTPResponse.Status
    public var headerFields: HTTPFields
    /// The body as received (up to the call's error-body limit).
    public var body: [UInt8]

    public init(status: HTTPResponse.Status, headerFields: HTTPFields, body: [UInt8]) {
        self.status = status
        self.headerFields = headerFields
        self.body = body
    }

    /// `Retry-After`, verbatim (seconds or an HTTP date).
    public var retryAfter: String? { headerFields[.retryAfter] }

    /// The provider's request id (`request-id`, `x-request-id`,
    /// `x-goog-request-id`…), when it sent one.
    public var requestID: String? {
        for name in ["request-id", "x-request-id", "x-goog-request-id", "openai-request-id", "cf-ray"] {
            if let field = HTTPField.Name(name), let value = headerFields[field] { return value }
        }
        return nil
    }

    public var description: String {
        "upstream HTTP \(status.code): \(String(decoding: body.prefix(512), as: UTF8.self))"
    }
}

/// Why an upstream call failed after the transport delivered a reply.
/// Transport failures (connection, TLS, cancellation) are thrown as the
/// transport threw them.
@_spi(Wire) public enum UpstreamError: Error, Hashable, Sendable {
    /// The endpoint's base URL is not `scheme://authority[/path]`.
    case invalidBaseURL(String)
    /// The upstream answered with a non-2xx status.
    case http(UpstreamHTTPError)
    /// A 2xx body that is not a valid reply of the protocol.
    case decoding(WireDecodingError, body: [UInt8])
    /// A stream that was collected into a reply reported an error.
    case stream(WireStreamError)
}

/// A request ready to send: what ``UpstreamCall/prepare(_:stream:clientHeaders:)``
/// builds. Exposed for logging and tests.
@_spi(Wire) public struct UpstreamRequest: Sendable {
    public var http: HTTPRequest
    public var body: [UInt8]
    /// Whether the upstream is asked to stream (the Profile may force it).
    public var streams: Bool
    /// The wire request after transforms, as encoded.
    public var wire: WireRequest
    /// Transform and encoder warnings.
    public var warnings: [WireWarning]
    /// Custom tools sent as functions, to map back on the reply.
    public var customTools: Set<String>
}

/// A 2xx upstream reply.
@_spi(Wire) public struct UpstreamReply: Sendable {
    public enum Body: Sendable {
        case response(WireResponse)
        case events(UpstreamEventStream)
    }

    /// The upstream's response head (request id, rate-limit headers…).
    public var head: HTTPResponse
    public var body: Body
    /// Request-side warnings (transforms, encoding) plus, for a complete
    /// reply, decoding warnings. Stream decoding warnings are on the
    /// stream's iterator.
    public var warnings: [WireWarning]
}

/// One call to one upstream model, shared by the library and the gateway.
///
/// Pipeline: set the model id → apply the Profile's named transforms →
/// apply Profile data (output-token cap, strict unknown fields) → encode
/// with the endpoint's protocol, trust set and Profile options → build the
/// HTTP request (path per protocol, auth, allowlisted client headers) →
/// send → decode the reply with the endpoint's system id as origin → map
/// custom tool calls back.
///
/// When the caller's streaming wish and the Profile's
/// ``Profile/streaming`` disagree, the call bridges: a forced stream is
/// folded with ``WireResponseAccumulator``; a forced complete reply is
/// replayed as events.
@_spi(Wire) public struct UpstreamCall: Sendable {
    public var target: ResolvedModel
    public var apiKey: String?
    public var transport: any HTTPTransport
    /// The conversation the request belongs to, sent in the endpoint's
    /// ``Endpoint/sessionHeader`` when it has one.
    public var session: String?
    /// Bytes kept of a non-2xx body.
    public var maxErrorBodyBytes = 1 << 20
    /// Largest complete (non-streaming) reply accepted.
    public var maxResponseBytes = 64 << 20

    public init(target: ResolvedModel, apiKey: String?, transport: any HTTPTransport, session: String? = nil) {
        self.target = target
        self.apiKey = apiKey
        self.transport = transport
        self.session = session
    }

    /// Client headers never forwarded, whatever an endpoint allows:
    /// credentials (always the gateway's own), and what the call or the
    /// connection sets itself.
    public static let neverForwarded: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "x-goog-api-key", "api-key", "cookie",
        "host", "content-length", "content-type", "accept", "accept-encoding", "connection",
        "transfer-encoding", "te", "upgrade", "keep-alive", "proxy-connection",
    ]

    // MARK: Prepare

    /// Transforms and encodes `request` and builds the HTTP request.
    ///
    /// - Parameters:
    ///   - stream: whether the caller wants a stream.
    ///   - clientHeaders: the gateway client's headers; only those in the
    ///     endpoint's ``Endpoint/forwardedHeaders`` are sent.
    public func prepare(_ request: WireRequest, stream: Bool, clientHeaders: HTTPFields = [:]) throws(UpstreamError) -> UpstreamRequest {
        let endpoint = target.endpoint
        let profile = target.profile
        let wire = endpoint.apiProtocol.wire
        var request = request
        request.model = target.model

        var outcome = ProfileTransform.apply(
            profile.transforms ?? [], to: &request,
            context: WireTransformContext(target: wire, endpoint: endpoint, profile: profile),
        )
        if let cap = profile.maxOutputTokens, let asked = request.maxOutputTokens, asked > cap {
            request.maxOutputTokens = cap
            outcome.warnings.append(WireWarning(.adjusted, "max output tokens \(asked) lowered to the model's \(cap)", path: "max_tokens"))
        }
        if profile.strictUnknownFields == true {
            WireTransforms.stripOpenAIPlatformFields(&request, warnings: &outcome.warnings)
            if request.source == wire { WireTransforms.stripUnknownFields(&request, target: wire, warnings: &outcome.warnings) }
        }
        // After the strip: what is left is what the encoder writes.
        if let max = profile.maxCacheBreakpoints {
            let chat = profile.chatCacheControlOption
            WireTransforms.limitCacheBreakpoints(&request, max: max, target: wire, chatCacheControl: chat, warnings: &outcome.warnings)
            WireTransforms.raiseEarlierCacheTTLs(&request, target: wire, chatCacheControl: chat, warnings: &outcome.warnings)
        }

        let streams = switch profile.streaming {
        case .always?: true
        case .never?: false
        case nil: stream
        }
        if wire == .gemini {
            request.stream = nil
        } else {
            request.stream = streams ? true : (request.stream == nil ? nil : false)
        }
        if !streams {
            request.streamOptions = nil
        } else if wire == .chatCompletions, profile.chatStreamUsage != false {
            request.streamOptions = WireStreamOptions(includeUsage: true, extra: request.streamOptions?.extra ?? [:])
        }

        let encoded: WireEncoded
        let suffix: String
        switch wire {
        case .chatCompletions:
            encoded = ChatCompletionsCodec.buildRequest(request, options: ChatRequestOptions(
                maxTokensKey: profile.maxTokensField?.rawValue, trustedOrigins: endpoint.trustedOrigins,
                cacheControl: profile.chatCacheControlOption,
            ))
            suffix = "/chat/completions"
        case .responses:
            encoded = ResponsesCodec.buildRequest(request, options: ResponsesRequestOptions(trustedReasoningOrigins: endpoint.trustedOrigins))
            suffix = "/responses"
        case .anthropicMessages:
            var maxTokens = profile.defaultMaxOutputTokens ?? AnthropicRequestOptions().defaultMaxTokens
            if let cap = profile.maxOutputTokens { maxTokens = min(maxTokens, cap) }
            let unsigned = profile.acceptsUnsignedThinking ?? (profile.transforms?.contains(.ensureThinkingOnToolTurns) ?? false)
            encoded = AnthropicMessagesCodec.buildRequest(request, options: AnthropicRequestOptions(
                defaultMaxTokens: maxTokens, trustedReasoningOrigins: endpoint.trustedOrigins, acceptsUnsignedThinking: unsigned,
                maxTokensCap: profile.maxOutputTokens,
            ))
            suffix = "/v1/messages"
        case .gemini:
            encoded = GeminiCodec.buildRequest(request, options: GeminiRequestOptions(
                trustedSignatureOrigins: endpoint.trustedOrigins,
                missingSignatureFallback: profile.geminiMissingSignatureFallback,
                parametersKey: profile.geminiSchemaKey?.rawValue,
            ))
            suffix = GeminiCodec.path(model: target.model, stream: streams)
        }

        guard let base = BaseURL(endpoint.baseURL) else { throw .invalidBaseURL(endpoint.baseURL) }
        var http = HTTPRequest(method: .post, scheme: base.scheme, authority: base.authority, path: base.path + suffix)
        http.headerFields = headers(clientHeaders: clientHeaders, streams: streams)
        return UpstreamRequest(
            http: http, body: encoded.body, streams: streams, wire: request,
            warnings: outcome.warnings + encoded.warnings, customTools: outcome.customTools,
        )
    }

    func headers(clientHeaders: HTTPFields, streams: Bool) -> HTTPFields {
        let endpoint = target.endpoint
        var fields = HTTPFields()
        func set(_ name: String, _ value: String) {
            guard let field = HTTPField.Name(name) else { return }
            fields[field] = value
        }
        for (name, value) in endpoint.headers.sorted(by: { $0.key < $1.key }) {
            set(name, value)
        }
        let allowed = Set(endpoint.forwardedHeaders.map { $0.lowercased() }).subtracting(Self.neverForwarded)
        var forwarded: [(HTTPField.Name, [String])] = []
        for field in clientHeaders where allowed.contains(field.name.canonicalName) {
            if let i = forwarded.firstIndex(where: { $0.0 == field.name }) {
                forwarded[i].1.append(field.value)
            } else {
                forwarded.append((field.name, [field.value]))
            }
        }
        for (name, values) in forwarded {
            fields[name] = values.joined(separator: ", ")
        }
        if let session, let name = endpoint.sessionHeader.flatMap({ HTTPField.Name($0) }), fields[name] == nil {
            fields[name] = session
        }
        fields[.contentType] = "application/json"
        fields[.accept] = streams ? "text/event-stream" : "application/json"
        for name in ["authorization", "x-api-key", "x-goog-api-key"] {
            if let field = HTTPField.Name(name) { fields[field] = nil }
        }
        switch endpoint.auth {
        case .bearer:
            if let apiKey { fields[.authorization] = "Bearer \(apiKey)" }
        case .anthropic(let version):
            if let apiKey { set("x-api-key", apiKey) }
            if let field = HTTPField.Name("anthropic-version"), fields[field] == nil { fields[field] = version }
        case .googleAPIKey:
            if let apiKey { set("x-goog-api-key", apiKey) }
        case .none:
            break
        }
        return fields
    }

    // MARK: Models

    /// The models the endpoint lists (`GET …/models` in its protocol's
    /// spelling), by the names requests give them. The target's model is
    /// not used.
    ///
    /// Throws ``UpstreamError`` for a non-2xx reply, and the transport's
    /// own errors otherwise. A reply that is not a model list lists none.
    public func listModels(maxBytes: Int = 4 << 20) async throws -> [String] {
        let endpoint = target.endpoint
        guard let base = BaseURL(endpoint.baseURL) else { throw UpstreamError.invalidBaseURL(endpoint.baseURL) }
        let suffix = switch endpoint.apiProtocol {
        case .chatCompletions, .responses: "/models"
        case .anthropicMessages: "/v1/models?limit=1000"
        case .gemini: "/v1beta/models?pageSize=1000"
        }
        var http = HTTPRequest(method: .get, scheme: base.scheme, authority: base.authority, path: base.path + suffix)
        http.headerFields = headers(clientHeaders: [:], streams: false)
        http.headerFields[.contentType] = nil
        let response = try await transport.send(http, body: nil)
        guard (200..<300).contains(response.status.code) else {
            let body = try await Self.collect(response.body, upTo: maxErrorBodyBytes, truncate: true)
            throw UpstreamError.http(UpstreamHTTPError(status: response.status, headerFields: response.response.headerFields, body: body))
        }
        let bytes = try await Self.collect(response.body, upTo: maxBytes, truncate: false)
        return Self.modelNames((try? JSONValue(parsing: bytes)) ?? .null)
    }

    /// The names of a model list: OpenAI's and Anthropic's `data[].id`,
    /// Gemini's `models[].name` (without `models/`), and ChatGPT sign-ins'
    /// `models[].slug` (without those it hides).
    package static func modelNames(_ list: JSONValue) -> [String] {
        if let data = list["data"]?.arrayValue {
            return data.compactMap { $0["id"]?.stringValue }
        }
        return (list["models"]?.arrayValue ?? []).compactMap { model in
            if model["visibility"]?.stringValue == "hide" { return nil }
            if let slug = model["slug"]?.stringValue { return slug }
            guard let name = model["name"]?.stringValue else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
        }
    }

    // MARK: Send

    /// Sends `request` and returns the reply in the shape asked for by
    /// `stream`.
    ///
    /// Throws ``UpstreamError`` for a non-2xx reply or an undecodable body,
    /// `HTTPResponseBodyTooLargeError` for a complete reply over
    /// ``maxResponseBytes``, and the transport's own errors otherwise.
    public func send(_ request: WireRequest, stream: Bool, clientHeaders: HTTPFields = [:]) async throws -> UpstreamReply {
        let prepared = try prepare(request, stream: stream, clientHeaders: clientHeaders)
        return try await send(prepared, stream: stream)
    }

    /// Sends a prepared request.
    public func send(_ prepared: UpstreamRequest, stream: Bool) async throws -> UpstreamReply {
        let wire = target.endpoint.apiProtocol.wire
        let origin = target.endpoint.system
        let response = try await transport.send(prepared.http, body: prepared.body)
        guard (200..<300).contains(response.status.code) else {
            let body = try await Self.collect(response.body, upTo: maxErrorBodyBytes, truncate: true)
            throw UpstreamError.http(UpstreamHTTPError(status: response.status, headerFields: response.response.headerFields, body: body))
        }
        var warnings = prepared.warnings
        let mapper = CustomToolReplyMapper(names: prepared.customTools)

        if prepared.streams {
            let events = UpstreamEventStream(body: response.body, decoder: AnyWireStreamDecoder(for: wire, origin: origin), mapper: mapper)
            if stream {
                return UpstreamReply(head: response.response, body: .events(events), warnings: warnings)
            }
            var accumulator = WireResponseAccumulator()
            var iterator = events.makeAsyncIterator()
            while let event = try await iterator.next() {
                accumulator.add(event)
            }
            warnings += iterator.warnings + accumulator.warnings
            if let error = accumulator.errors.first { throw UpstreamError.stream(error) }
            return UpstreamReply(head: response.response, body: .response(accumulator.response), warnings: warnings)
        }

        let bytes = try await Self.collect(response.body, upTo: maxResponseBytes, truncate: false)
        let decoded: WireDecoded<WireResponse>
        do {
            decoded = switch wire {
            case .chatCompletions: try ChatCompletionsCodec.parseResponse(bytes, origin: origin)
            case .responses: try ResponsesCodec.parseResponse(bytes, origin: origin)
            case .anthropicMessages: try AnthropicMessagesCodec.parseResponse(bytes, origin: origin)
            case .gemini: try GeminiCodec.parseResponse(bytes, origin: origin)
            }
        } catch {
            throw UpstreamError.decoding(error, body: bytes)
        }
        warnings += decoded.warnings
        let reply = mapper.map(decoded.value)
        if stream {
            let events = WireEvents.of(reply, protocolName: wire.rawValue, warnings: &warnings)
            return UpstreamReply(head: response.response, body: .events(UpstreamEventStream(replaying: events)), warnings: warnings)
        }
        return UpstreamReply(head: response.response, body: .response(reply), warnings: warnings)
    }

    static func collect(_ body: HTTPResponseBody, upTo limit: Int, truncate: Bool) async throws -> [UInt8] {
        if !truncate { return try await body.collect(upTo: limit) }
        var result: [UInt8] = []
        for try await chunk in body {
            result.append(contentsOf: chunk.prefix(limit - result.count))
            if result.count >= limit { break }
        }
        return result
    }
}

/// `scheme://authority[/path]`, split for `HTTPRequest`.
package struct BaseURL {
    package var scheme: String
    package var authority: String
    /// Without a trailing `/`; empty for none.
    package var path: String

    package init?(_ string: String) {
        guard let marker = string.firstRange(of: "://") else { return nil }
        scheme = String(string[..<marker.lowerBound]).lowercased()
        let rest = string[marker.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        authority = String(rest[..<slash])
        var path = String(rest[slash...])
        while path.hasSuffix("/") { path.removeLast() }
        self.path = path
        guard ["http", "https"].contains(scheme), !authority.isEmpty, !path.contains("?") else { return nil }
    }
}
