// Reasoning replay for OpenAI Responses: which reasoning data may be written
// raw, and the envelope that carries other systems' reasoning through a
// Responses client.

/// Decides whether a reasoning part's fidelity data (`encrypted_content`,
/// item ids) may be written raw for a Responses peer.
///
/// This is the one place an endpoint's trust set is applied:
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
/// `{"o": origin, "s": signature?, "e": encrypted?, "t": target?}`. The
/// reasoning text is not repeated: it travels as the item's `summary` (or
/// `content`), which clients echo too.
///
/// **Call signatures.** A Gemini `thoughtSignature` on a function call
/// (which Gemini 3 requires back) has no reasoning to ride on, so the reply
/// encoders write an extra reasoning item with an empty summary right
/// before the `function_call` item, sealing `{"o", "s", "t": "call"}`
/// (``Contents/target`` ``callTarget``). The request parser removes that item
/// and puts the signature and origin back on the call that follows it (its
/// gateway-made item id cleared); an envelope that is not followed by a
/// call is dropped with a warning. Text signatures are not carried (Gemini
/// does not require them back).
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
    /// ``Contents/target`` of a function call's signature.
    public static let callTarget = "call"

    public struct Contents: Hashable, Sendable {
        public var origin: WireSystemID
        public var signature: String?
        public var encrypted: String?
        /// What the data belongs to when not the reasoning item itself:
        /// ``callTarget`` for the function call that follows.
        public var target: String?

        public init(origin: WireSystemID, signature: String? = nil, encrypted: String? = nil, target: String? = nil) {
            self.origin = origin
            self.signature = signature
            self.encrypted = encrypted
            self.target = target
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
        if let value = contents.target { object["t"] = .string(value) }
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
        switch object["t"] {
        case .string(let value)?: contents.target = value
        case nil: break
        default: return .unreadable
        }
        return .sealed(contents)
    }
}

/// Item ids the gateway makes up for a Responses client when the upstream
/// gave none (a reply from another protocol): `<prefix>_unladen_<seed>_<n>`
/// (`msg`, `rs`, `fc`, `ctc`), where the seed is the response id without
/// its `resp_` prefix and `n` the output index.
///
/// They are valid Responses ids, so clients store and echo them, but no
/// upstream knows them: the request parser clears them (as it clears the
/// ids of sealed reasoning), so a later OpenAI upstream is never asked for
/// an item it never made. Real upstream ids never contain the marker
/// (OpenAI's are `<prefix>_<hex>`).
@_spi(Wire) public enum ResponsesItemID {
    public static let mark = "unladen_"

    static func mint(prefix: String, responseID: String, index: Int) -> String {
        let seed = responseID.hasPrefix("resp_") ? String(responseID.dropFirst(5)) : responseID
        return "\(prefix)_\(mark)\(seed)_\(index)"
    }

    /// `true` for an id made by ``mint(prefix:responseID:index:)``.
    public static func isMinted(_ id: String) -> Bool {
        guard let underscore = id.firstIndex(of: "_") else { return false }
        return id[id.index(after: underscore)...].hasPrefix(mark)
    }

    /// `id`, or `nil` if the gateway minted it.
    static func upstream(_ id: String?) -> String? {
        guard let id, !isMinted(id) else { return nil }
        return id
    }
}
