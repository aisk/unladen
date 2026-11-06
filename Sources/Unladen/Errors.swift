@_spi(Wire) import UnladenCore

/// Everything a model call throws, except `CancellationError`, which is
/// passed through unchanged when the calling task is cancelled.
public enum UnladenError: Error, Sendable, CustomStringConvertible {
    /// The `"provider/model"` reference does not resolve.
    case invalidModelReference(String, ModelReferenceError)
    /// The provider needs an API key and none was configured or found in
    /// its environment variables.
    case missingAPIKey(provider: String, environmentVariables: [String])
    /// The request is malformed (e.g. a tool result in a user message, a
    /// non-finite temperature) or the endpoint configuration is invalid.
    case invalidRequest(String)
    /// The request cannot be sent exactly as asked to this model, and the
    /// policy is ``WarningPolicy/strict``. Nothing was sent. The warnings
    /// say what would have been dropped or changed.
    case unsupported([CallWarning])
    /// The provider answered with an error status.
    case http(ProviderHTTPError)
    /// The provider reported an error in the middle of a stream.
    case stream(ProviderStreamError)
    /// The provider's reply is not valid for its protocol.
    case invalidResponse(String)
    /// The transport failed before a response arrived (connection, TLS,
    /// timeout).
    case transport(any Error)

    public var description: String {
        switch self {
        case .invalidModelReference(let reference, let error): "invalid model reference `\(reference)`: \(error)"
        case .missingAPIKey(let provider, let variables):
            variables.isEmpty
                ? "no API key for provider `\(provider)`"
                : "no API key for provider `\(provider)`; set \(variables.joined(separator: " or ")) or pass one explicitly"
        case .invalidRequest(let message): "invalid request: \(message)"
        case .unsupported(let warnings): "request not supported as asked: \(warnings.map(\.description).joined(separator: "; "))"
        case .http(let error): error.description
        case .stream(let error): "stream error: \(error.message)"
        case .invalidResponse(let message): "invalid response: \(message)"
        case .transport(let error): "transport error: \(error)"
        }
    }
}

/// A non-2xx reply from the provider.
public struct ProviderHTTPError: Hashable, Sendable, CustomStringConvertible {
    /// The reply as received: status, all headers, raw body.
    public var underlying: UpstreamHTTPError

    public init(_ underlying: UpstreamHTTPError) {
        self.underlying = underlying
    }

    public var statusCode: Int { underlying.status.code }
    /// `Retry-After`, verbatim (seconds or an HTTP date).
    public var retryAfter: String? { underlying.retryAfter }
    /// `Retry-After` when it is a number of seconds.
    public var retryAfterSeconds: Int? { retryAfter.flatMap { Int(String($0.filter { !$0.isWhitespace })) } }
    /// The provider's request id, for support tickets.
    public var requestID: String? { underlying.requestID }
    public var body: String { String(decoding: underlying.body, as: UTF8.self) }

    /// `error.message` from the JSON body, the shape OpenAI, Anthropic and
    /// Gemini all use; `nil` if the body is something else.
    public var providerMessage: String? {
        guard let json = try? JSONValue(parsing: underlying.body) else { return nil }
        if let message = json["error"]?["message"]?.stringValue { return message }
        if let message = json["error"]?.stringValue { return message }
        return json["message"]?.stringValue
    }

    /// `true` for 408, 409, 429 and 5xx: worth retrying, after
    /// ``retryAfterSeconds`` if given.
    public var isRetryable: Bool {
        [408, 409, 429].contains(statusCode) || statusCode >= 500
    }

    public var description: String {
        "HTTP \(statusCode): \(providerMessage ?? String(body.prefix(512)))"
    }
}

/// An error event inside a provider's stream.
public struct ProviderStreamError: Hashable, Sendable {
    public var message: String
    /// The provider's error type (`overloaded_error`, `server_error`…).
    public var type: String?
    public var code: String?
    /// The error object as sent, when it was JSON.
    public var raw: JSONValue?

    public init(message: String, type: String? = nil, code: String? = nil, raw: JSONValue? = nil) {
        self.message = message
        self.type = type
        self.code = code
        self.raw = raw
    }
}

extension UnladenError {
    /// Maps what an upstream call threw: cancellation passes through,
    /// `UpstreamError` and decoding errors become their cases, anything else
    /// is a transport failure.
    static func map(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        switch error {
        case let error as UnladenError: return error
        case let error as UpstreamError:
            switch error {
            case .invalidBaseURL(let url): return UnladenError.invalidRequest("invalid endpoint base URL `\(url)`")
            case .http(let http): return UnladenError.http(ProviderHTTPError(http))
            case .decoding(let decoding, _): return UnladenError.invalidResponse(decoding.description)
            case .stream(let stream): return UnladenError.stream(ProviderStreamError(stream))
            }
        case let error as WireDecodingError: return UnladenError.invalidResponse(error.description)
        case let error as HTTPResponseBodyTooLargeError: return UnladenError.invalidResponse("reply larger than \(error.maxBytes) bytes")
        default: return UnladenError.transport(error)
        }
    }
}

extension ProviderStreamError {
    init(_ wire: WireStreamError) {
        self.init(message: wire.message, type: wire.type, code: wire.code, raw: wire.raw)
    }
}
