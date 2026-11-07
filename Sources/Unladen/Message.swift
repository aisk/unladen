@_spi(Wire) import UnladenCore

/// Who wrote a message.
public enum Role: String, Hashable, Sendable, CaseIterable, Codable {
    /// Instructions for the model. Text only.
    case system
    /// The user: text, images and files.
    case user
    /// The model: text, reasoning, refusals and tool calls. A
    /// ``ModelResponse/message`` is one, ready to append to the history.
    case assistant
    /// Results of the model's tool calls. Tool results only.
    case tool
}

/// One turn of a conversation.
///
/// ```swift
/// var history: [Message] = [
///     .system("Answer in one sentence."),
///     .user("What is the capital of France?"),
/// ]
/// let response = try await model.generate(history)
/// history.append(response.message)
/// ```
public struct Message: Hashable, Sendable, Codable {
    public var role: Role
    /// In order. Which kinds of part a role may hold is listed on ``Role``;
    /// anything else is rejected with ``UnladenError/invalidRequest(_:)``.
    public var content: [ContentPart]
    /// A prompt-cache breakpoint at the end of the message: it goes on the
    /// last part that can carry one in the target protocol (a part's own
    /// breakpoint wins). See ``CacheBreakpoint``.
    public var cache: CacheBreakpoint?
    /// Raw JSON merged into every object the target protocol writes for
    /// the message (see ``ProviderOptions``): each Chat message it becomes
    /// (each `tool` message of a tool turn), each Anthropic or Gemini turn
    /// it goes into (Gemini's `systemInstruction` for a leading system
    /// message; a turn that joins several messages takes all their options,
    /// later over earlier), each Responses input item it splits into. A
    /// leading system message sent as Anthropic's `system`
    /// has no object of its own: set options on its parts instead; the
    /// options are dropped with a ``CallWarning/Code/droppedField`` warning.
    public var providerOptions: ProviderOptions

    public init(role: Role, content: [ContentPart], cache: CacheBreakpoint? = nil, providerOptions: ProviderOptions = [:]) {
        self.role = role
        self.content = content
        self.cache = cache
        self.providerOptions = providerOptions
    }

    public static func system(_ text: String) -> Message {
        Message(role: .system, content: [.text(text)])
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text(text)])
    }

    public static func user(_ content: [ContentPart]) -> Message {
        Message(role: .user, content: content)
    }

    public static func assistant(_ text: String) -> Message {
        Message(role: .assistant, content: [.text(text)])
    }

    public static func assistant(_ content: [ContentPart]) -> Message {
        Message(role: .assistant, content: content)
    }

    /// A tool message answering one or more tool calls.
    public static func tool(_ results: ToolResult...) -> Message {
        Message(role: .tool, content: results.map(ContentPart.toolResult))
    }

    public static func tool(_ results: [ToolResult]) -> Message {
        Message(role: .tool, content: results.map(ContentPart.toolResult))
    }

    /// The text parts, joined.
    public var text: String {
        content.compactMap { if case .text(let text, _) = $0.base { text } else { nil } }.joined()
    }

    /// The tool calls, in order.
    public var toolCalls: [ToolCall] {
        content.compactMap { if case .toolCall(let call) = $0.base { call } else { nil } }
    }
}

/// One block of message content.
///
/// Parts that came from a model carry a ``ReplayToken``: the provider's
/// signature, encrypted reasoning or item id, needed to send the message
/// back in a later request. Keep it with the part; it is dropped
/// automatically when the history goes to a provider that cannot verify it.
///
/// **Match on ``base``.** A part sent with options (``cached(ttl:)``,
/// ``withProviderOptions(_:)``) is ``annotated(_:_:)``, so
/// `if case .text = part` does not match it; `if case .text = part.base`
/// matches both. Equality and hashing look through the wrapping: two parts
/// are equal when their ``base`` and their ``options`` are, however the
/// options were stacked.
public enum ContentPart: Hashable, Sendable {
    case text(String, replay: ReplayToken? = nil)
    case image(Media)
    /// A document, audio or other non-image file.
    case file(Media)
    /// The model's reasoning ("thinking") or its summary. The text may be
    /// empty when the provider returns only encrypted reasoning.
    case reasoning(String, replay: ReplayToken? = nil)
    /// The model declined to answer.
    case refusal(String, replay: ReplayToken? = nil)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    /// A part sent with per-part settings: a cache breakpoint or raw
    /// provider options. Built by ``cached(ttl:)``,
    /// ``withProviderOptions(_:)`` and ``with(_:)``; ``base`` and
    /// ``options`` take it apart. Responses never contain it.
    indirect case annotated(ContentPart, PartOptions)
}

extension ContentPart {
    public static func == (lhs: ContentPart, rhs: ContentPart) -> Bool {
        let (left, right) = (lhs.base, rhs.base)
        guard lhs.options == rhs.options else { return false }
        switch (left, right) {
        case (.text(let a, let x), .text(let b, let y)),
             (.reasoning(let a, let x), .reasoning(let b, let y)),
             (.refusal(let a, let x), .refusal(let b, let y)):
            return a == b && x == y
        case (.image(let a), .image(let b)), (.file(let a), .file(let b)):
            return a == b
        case (.toolCall(let a), .toolCall(let b)):
            return a == b
        case (.toolResult(let a), .toolResult(let b)):
            return a == b
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch base {
        case .text(let text, let token): hasher.combine(0); hasher.combine(text); hasher.combine(token)
        case .image(let media): hasher.combine(1); hasher.combine(media)
        case .file(let media): hasher.combine(2); hasher.combine(media)
        case .reasoning(let text, let token): hasher.combine(3); hasher.combine(text); hasher.combine(token)
        case .refusal(let text, let token): hasher.combine(4); hasher.combine(text); hasher.combine(token)
        case .toolCall(let call): hasher.combine(5); hasher.combine(call)
        case .toolResult(let result): hasher.combine(6); hasher.combine(result)
        case .annotated: break // `base` never is
        }
        let options = options
        if !options.isEmpty { hasher.combine(options) }
    }
}

/// An image or file: a URL, inline data, or a provider-side file id.
public struct Media: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// A URL the provider fetches (`https:`, `gs:`, or a `data:` URL).
        case url(String)
        /// Inline data, base64-encoded (no `data:` prefix).
        case base64(String)
        /// A file uploaded to the provider beforehand (OpenAI and
        /// Anthropic `file_id`).
        case fileID(String)
    }

    public var source: Source
    /// MIME type (`image/png`, `application/pdf`). Required by most
    /// providers for inline data.
    public var mediaType: String?
    public var filename: String?
    /// Image detail hint (`low`, `high`, `auto`); OpenAI only.
    public var detail: String?

    public init(_ source: Source, mediaType: String? = nil, filename: String? = nil, detail: String? = nil) {
        self.source = source
        self.mediaType = mediaType
        self.filename = filename
        self.detail = detail
    }

    /// Inline bytes.
    public init(bytes: some Collection<UInt8>, mediaType: String, filename: String? = nil) {
        self.init(.base64(Base64.encode(bytes)), mediaType: mediaType, filename: filename)
    }

    public static func url(_ url: String, mediaType: String? = nil) -> Media {
        Media(.url(url), mediaType: mediaType)
    }
}

/// A tool call made by the model.
public struct ToolCall: Hashable, Sendable, Codable {
    /// The id a ``ToolResult`` answers. Unique within a response.
    public var id: String
    public var name: String
    /// The arguments as the model produced them: normally a JSON object,
    /// but not guaranteed to be valid JSON (see ``parsedArguments()``).
    public var arguments: String
    public var replay: ReplayToken?

    public init(id: String, name: String, arguments: String, replay: ReplayToken? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.replay = replay
    }

    public init(id: String, name: String, arguments: JSONValue) {
        self.init(id: id, name: name, arguments: arguments.description)
    }

    /// ``arguments`` parsed as JSON; an empty string is an empty object.
    public func parsedArguments() throws(JSONParseError) -> JSONValue {
        if arguments.allSatisfy(\.isWhitespace) { return .object([:]) }
        return try JSONValue(parsing: arguments)
    }
}

/// The output of a tool, answering a ``ToolCall``.
public struct ToolResult: Hashable, Sendable, Codable {
    /// The ``ToolCall/id`` this answers.
    public var callID: String
    /// The tool's name (Gemini needs it; ``init(call:output:isError:)`` fills it).
    public var toolName: String?
    /// Text, image or file parts.
    public var output: [ContentPart]
    /// The tool failed and ``output`` describes the error.
    public var isError: Bool

    public init(callID: String, toolName: String?, output: [ContentPart], isError: Bool = false) {
        self.callID = callID
        self.toolName = toolName
        self.output = output
        self.isError = isError
    }

    /// Answers `call` with text.
    public init(call: ToolCall, output: String, isError: Bool = false) {
        self.init(callID: call.id, toolName: call.name, output: [.text(output)], isError: isError)
    }

    /// Answers `call` with a JSON value, sent as its compact encoding.
    public init(call: ToolCall, json: JSONValue, isError: Bool = false) {
        self.init(call: call, output: json.description, isError: isError)
    }

    /// Answers `call` with arbitrary parts.
    public init(call: ToolCall, output: [ContentPart], isError: Bool = false) {
        self.init(callID: call.id, toolName: call.name, output: output, isError: isError)
    }
}

/// Provider data that lets a model's output be sent back verbatim: a
/// thinking signature, encrypted reasoning, a provider item id, and which
/// system produced them.
///
/// Opaque on purpose: it has no public initialiser or setters, so it can
/// only come from a response and survives as long as the part holding it
/// is kept. `Codable`, so a history can be saved and loaded: it encodes as
/// one versioned opaque string, not as readable fields. When the history is sent to a provider that does not accept
/// data from ``system`` (another vendor, after a fallback), the library
/// drops it before encoding: reasoning from that system is left out and
/// other parts lose only the token. That is reported as a
/// ``CallWarning/Code/replayDataDropped`` warning, which is never an error.
public struct ReplayToken: Hashable, Sendable {
    /// The endpoint system (``Endpoint/system``) that produced the content.
    public let system: String
    let signature: String?
    let encrypted: String?
    let itemID: String?
    /// The wire origin the decoder stamped (normally ``system`` when there
    /// is fidelity data, `nil` otherwise).
    let origin: String?
    let summaryIndex: Int?
    let sourceKey: String?
    let idSynthesized: Bool
    let itemType: String?
    /// Chat dialect data the typed fields do not hold (an OpenRouter
    /// `reasoning_details` entry's `type`/`format`/`index`/`id`, the rest of
    /// Gemini's `extra_content`), restored for Chat endpoints.
    let dialect: JSONObject?

    init(
        system: String,
        signature: String? = nil,
        encrypted: String? = nil,
        itemID: String? = nil,
        origin: String? = nil,
        summaryIndex: Int? = nil,
        sourceKey: String? = nil,
        idSynthesized: Bool = false,
        itemType: String? = nil,
        dialect: JSONObject? = nil,
    ) {
        self.dialect = dialect
        self.system = system
        self.signature = signature
        self.encrypted = encrypted
        self.itemID = itemID
        self.origin = origin
        self.summaryIndex = summaryIndex
        self.sourceKey = sourceKey
        self.idSynthesized = idSynthesized
        self.itemType = itemType
    }

    /// `true` if the token holds a signature or encrypted reasoning, which
    /// only ``system`` (and systems that trust it) can verify.
    public var hasSignedData: Bool { signature != nil || encrypted != nil }
}

extension ReplayToken: CustomStringConvertible {
    public var description: String {
        var fields = ["system: \(system)"]
        if signature != nil { fields.append("signature") }
        if encrypted != nil { fields.append("encrypted") }
        if let itemID { fields.append("item: \(itemID)") }
        return "ReplayToken(\(fields.joined(separator: ", ")))"
    }
}
