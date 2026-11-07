/// A non-fatal note from a codec: content that was representable but lossy,
/// unknown, or dropped.
///
/// Codecs append warnings instead of failing. The library escalates them to
/// errors by default; the gateway forwards them to the client.
@_spi(Wire) public struct WireWarning: Hashable, Sendable, CustomStringConvertible {
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }
        public var description: String { rawValue }

        /// A decoder kept a field it does not model in an unknown-field bag.
        /// Same-protocol output keeps it; other protocols will drop it.
        public static let unknownField: Code = "unknown_field"
        /// A decoder kept content it does not model as an opaque part/tool.
        public static let opaqueContent: Code = "opaque_content"
        /// An encoder dropped a field the target protocol cannot carry.
        public static let droppedField: Code = "dropped_field"
        /// An encoder dropped content (a part, a signature, a tool) the target
        /// protocol cannot carry.
        public static let droppedContent: Code = "dropped_content"
        /// Content was carried, but not exactly (e.g. several parts joined).
        public static let lossyConversion: Code = "lossy_conversion"
        /// A value is outside what the codec understands and was ignored.
        public static let unsupportedValue: Code = "unsupported_value"
        /// A stream did not follow the protocol (e.g. ended without `[DONE]`).
        public static let malformedStream: Code = "malformed_stream"
        /// A Profile transform changed the request to fit the upstream
        /// (synthesized a tool result, converted an effort, clamped a limit).
        public static let adjusted: Code = "adjusted"
        /// A Profile transform left out a parameter or setting the model's
        /// Profile declares it does not take (`temperature` on a reasoning
        /// model, `seed` on Claude, reasoning on a model without it). The
        /// request is valid for the model as configured; under a strict
        /// policy this is reported, not an error.
        public static let unsupportedByModel: Code = "unsupported_by_model"
    }

    public var code: Code
    public var message: String
    /// Location in the source or target JSON, e.g. `messages[2].content[0]`.
    /// Empty for the document root or stream-level notes.
    public var path: String

    public init(_ code: Code, _ message: String, path: String = "") {
        self.code = code
        self.message = message
        self.path = path
    }

    public var description: String {
        path.isEmpty ? "\(code): \(message)" : "\(code) at \(path): \(message)"
    }
}

// MARK: - Classification

extension WireWarning {
    /// Last path components of prompt-cache hints (`prompt_cache_key`,
    /// `cache_control`…): dropping one only costs money, never correctness.
    public static let cacheHintFields: Set<String> = ["prompt_cache_key", "prompt_cache_retention", "cache_control", "cachedContent"]

    /// `true` for a prompt-cache hint dropped, or sent although the target
    /// may refuse it (``Code/unsupportedValue``: more breakpoints than the
    /// model takes, as the client spelled them).
    public var isCacheHint: Bool {
        guard code == .droppedField || code == .droppedContent || code == .unsupportedValue else { return false }
        let last = path.split(separator: ".").last.map(String.init) ?? path
        return Self.cacheHintFields.contains(last)
    }

    /// Whether a strict policy turns this request-side warning into an
    /// error: every loss a codec or encoder discovers (a field or content
    /// the target cannot carry, foreign replay data, a lossy conversion).
    ///
    /// Reported only: lossless notes (an unknown field or opaque content
    /// kept: ``Code/unknownField``, ``Code/opaqueContent``), a
    /// meaning-preserving ``Code/adjusted`` rewrite, a parameter the
    /// model's Profile declares it does not take
    /// (``Code/unsupportedByModel``), and dropped cache hints.
    public var isEscalatedWhenStrict: Bool {
        !(code == .unknownField || code == .opaqueContent || code == .adjusted || code == .unsupportedByModel || isCacheHint)
    }

    /// `decoded` (a client request's or upstream reply's decoding notes)
    /// followed by `encoded` (what re-encoding it reported), without
    /// saying the same thing twice: a decoder's "kept" note
    /// (``Code/unknownField``, ``Code/opaqueContent``) is left out when the
    /// encoder reported losing the same field or content (same path, or for
    /// an unknown field the same key), so each field gets one warning, the
    /// one that tells what happened to it.
    public static func merged(decoded: [WireWarning], encoded: [WireWarning]) -> [WireWarning] {
        let lost = encoded.filter { $0.code != .unknownField && $0.code != .opaqueContent && $0.code != .adjusted }
        let lostPaths = Set(lost.map(\.path))
        let lostKeys = Set(lost.filter { $0.code == .droppedField || $0.code == .lossyConversion }.map(\.lastPathKey))
        let kept = decoded.filter { warning in
            switch warning.code {
            case .unknownField: !(lostPaths.contains(warning.path) || lostKeys.contains(warning.lastPathKey))
            case .opaqueContent: !lostPaths.contains(warning.path)
            default: true
            }
        }
        return kept + encoded
    }

    /// The last key of ``path`` (`messages[2].foo` → `foo`).
    var lastPathKey: String {
        let last = path.split(separator: ".").last.map(String.init) ?? path
        return String(last.prefix { $0 != "[" })
    }
}

/// A decoder failure: the input is not something the protocol allows.
///
/// The gateway maps this to HTTP 400. Content that is valid but unknown
/// never produces this error; it goes into bags or opaque parts instead.
@_spi(Wire) public struct WireDecodingError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case invalidJSON(JSONParseError)
        case missingField
        /// A known field has the wrong JSON type; `expected` names the type.
        case typeMismatch(expected: String)
        case invalidValue(String)
    }

    public var kind: Kind
    public var path: String

    public init(_ kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }

    public var description: String {
        switch kind {
        case .invalidJSON(let error): "invalid JSON: \(error)"
        case .missingField: "missing required field `\(path)`"
        case .typeMismatch(let expected): "`\(path)` must be \(expected)"
        case .invalidValue(let message): "invalid value at `\(path)`: \(message)"
        }
    }
}

/// A decoded value plus the warnings produced while decoding it.
@_spi(Wire) public struct WireDecoded<Value: Hashable & Sendable>: Hashable, Sendable {
    public var value: Value
    public var warnings: [WireWarning]

    public init(value: Value, warnings: [WireWarning] = []) {
        self.value = value
        self.warnings = warnings
    }
}

/// An encoded JSON body plus the warnings produced while encoding it.
@_spi(Wire) public struct WireEncoded: Hashable, Sendable {
    /// The JSON document; `body` is its deterministic encoding.
    public var json: JSONValue
    public var warnings: [WireWarning]

    public init(json: JSONValue, warnings: [WireWarning] = []) {
        self.json = json
        self.warnings = warnings
    }

    /// Compact UTF-8 bytes (see ``JSONValue/encoded()``).
    public var body: [UInt8] { json.encoded() }
}
