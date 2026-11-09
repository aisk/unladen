@_spi(Wire) import UnladenCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The entry point: which providers exist, how to reach them, and where
/// the API keys are.
///
/// ```swift
/// import Unladen
///
/// // Apple platforms use URLSession by default. On Linux, add the
/// // UnladenAsyncHTTPClient product and pass `transport: AsyncHTTPClientTransport()`.
/// let client = ModelClient(apiKeys: ["anthropic": "sk-ant-…"]) // or ANTHROPIC_API_KEY
/// let model = try client.model("anthropic/claude-sonnet-4-6")
///
/// // One call.
/// let weather = Tool(
///     name: "get_weather",
///     description: "Current weather for a city",
///     inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
/// )
/// var history: [Message] = [.user("Weather in Paris?")]
/// let response = try await model.generate(history, tools: [weather])
/// history.append(response.message) // replay tokens (signatures…) included
/// for call in response.toolCalls {
///     history.append(.tool(ToolResult(call: call, output: "18°C, sunny")))
/// }
///
/// // Streaming.
/// for try await part in model.stream(history, tools: [weather]) {
///     if case .textDelta(_, let delta) = part { print(delta, terminator: "") }
/// }
///
/// // The same history can go to another vendor: replay data it cannot
/// // verify is left out automatically.
/// let fallback = try client.model("openai/gpt-5.2")
/// let answer = try await fallback.generate(history, tools: [weather])
/// ```
///
/// A value: copy it and change ``registry``, ``apiKeys`` or
/// ``warningPolicy`` freely. Models resolved from it keep the settings they
/// were resolved with.
public struct ModelClient: Sendable {
    public var registry: ProviderRegistry
    public var transport: any HTTPTransport
    /// API keys by provider id (`"openai"`, `"anthropic"`…). Take precedence
    /// over the environment.
    public var apiKeys: [String: String]
    /// Where ``Provider/apiKeyEnvironmentVariables`` are looked up; `nil`
    /// is the process environment.
    public var environment: [String: String]?
    public var warningPolicy: WarningPolicy

    public init(
        transport: any HTTPTransport,
        registry: ProviderRegistry = .builtIn,
        apiKeys: [String: String] = [:],
        environment: [String: String]? = nil,
        warningPolicy: WarningPolicy = .strict,
    ) {
        self.transport = transport
        self.registry = registry
        self.apiKeys = apiKeys
        self.environment = environment
        self.warningPolicy = warningPolicy
    }

    #if canImport(Darwin)
    /// A client using `URLSession`.
    public init(
        registry: ProviderRegistry = .builtIn,
        apiKeys: [String: String] = [:],
        environment: [String: String]? = nil,
        warningPolicy: WarningPolicy = .strict,
    ) {
        self.init(
            transport: URLSessionTransport(), registry: registry, apiKeys: apiKeys,
            environment: environment, warningPolicy: warningPolicy,
        )
    }
    #else
    @available(*, unavailable, message: "Linux has no default transport: add the UnladenAsyncHTTPClient product, `import UnladenAsyncHTTPClient` and pass `transport: AsyncHTTPClientTransport()`")
    public init(
        registry: ProviderRegistry = .builtIn,
        apiKeys: [String: String] = [:],
        environment: [String: String]? = nil,
        warningPolicy: WarningPolicy = .strict,
    ) {
        fatalError("unavailable")
    }
    #endif

    /// The model named by `"provider/model"` (e.g. `"openai/gpt-5.2"`,
    /// `"openrouter/anthropic/claude-sonnet-4-6"`).
    ///
    /// - Parameter preferred: the protocol to use when the provider offers
    ///   several (OpenAI: Responses first, then Chat), unless the model's
    ///   Profile forces one.
    /// - Throws: ``UnladenError/invalidModelReference(_:_:)``, or
    ///   ``UnladenError/missingAPIKey(provider:environmentVariables:)`` when
    ///   the endpoint needs a key and none is configured.
    public func model(_ reference: String, preferring preferred: APIProtocol? = nil) throws(UnladenError) -> LanguageModel {
        let target: ResolvedModel
        do {
            target = try registry.resolve(reference, preferring: preferred)
        } catch {
            throw .invalidModelReference(reference, error)
        }
        return try model(target)
    }

    /// A model resolved by hand (any endpoint and Profile).
    public func model(_ target: ResolvedModel) throws(UnladenError) -> LanguageModel {
        LanguageModel(target: target, apiKey: try apiKey(for: target), transport: transport, warningPolicy: warningPolicy)
    }

    /// The key for `target`: ``apiKeys`` by provider id, then the provider's
    /// environment variables; `nil` for endpoints without auth.
    func apiKey(for target: ResolvedModel) throws(UnladenError) -> String? {
        if let key = apiKeys[target.provider], !key.isEmpty { return key }
        let variables = registry[target.provider]?.apiKeyEnvironmentVariables ?? []
        for name in variables {
            if let value = lookup(name), !value.isEmpty { return value }
        }
        if target.endpoint.auth == .none { return nil }
        throw .missingAPIKey(provider: target.provider, environmentVariables: variables)
    }

    private func lookup(_ name: String) -> String? {
        if let environment { return environment[name] }
        guard let value = getenv(name) else { return nil }
        return String(cString: value)
    }
}

/// One model on one endpoint, with its key: what `generate` and `stream`
/// are called on. Cheap to copy and `Sendable`.
public struct LanguageModel: Sendable {
    /// The endpoint, model id and merged Profile in use.
    public let target: ResolvedModel
    public var warningPolicy: WarningPolicy
    let apiKey: String?
    let transport: any HTTPTransport

    init(target: ResolvedModel, apiKey: String?, transport: any HTTPTransport, warningPolicy: WarningPolicy) {
        self.target = target
        self.apiKey = apiKey
        self.transport = transport
        self.warningPolicy = warningPolicy
    }

    /// `"provider/model"`.
    public var reference: String { "\(target.provider)/\(target.model)" }

    // MARK: Generate

    /// Sends `request` and waits for the whole response.
    ///
    /// - Throws: ``UnladenError``; `CancellationError` if the task is
    ///   cancelled (the upstream request is cancelled with it).
    public func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let call = try prepare(request, stream: false)
        let reply: UpstreamReply
        do {
            reply = try await call.upstream.send(call.request, stream: false)
        } catch {
            throw UnladenError.map(error)
        }
        guard case .response(let wire) = reply.body else {
            throw UnladenError.invalidResponse("expected a complete reply")
        }
        let replyWarnings = reply.replyWarnings.map(WireConversion.warning)
        return WireConversion.response(wire, system: target.endpoint.system, warnings: call.warnings + replyWarnings)
    }

    public func generate(
        _ messages: [Message],
        tools: [Tool] = [],
        toolChoice: ToolChoice? = nil,
        settings: GenerationSettings = GenerationSettings(),
    ) async throws -> ModelResponse {
        try await generate(ModelRequest(messages: messages, tools: tools, toolChoice: toolChoice, settings: settings))
    }

    /// One user message.
    public func generate(_ prompt: String, settings: GenerationSettings = GenerationSettings()) async throws -> ModelResponse {
        try await generate([.user(prompt)], settings: settings)
    }

    // MARK: Stream

    /// The response as it is generated. Nothing is sent until iteration
    /// starts; each iteration sends its own request. Errors, including
    /// ``UnladenError/unsupported(_:)``, are thrown from the iteration.
    public func stream(_ request: ModelRequest) -> ResponseStream {
        ResponseStream(model: self, request: request)
    }

    public func stream(
        _ messages: [Message],
        tools: [Tool] = [],
        toolChoice: ToolChoice? = nil,
        settings: GenerationSettings = GenerationSettings(),
    ) -> ResponseStream {
        stream(ModelRequest(messages: messages, tools: tools, toolChoice: toolChoice, settings: settings))
    }

    public func stream(_ prompt: String, settings: GenerationSettings = GenerationSettings()) -> ResponseStream {
        stream([.user(prompt)], settings: settings)
    }

    // MARK: Pipeline

    struct PreparedCall {
        var upstream: UpstreamCall
        var request: UpstreamRequest
        /// Request-side warnings that were not escalated.
        var warnings: [CallWarning]
    }

    /// Replay policy → semantic-to-wire conversion → Profile transforms and
    /// encoding → warning policy → provider options.
    func prepare(_ request: ModelRequest, stream: Bool) throws(UnladenError) -> PreparedCall {
        let endpoint = target.endpoint
        var semantic = request
        var (messages, notices) = WireConversion.forTarget(request.messages, trusted: endpoint.trustedOrigins)
        semantic.messages = messages
        let wire = try WireConversion.request(
            semantic, model: target.model, target: WireConversion.Target(apiProtocol: endpoint.apiProtocol, system: endpoint.system),
            chatDialect: endpoint.apiProtocol.wire == .chatCompletions, warnings: &notices,
        )

        let upstream = UpstreamCall(target: target, apiKey: apiKey, transport: transport)
        var prepared: UpstreamRequest
        do {
            prepared = try upstream.prepare(wire, stream: stream)
        } catch {
            throw UnladenError.map(error) as? UnladenError ?? .invalidRequest("\(error)")
        }
        let warnings = notices + prepared.warnings.map(WireConversion.warning)
        if warningPolicy == .strict {
            let fatal = warnings.filter(\.isEscalatedWhenStrict)
            if !fatal.isEmpty { throw .unsupported(fatal) }
        }
        let options = request.settings.providerOptions
        if !options.isEmpty, let body = try? JSONValue(parsing: prepared.body) {
            prepared.body = WireConversion.merge(options, into: body, protocol: endpoint.apiProtocol, system: endpoint.system).encoded()
        }
        return PreparedCall(upstream: upstream, request: prepared, warnings: warnings)
    }
}
