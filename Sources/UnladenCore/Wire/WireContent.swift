/// The role of a message.
///
/// An open set: roles the model does not know (Chat's legacy `function`)
/// are kept as their raw string.
@_spi(Wire) public struct WireRole: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Chat/Responses `system` message (Anthropic and Gemini carry system
    /// text in ``WireRequest/instructions`` instead).
    public static let system: WireRole = "system"
    /// Chat/Responses `developer` message.
    public static let developer: WireRole = "developer"
    public static let user: WireRole = "user"
    /// The model's turn (Gemini's `model`).
    public static let assistant: WireRole = "assistant"
    /// A Chat `tool` message. Protocols that put tool results in user turns
    /// (Anthropic, Gemini) use ``user`` with ``WirePart/toolResult(_:)`` parts.
    public static let tool: WireRole = "tool"
}

/// How a message's content was written, so the same protocol writes it back
/// the same way. `nil` everywhere means "encoder's choice".
@_spi(Wire) public enum WireContentForm: Hashable, Sendable {
    /// A bare string (`"content": "hi"`).
    case string
    /// An array of typed parts.
    case parts
    /// Explicit `null` (Chat assistant turns with only tool calls).
    case null
    /// The key was absent.
    case absent
}

/// One turn of a conversation.
@_spi(Wire) public struct WireMessage: Hashable, Sendable {
    public var role: WireRole
    /// Content in order. For an assistant turn this may mix reasoning, text,
    /// refusals and tool calls; protocols that store them in separate fields
    /// (Chat's `reasoning_content`, `tool_calls`) split them on encode.
    public var parts: [WirePart]
    public var contentForm: WireContentForm?
    /// Unknown keys of the message object, in decode order.
    public var extra: JSONObject

    public init(role: WireRole, parts: [WirePart], contentForm: WireContentForm? = nil, extra: JSONObject = [:]) {
        self.role = role
        self.parts = parts
        self.contentForm = contentForm
        self.extra = extra
    }
}

/// One block of message content.
@_spi(Wire) public enum WirePart: Hashable, Sendable {
    case text(WireText)
    case image(WireMedia)
    /// A document, audio or other non-image file.
    case file(WireMedia)
    case reasoning(WireReasoning)
    case toolCall(WireToolCall)
    case toolResult(WireToolResult)
    /// The model declined to answer (Chat `refusal`, Responses `refusal`).
    case refusal(WireRefusal)
    /// Content the model does not understand, kept as raw JSON.
    case opaque(WireOpaque)
}

@_spi(Wire) public struct WireText: Hashable, Sendable {
    public var text: String
    /// Gemini attaches `thoughtSignature` to text parts too.
    public var signature: String?
    /// The system that produced ``signature``.
    public var origin: WireSystemID?
    /// Unknown keys of the part object (e.g. `cache_control`).
    public var extra: JSONObject

    public init(_ text: String, signature: String? = nil, origin: WireSystemID? = nil, extra: JSONObject = [:]) {
        self.text = text
        self.signature = signature
        self.origin = origin
        self.extra = extra
    }
}

@_spi(Wire) public struct WireRefusal: Hashable, Sendable {
    public var text: String
    public var extra: JSONObject

    public init(_ text: String, extra: JSONObject = [:]) {
        self.text = text
        self.extra = extra
    }
}

/// Where image or file bytes come from.
@_spi(Wire) public enum WireMediaSource: Hashable, Sendable {
    /// A URL the provider fetches (http(s), `gs://`, or a non-base64 data URL).
    case url(String)
    /// Inline base64 data (without any `data:` prefix).
    case base64(String)
    /// A provider-side file id (OpenAI `file_id`, Anthropic `file_id`).
    case fileID(String)
}

@_spi(Wire) public struct WireMedia: Hashable, Sendable {
    public var source: WireMediaSource
    /// MIME type, when known (`image/png`, `application/pdf`).
    public var mediaType: String?
    /// Image detail hint (`low`, `high`, `auto`).
    public var detail: String?
    public var filename: String?
    /// Unknown keys of the part object.
    public var extra: JSONObject

    public init(
        source: WireMediaSource,
        mediaType: String? = nil,
        detail: String? = nil,
        filename: String? = nil,
        extra: JSONObject = [:],
    ) {
        self.source = source
        self.mediaType = mediaType
        self.detail = detail
        self.filename = filename
        self.extra = extra
    }
}

/// Model reasoning ("thinking"), with the opaque data needed to replay it.
///
/// Fidelity fields are stored verbatim. Whether they may be sent to a given
/// upstream is decided later by that endpoint's trust set, keyed on
/// ``origin``.
@_spi(Wire) public struct WireReasoning: Hashable, Sendable {
    /// Visible reasoning text or summary; may be empty (redacted reasoning).
    public var text: String
    /// Anthropic `signature`, Gemini `thoughtSignature`.
    public var signature: String?
    /// Opaque reasoning payload: Anthropic `redacted_thinking.data`,
    /// Responses `encrypted_content`.
    public var encrypted: String?
    /// Provider item id (Responses `rs_…`).
    public var itemID: String?
    /// The system that produced ``signature``, ``encrypted`` and ``itemID``.
    public var origin: WireSystemID?
    /// The field the source protocol used, when it has several spellings
    /// (Chat: `reasoning_content` vs `reasoning`).
    public var sourceKey: String?
    /// Unknown keys of the reasoning object, when it was an object.
    public var extra: JSONObject

    public init(
        text: String,
        signature: String? = nil,
        encrypted: String? = nil,
        itemID: String? = nil,
        origin: WireSystemID? = nil,
        sourceKey: String? = nil,
        extra: JSONObject = [:],
    ) {
        self.text = text
        self.signature = signature
        self.encrypted = encrypted
        self.itemID = itemID
        self.origin = origin
        self.sourceKey = sourceKey
        self.extra = extra
    }

    /// `true` if this carries data only its origin can verify.
    public var hasFidelityData: Bool { signature != nil || encrypted != nil || itemID != nil }
}

/// A tool call made by the model.
@_spi(Wire) public struct WireToolCall: Hashable, Sendable {
    /// The call id the result refers back to. Gemini calls may have none.
    public var id: String?
    public var name: String
    /// The argument JSON exactly as the model produced it (usually an
    /// object; may be malformed text from a misbehaving model).
    public var arguments: String
    /// Responses `function_call` item id (`fc_…`), distinct from the call id.
    public var itemID: String?
    /// Gemini `thoughtSignature` on a function call.
    public var signature: String?
    /// The system that produced ``itemID`` and ``signature``.
    public var origin: WireSystemID?
    /// Unknown keys of the call object.
    public var extra: JSONObject

    public init(
        id: String?,
        name: String,
        arguments: String,
        itemID: String? = nil,
        signature: String? = nil,
        origin: WireSystemID? = nil,
        extra: JSONObject = [:],
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.itemID = itemID
        self.signature = signature
        self.origin = origin
        self.extra = extra
    }
}

/// The output of a tool call, sent back to the model.
@_spi(Wire) public struct WireToolResult: Hashable, Sendable {
    public var callID: String
    /// The tool's name (Gemini `functionResponse.name` needs it).
    public var name: String?
    /// Text, image, file or opaque parts.
    public var content: [WirePart]
    public var contentForm: WireContentForm?
    /// Anthropic `is_error`.
    public var isError: Bool?
    /// Unknown keys of the result object (for Chat, keys of the `tool`
    /// message go to ``WireMessage/extra``).
    public var extra: JSONObject

    public init(
        callID: String,
        name: String? = nil,
        content: [WirePart],
        contentForm: WireContentForm? = nil,
        isError: Bool? = nil,
        extra: JSONObject = [:],
    ) {
        self.callID = callID
        self.name = name
        self.content = content
        self.contentForm = contentForm
        self.isError = isError
        self.extra = extra
    }
}

/// Raw JSON the wire model does not understand: a content part, tool, or
/// tool choice of an unknown type. Only an encoder for ``protocol`` writes
/// it back; others drop it with a warning.
@_spi(Wire) public struct WireOpaque: Hashable, Sendable {
    public var `protocol`: WireProtocol
    public var value: JSONValue
    /// Where in the source protocol's structure it lived when that is not
    /// implied by its position, e.g. Chat `tool_calls` for a non-function
    /// call inside an assistant message. `nil` for ordinary content.
    public var slot: String?

    public init(protocol: WireProtocol, value: JSONValue, slot: String? = nil) {
        self.protocol = `protocol`
        self.value = value
        self.slot = slot
    }
}
