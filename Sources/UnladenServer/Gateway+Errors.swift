// What the client is told when no candidate served it, with secrets
// redacted, and the warnings header.

import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
@_spi(Wire) import UnladenCore

extension Gateway {
    // MARK: Errors

    static let modelHeader = HTTPField.Name("x-unladen-model")!

    /// Upstream headers forwarded with a same-protocol error.
    static let forwardedErrorHeaders: [String] = [
        "retry-after", "request-id", "x-request-id", "x-goog-request-id", "openai-request-id",
    ]

    /// Upstream statuses that mean the gateway's own key was refused.
    static let credentialStatuses: Set<Int> = [401, 402, 403]

    /// The client's response for a request no candidate served.
    ///
    /// An upstream 401/402/403 is about the gateway's key, not the
    /// client's: the client gets a 502 with a gateway message, never the
    /// upstream's body (which can quote part of the key).
    func failureResponse(_ failure: AttemptFailure, clientProtocol: WireProtocol, warnings: [WireWarning]) -> Response {
        switch failure {
        case .upstream(let candidate, let error) where Self.credentialStatuses.contains(error.status.code):
            var response = Self.errorResponse(
                clientProtocol, status: 502,
                message: "upstream rejected the gateway's credentials for \(candidate.reference)", warnings: warnings,
            )
            response.headers[Self.modelHeader] = candidate.reference
            return response
        case .upstream(let candidate, let error):
            var fields = HTTPFields()
            for name in Self.forwardedErrorHeaders {
                if let field = HTTPField.Name(name), let value = error.headerFields[field] { fields[field] = value }
            }
            for field in error.headerFields where field.name.canonicalName.hasPrefix("x-ratelimit-")
                || field.name.canonicalName.hasPrefix("anthropic-ratelimit-")
            {
                fields.append(field)
            }
            fields[Self.modelHeader] = candidate.reference
            if !warnings.isEmpty { fields[WarningHeader.name] = WarningHeader.value(request: warnings) }
            let body: [UInt8]
            if candidate.upstreamProtocol == clientProtocol {
                // Same protocol: the upstream's error, verbatim.
                fields[.contentType] = error.headerFields[.contentType] ?? "application/json"
                body = error.body
            } else {
                fields[.contentType] = "application/json"
                body = ErrorShape.body(for: clientProtocol, status: error.status.code, message: ErrorShape.upstreamMessage(error.body))
            }
            return Response(status: error.status, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: body)))
        case .gateway(let status, let message, _):
            return Self.errorResponse(clientProtocol, status: status, message: message, warnings: warnings)
        case .strict(let lossy):
            return Self.errorResponse(
                clientProtocol, status: 400,
                message: "strict mode: the request cannot be carried exactly: \(WarningHeader.summary(lossy))", warnings: lossy,
            )
        }
    }

    static func errorResponse(_ clientProtocol: WireProtocol, status: Int, message: String, warnings: [WireWarning] = []) -> Response {
        var fields: HTTPFields = [.contentType: "application/json"]
        if !warnings.isEmpty { fields[WarningHeader.name] = WarningHeader.value(request: warnings) }
        return Response(
            status: HTTPResponse.Status(code: status),
            headers: fields,
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: ErrorShape.body(for: clientProtocol, status: status, message: message))),
        )
    }

    // MARK: Redaction

    /// `text` with anything that looks like an API key replaced by
    /// `[redacted]`, for logging upstream error messages: words with a
    /// vendor key prefix (`sk-`, `AIza`, `xai-`…), masked keys (`****`), and
    /// long runs of letters and digits.
    static func redactingSecrets(_ text: String) -> String {
        let separators: Set<Character> = [" ", "\t", "\n", "\r", "\"", "'", "`", ",", ";", "(", ")", "[", "]", "{", "}", "<", ">", "="]
        var out = ""
        var word = ""
        func flush() {
            var core = Substring(word)
            var trailing = ""
            while let last = core.last, [".", ":", "!", "?"].contains(last) {
                trailing = String(last) + trailing
                core = core.dropLast()
            }
            out += (isSecret(core) ? "[redacted]" : String(core)) + trailing
            word = ""
        }
        for character in text {
            if separators.contains(character) {
                flush()
                out.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return out
    }

    static let keyPrefixes = ["sk-", "sk_", "pk-", "rk-", "AIza", "xai-", "gsk_", "key-", "ya29."]

    static func isSecret(_ word: Substring) -> Bool {
        guard word.count >= 8 else { return false }
        if keyPrefixes.contains(where: { word.hasPrefix($0) }) { return true }
        if word.contains("***") || word.contains("…") { return true }
        let keyish = word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return keyish && word.count >= 32 && word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
    }
}

/// The `x-unladen-warnings` header: a count and the warnings, compact,
/// ASCII, truncated. Each is labelled `request:` (decoding the client's
/// request, transforming and encoding it for the upstream) or `response:`
/// (decoding the upstream's reply, encoding it for the client).
enum WarningHeader {
    static let name = HTTPField.Name("x-unladen-warnings")!
    static let limit = 1024

    static func summary(_ warnings: [WireWarning]) -> String {
        warnings.map(\.description).joined(separator: "; ")
    }

    static func value(request: [WireWarning], response: [WireWarning] = []) -> String {
        let labelled = request.map { "request: \($0)" } + response.map { "response: \($0)" }
        var text = "\(labelled.count): " + labelled.joined(separator: "; ")
        text = String(text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F ? Character($0) : "?" })
        if text.utf8.count > limit {
            text = String(text.prefix(limit - 3)) + "..."
        }
        return text
    }
}
