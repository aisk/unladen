// Reasoning replay for OpenAI Responses: which reasoning data may be written
// raw, and the envelope that carries other systems' reasoning through a
// Responses client.

/// Decides whether a reasoning part's fidelity data (`encrypted_content`,
/// item ids) may be written raw for a Responses peer.
///
/// This is the single swap point for the phase-4 endpoint trust sets:
/// everything Responses-bound asks ``accepts(_:sameProtocol:trusted:)``.
enum ResponsesReplay {
    /// The system id Responses decoders stamp on fidelity data by default,
    /// and the origin of a client's non-envelope `encrypted_content`.
    static let system: WireSystemID = "openai"

    /// - A part with an ``WireReasoning/origin`` is accepted iff the origin
    ///   is trusted.
    /// - A part without one came from a client request (or a protocol with
    ///   no fidelity data); it is accepted only when that request was
    ///   Responses too.
    static func accepts(_ reasoning: WireReasoning, sameProtocol: Bool, trusted: Set<WireSystemID>) -> Bool {
        guard let origin = reasoning.origin else { return sameProtocol }
        return trusted.contains(origin)
    }

    /// The same decision for an item id on a text, refusal, tool call or
    /// tool result (ids of other systems are dropped silently).
    static func acceptsID(origin: WireSystemID?, sameProtocol: Bool, trusted: Set<WireSystemID>) -> Bool {
        guard let origin else { return sameProtocol }
        return trusted.contains(origin)
    }
}

/// The envelope that carries another system's reasoning data (an Anthropic
/// thinking signature or `redacted_thinking` data, a Gemini
/// `thoughtSignature`) through a Responses client inside a reasoning item's
/// `encrypted_content`, which Responses clients store and send back
/// verbatim (the idea of magpie's claudeseal).
///
/// Format: the prefix ``prefix`` (`unladen-seal1:`, which also versions the
/// format) followed by standard base64 of a compact JSON object:
/// `{"o": origin, "s": signature?, "e": encrypted?}`. The reasoning text is
/// not repeated: it travels as the item's `summary` (or `content`), which
/// clients echo too.
///
/// - The Responses reply encoders seal reasoning whose origin
///   ``ResponsesReplay`` does not accept and that has a signature or
///   encrypted data.
/// - The Responses request parser opens envelopes and restores the original
///   ``WireReasoning/origin``, ``WireReasoning/signature`` and
///   ``WireReasoning/encrypted`` (item id cleared: the gateway made it up).
///   Restoring needs no trust decision of its own: the data is only ever
///   written to an upstream whose trust set accepts its origin, and that
///   upstream verifies it.
/// - The Responses request builder never writes an envelope: restored
///   reasoning has a foreign origin, which an OpenAI upstream does not
///   trust, so it is dropped with a warning.
@_spi(Wire) public enum ResponsesSeal {
    public static let prefix = "unladen-seal1:"

    public struct Contents: Hashable, Sendable {
        public var origin: WireSystemID
        public var signature: String?
        public var encrypted: String?

        public init(origin: WireSystemID, signature: String? = nil, encrypted: String? = nil) {
            self.origin = origin
            self.signature = signature
            self.encrypted = encrypted
        }
    }

    public enum Opened: Hashable, Sendable {
        /// Not an envelope: another system's own `encrypted_content`.
        case notSealed
        /// An envelope that cannot be read (corrupted or forged).
        case unreadable
        case sealed(Contents)
    }

    public static func seal(_ contents: Contents) -> String {
        var object = JSONObject()
        object["o"] = .string(contents.origin)
        if let value = contents.signature { object["s"] = .string(value) }
        if let value = contents.encrypted { object["e"] = .string(value) }
        return prefix + Base64.encode(JSONValue.object(object).encoded())
    }

    public static func open(_ encrypted: String) -> Opened {
        guard encrypted.hasPrefix(prefix) else { return .notSealed }
        guard let bytes = Base64.decode(String(encrypted.dropFirst(prefix.count))),
              case .object(let object)? = try? JSONValue(parsing: bytes),
              case .string(let origin)? = object["o"]
        else { return .unreadable }
        var contents = Contents(origin: origin)
        switch object["s"] {
        case .string(let value)?: contents.signature = value
        case nil: break
        default: return .unreadable
        }
        switch object["e"] {
        case .string(let value)?: contents.encrypted = value
        case nil: break
        default: return .unreadable
        }
        return .sealed(contents)
    }
}
