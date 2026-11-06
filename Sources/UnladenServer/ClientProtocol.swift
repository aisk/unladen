// The client side of each protocol: request parsing, reply encoding,
// stream encoders, keepalives and error shapes.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
@_spi(Wire) import UnladenCore

/// Ids and times a reply encoder needs when the upstream reply lacks them.
struct ReplyDefaults: Sendable {
    var id: String
    var model: String
    var created: Int
    /// Systems whose signatures and encrypted reasoning the client is given
    /// (they come back in its next request).
    var trusted: Set<WireSystemID>

    /// Defaults for a reply to a `clientProtocol` client from `candidate`.
    ///
    /// The client gets fidelity data from the systems its protocol's
    /// encoder trusts by default (Anthropic signatures for an Anthropic
    /// client…); when the upstream speaks the client's protocol, also from
    /// that upstream and the systems it trusts, so a same-protocol relay
    /// (DeepSeek's Anthropic endpoint) round-trips its own signatures.
    init(clientProtocol: WireProtocol, model: String, candidate: Candidate?) {
        let random = String(UInt64.random(in: 0...UInt64.max), radix: 16)
        id = switch clientProtocol {
        case .chatCompletions: "chatcmpl-unladen\(random)"
        case .responses: "resp_unladen\(random)"
        case .anthropicMessages: "msg_unladen\(random)"
        case .gemini: "unladen\(random)"
        }
        self.model = model
        created = Int(Date().timeIntervalSince1970)
        var trusted: Set<WireSystemID> = switch clientProtocol {
        case .chatCompletions: []
        case .responses: ["openai"]
        case .anthropicMessages: ["anthropic"]
        case .gemini: ["gemini"]
        }
        if let candidate, candidate.upstreamProtocol == clientProtocol {
            trusted.insert(candidate.target.endpoint.system)
            trusted.formUnion(candidate.target.endpoint.trustedOrigins)
        }
        self.trusted = trusted
    }
}

enum ClientCodec {
    /// Decodes a client request. Gemini requests take the model and the
    /// stream flag from the path.
    static func parseRequest(
        _ clientProtocol: WireProtocol,
        body: [UInt8],
        geminiPath: (model: String, stream: Bool)? = nil,
    ) throws(WireDecodingError) -> WireDecoded<WireRequest> {
        switch clientProtocol {
        case .chatCompletions: try ChatCompletionsCodec.parseRequest(body)
        case .responses: try ResponsesCodec.parseRequest(body)
        case .anthropicMessages: try AnthropicMessagesCodec.parseRequest(body)
        case .gemini: try GeminiCodec.parseRequest(body, model: geminiPath?.model ?? "", stream: geminiPath?.stream ?? false)
        }
    }

    /// Encodes a complete reply for the client.
    static func encodeResponse(_ response: WireResponse, for clientProtocol: WireProtocol, defaults: ReplyDefaults) -> WireEncoded {
        switch clientProtocol {
        case .chatCompletions:
            ChatCompletionsCodec.encodeResponse(response, defaults: ChatResponseDefaults(
                id: defaults.id, model: defaults.model, created: defaults.created,
            ))
        case .responses:
            ResponsesCodec.encodeResponse(response, defaults: ResponsesResponseDefaults(
                id: defaults.id, model: defaults.model, created: defaults.created, trustedReasoningOrigins: defaults.trusted,
            ))
        case .anthropicMessages:
            AnthropicMessagesCodec.encodeResponse(response, defaults: AnthropicResponseDefaults(
                id: defaults.id, model: defaults.model, trustedReasoningOrigins: defaults.trusted,
            ))
        case .gemini:
            GeminiCodec.encodeResponse(response, defaults: GeminiResponseDefaults(
                id: defaults.id, model: defaults.model, trustedSignatureOrigins: defaults.trusted,
            ))
        }
    }
}

/// The client protocol's stream encoder, chosen at run time.
enum ClientStreamEncoder: Sendable {
    case chat(ChatCompletionsStreamEncoder)
    case responses(ResponsesStreamEncoder)
    case anthropic(AnthropicMessagesStreamEncoder)
    case gemini(GeminiStreamEncoder)

    init(for clientProtocol: WireProtocol, defaults: ReplyDefaults, includeUsage: Bool) {
        switch clientProtocol {
        case .chatCompletions:
            self = .chat(ChatCompletionsStreamEncoder(
                defaults: ChatResponseDefaults(id: defaults.id, model: defaults.model, created: defaults.created),
                includeUsage: includeUsage,
            ))
        case .responses:
            self = .responses(ResponsesStreamEncoder(defaults: ResponsesResponseDefaults(
                id: defaults.id, model: defaults.model, created: defaults.created, trustedReasoningOrigins: defaults.trusted,
            )))
        case .anthropicMessages:
            self = .anthropic(AnthropicMessagesStreamEncoder(defaults: AnthropicResponseDefaults(
                id: defaults.id, model: defaults.model, trustedReasoningOrigins: defaults.trusted,
            )))
        case .gemini:
            self = .gemini(GeminiStreamEncoder(defaults: GeminiResponseDefaults(
                id: defaults.id, model: defaults.model, trustedSignatureOrigins: defaults.trusted,
            )))
        }
    }

    mutating func encode(_ event: WireEvent) -> [SSEElement] {
        switch self {
        case .chat(var encoder): defer { self = .chat(encoder) }; return encoder.encode(event)
        case .responses(var encoder): defer { self = .responses(encoder) }; return encoder.encode(event)
        case .anthropic(var encoder): defer { self = .anthropic(encoder) }; return encoder.encode(event)
        case .gemini(var encoder): defer { self = .gemini(encoder) }; return encoder.encode(event)
        }
    }

    mutating func finish() -> [SSEElement] {
        switch self {
        case .chat(var encoder): defer { self = .chat(encoder) }; return encoder.finish()
        case .responses(var encoder): defer { self = .responses(encoder) }; return encoder.finish()
        case .anthropic(var encoder): defer { self = .anthropic(encoder) }; return encoder.finish()
        case .gemini(var encoder): defer { self = .gemini(encoder) }; return encoder.finish()
        }
    }

    /// What keeps the client's connection alive during upstream silence:
    /// - Chat: an SSE comment (OpenAI-compatible servers do the same).
    /// - Anthropic: an `event: ping` once `message_start` is out (a
    ///   comment before).
    /// - Responses: a `response.in_progress` event, since Codex's idle
    ///   timer counts events and ignores comments.
    /// - Gemini: nothing; Google's SDKs stall on comment frames.
    mutating func keepalive() -> [SSEElement] {
        switch self {
        case .chat(var encoder): defer { self = .chat(encoder) }; return encoder.encode(.ping)
        case .responses(var encoder): defer { self = .responses(encoder) }; return encoder.keepalive()
        case .anthropic(var encoder): defer { self = .anthropic(encoder) }; return encoder.encode(.ping)
        case .gemini: return []
        }
    }

    var warnings: [WireWarning] {
        switch self {
        case .chat(let encoder): encoder.warnings
        case .responses(let encoder): encoder.warnings
        case .anthropic(let encoder): encoder.warnings
        case .gemini(let encoder): encoder.warnings
        }
    }
}

extension WireProtocol {
    /// Whether the protocol's clients tolerate SSE comment frames (the
    /// leading warnings comment). Gemini SDKs do not.
    var toleratesComments: Bool { self != .gemini }

    var displayName: String {
        switch self {
        case .chatCompletions: "chat"
        case .responses: "responses"
        case .anthropicMessages: "anthropic"
        case .gemini: "gemini"
        }
    }
}

/// Error bodies in each client protocol's shape.
enum ErrorShape {
    /// `{"error":{"message","type","param","code"}}` (OpenAI),
    /// `{"type":"error","error":{"type","message"}}` (Anthropic),
    /// `{"error":{"code","message","status"}}` (Gemini).
    static func body(for clientProtocol: WireProtocol, status: Int, message: String) -> [UInt8] {
        let json: JSONValue
        switch clientProtocol {
        case .chatCompletions, .responses:
            json = ["error": [
                "message": .string(message),
                "type": .string(openAIType(status)),
                "param": .null,
                "code": openAICode(status).map(JSONValue.string) ?? .null,
            ]]
        case .anthropicMessages:
            json = ["type": "error", "error": ["type": .string(anthropicType(status)), "message": .string(message)]]
        case .gemini:
            json = ["error": ["code": .number(JSONNumber(status)), "message": .string(message), "status": .string(geminiStatus(status))]]
        }
        return json.encoded()
    }

    static func openAIType(_ status: Int) -> String {
        switch status {
        case 401: "authentication_error"
        case 403: "permission_error"
        case 404: "not_found_error"
        case 429: "rate_limit_error"
        case 400..<500: "invalid_request_error"
        default: "server_error"
        }
    }

    static func openAICode(_ status: Int) -> String? {
        switch status {
        case 401: "invalid_api_key"
        case 404: "model_not_found"
        case 429: "rate_limit_exceeded"
        case 501: "not_implemented"
        default: nil
        }
    }

    static func anthropicType(_ status: Int) -> String {
        switch status {
        case 401: "authentication_error"
        case 402: "billing_error"
        case 403: "permission_error"
        case 404: "not_found_error"
        case 413: "request_too_large"
        case 429: "rate_limit_error"
        case 504: "timeout_error"
        case 503, 529: "overloaded_error"
        case 400..<500: "invalid_request_error"
        default: "api_error"
        }
    }

    static func geminiStatus(_ status: Int) -> String {
        switch status {
        case 400, 413, 422: "INVALID_ARGUMENT"
        case 401: "UNAUTHENTICATED"
        case 403: "PERMISSION_DENIED"
        case 404: "NOT_FOUND"
        case 409: "ABORTED"
        case 429: "RESOURCE_EXHAUSTED"
        case 499: "CANCELLED"
        case 501: "UNIMPLEMENTED"
        case 503, 529: "UNAVAILABLE"
        case 504: "DEADLINE_EXCEEDED"
        case 400..<500: "FAILED_PRECONDITION"
        default: "INTERNAL"
        }
    }

    /// The human-readable message of an upstream error body in any of the
    /// four shapes (`error.message`, `message`, `detail`, or Gemini's array
    /// form), else its text.
    static func upstreamMessage(_ body: [UInt8]) -> String {
        if let json = try? JSONValue(parsing: body) {
            var root = json
            if case .array(let items) = json, let first = items.first { root = first }
            if let message = root["error"]?["message"]?.stringValue, !message.isEmpty { return message }
            if let message = root["error"]?.stringValue, !message.isEmpty { return message }
            if let message = root["message"]?.stringValue, !message.isEmpty { return message }
            if let message = root["detail"]?.stringValue, !message.isEmpty { return message }
        }
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        return text.isEmpty ? "upstream error" : text
    }
}
