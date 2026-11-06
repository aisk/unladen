/// The wire protocol an endpoint speaks.
///
/// The stable, public twin of the semi-public `WireProtocol`: configuration
/// types name protocols without importing the wire model.
public enum APIProtocol: String, Hashable, Sendable, CaseIterable {
    /// OpenAI Chat Completions (`{base}/chat/completions`).
    case chatCompletions = "chat"
    /// OpenAI Responses (`{base}/responses`).
    case responses
    /// Anthropic Messages (`{base}/v1/messages`).
    case anthropicMessages = "anthropic"
    /// Google Gemini (`{base}/v1beta/models/{model}:generateContent`).
    case gemini
}

extension APIProtocol {
    @_spi(Wire) public var wire: WireProtocol {
        switch self {
        case .chatCompletions: .chatCompletions
        case .responses: .responses
        case .anthropicMessages: .anthropicMessages
        case .gemini: .gemini
        }
    }

    @_spi(Wire) public init(_ wire: WireProtocol) {
        switch wire {
        case .chatCompletions: self = .chatCompletions
        case .responses: self = .responses
        case .anthropicMessages: self = .anthropicMessages
        case .gemini: self = .gemini
        }
    }
}

/// How an endpoint wants the API key.
public enum EndpointAuth: Hashable, Sendable {
    /// `Authorization: Bearer <key>`.
    case bearer
    /// `x-api-key: <key>` plus `anthropic-version` (unless the endpoint's
    /// static headers or a forwarded client header set one).
    case anthropic(version: String = "2023-06-01")
    /// `x-goog-api-key: <key>`.
    case googleAPIKey
    /// No credentials (local servers).
    case none
}

/// One HTTP API of a provider: where it is, which protocol it speaks, how it
/// authenticates, and whose fidelity data it accepts.
///
/// A provider with several protocols (OpenAI's Chat and Responses,
/// DeepSeek's Chat and Anthropic) has one endpoint per protocol. The base URL
/// follows each protocol's SDK convention: OpenAI-style bases include the
/// version (`https://api.openai.com/v1`), Anthropic and Gemini bases do not
/// (`https://api.anthropic.com`, `https://generativelanguage.googleapis.com`).
public struct Endpoint: Hashable, Sendable {
    /// The system id stamped on fidelity data this endpoint produces
    /// (signatures, encrypted reasoning, item ids), e.g. `"anthropic"`,
    /// `"openai"`, `"gemini"`, `"bedrock"`.
    public var system: String
    public var apiProtocol: APIProtocol
    public var baseURL: String
    public var auth: EndpointAuth
    /// Headers sent on every request (lowercase names recommended). A
    /// forwarded client header of the same name replaces one of these;
    /// credentials always replace both.
    public var headers: [String: String]
    /// Client headers the gateway may forward to this endpoint, by
    /// case-insensitive name (e.g. `anthropic-beta`). Credentials and
    /// hop-by-hop headers are never forwarded, whatever this says.
    public var forwardedHeaders: Set<String>
    /// Systems whose signatures and encrypted reasoning this endpoint
    /// accepts. Defaults to ``system`` alone. Claude direct, Bedrock and
    /// Vertex do not accept each other's; OpenAI and its Codex backend do.
    public var trustedOrigins: Set<String>
    /// Endpoint-level Profile defaults; a matching model rule's Profile is
    /// merged over it (see ``Provider``).
    public var defaults: Profile

    public init(
        system: String,
        apiProtocol: APIProtocol,
        baseURL: String,
        auth: EndpointAuth = .bearer,
        headers: [String: String] = [:],
        forwardedHeaders: Set<String> = [],
        trustedOrigins: Set<String>? = nil,
        defaults: Profile = Profile(),
    ) {
        self.system = system
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.auth = auth
        self.headers = headers
        self.forwardedHeaders = forwardedHeaders
        self.trustedOrigins = trustedOrigins ?? [system]
        self.defaults = defaults
    }
}
