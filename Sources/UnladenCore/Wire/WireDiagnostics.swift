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
