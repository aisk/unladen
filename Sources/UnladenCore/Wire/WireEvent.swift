/// One event of a streaming reply, in vercel-style block structure.
///
/// Content arrives in blocks: `*Start` → `*Delta`* → `*End`, correlated by
/// a block `id` that is unique within the stream. Several blocks may be open
/// at once (Chat interleaves parallel tool calls by index). A stream ends
/// with exactly one ``finish(_:)``, possibly preceded by ``error(_:)``.
///
/// Block ids are assigned by decoders and carry no meaning on the wire;
/// encoders assign the target protocol's indices themselves.
@_spi(Wire) public enum WireEvent: Hashable, Sendable {
    /// Reply id/model/creation time, sent once as soon as known.
    case responseMetadata(WireResponseMetadata)

    /// `text` carries metadata known at start (Responses item id, origin,
    /// bag); its `text` is empty and content follows as deltas.
    case textStart(id: String, text: WireText)
    case textDelta(id: String, delta: String)
    /// `text`, when non-nil, carries metadata learned at the end (Gemini's
    /// `thoughtSignature`, which arrives with the last chunk); its non-nil
    /// fields replace the start's. Its `text` is ignored.
    case textEnd(id: String, text: WireText?)

    /// `reasoning` carries fidelity metadata known at start (item id,
    /// summary index, origin, Anthropic redacted data, source spelling); its
    /// `text` is empty. A new Responses summary part is a new block with the
    /// same item id and the next ``WireReasoning/summaryIndex``.
    case reasoningStart(id: String, reasoning: WireReasoning)
    case reasoningDelta(id: String, delta: String)
    /// A piece of the block's signature (appended to the previous pieces).
    case reasoningSignatureDelta(id: String, delta: String)
    /// `reasoning`, when non-nil, carries metadata learned at the end
    /// (Responses `encrypted_content`); its non-nil fields replace the start's.
    case reasoningEnd(id: String, reasoning: WireReasoning?)

    /// As ``textStart(id:text:)``: metadata only, the text follows as deltas.
    case refusalStart(id: String, refusal: WireRefusal)
    case refusalDelta(id: String, delta: String)
    /// As ``textEnd(id:text:)``: late metadata, if any.
    case refusalEnd(id: String, refusal: WireRefusal?)

    /// `call.arguments` is empty here; arguments follow as deltas.
    case toolInputStart(id: String, call: WireToolCall)
    case toolInputDelta(id: String, delta: String)
    case toolInputEnd(id: String)
    /// The complete call, after its input block ended (or alone, for
    /// protocols that deliver calls whole).
    case toolCall(id: String, call: WireToolCall)

    /// Content of a kind the model does not know, delivered whole.
    case opaque(WireOpaque)

    /// Keepalive (SSE comment, Anthropic `ping`).
    case ping
    /// An error reported inside the stream.
    case error(WireStreamError)
    /// End of the reply.
    case finish(WireFinish)
}

@_spi(Wire) public struct WireResponseMetadata: Hashable, Sendable {
    /// The protocol of the decoder that produced this; stream encoders write
    /// bags (here and in usage) only when it equals their own.
    public var source: WireProtocol?
    public var id: String?
    public var model: String?
    public var created: Int?
    /// Usage known at the start (Anthropic `message_start` input tokens).
    /// The usage in ``WireFinish`` is the final word.
    public var usage: WireUsage?
    /// Unknown top-level keys of the first chunk (`system_fingerprint`…).
    public var extra: JSONObject

    public init(
        id: String? = nil,
        model: String? = nil,
        created: Int? = nil,
        usage: WireUsage? = nil,
        extra: JSONObject = [:],
        source: WireProtocol? = nil,
    ) {
        self.source = source
        self.id = id
        self.model = model
        self.created = created
        self.usage = usage
        self.extra = extra
    }
}

@_spi(Wire) public struct WireFinish: Hashable, Sendable {
    public var reason: WireFinishReason?
    public var usage: WireUsage?
    /// Unknown keys that came with the finish (Chat: keys of the choice in
    /// the `finish_reason` chunk, e.g. OpenRouter `native_finish_reason`;
    /// Anthropic: `message_delta.delta` keys). Same protocol only.
    public var extra: JSONObject

    public init(reason: WireFinishReason? = nil, usage: WireUsage? = nil, extra: JSONObject = [:]) {
        self.reason = reason
        self.usage = usage
        self.extra = extra
    }
}

@_spi(Wire) public struct WireStreamError: Hashable, Sendable {
    public var message: String
    public var type: String?
    public var code: String?
    /// The error object as the upstream sent it, when it was JSON.
    public var raw: JSONValue?

    public init(message: String, type: String? = nil, code: String? = nil, raw: JSONValue? = nil) {
        self.message = message
        self.type = type
        self.code = code
        self.raw = raw
    }
}

/// A stateful, synchronous transducer from upstream SSE to wire events.
@_spi(Wire) public protocol WireStreamDecoder: Sendable {
    /// Decodes one SSE element. Comments become ``WireEvent/ping``.
    mutating func decode(_ element: SSEElement) throws(WireDecodingError) -> [WireEvent]
    /// Call at end of input: closes open blocks and emits ``WireEvent/finish(_:)``
    /// if the stream did not already. Idempotent.
    mutating func finish() -> [WireEvent]
    /// Warnings so far.
    var warnings: [WireWarning] { get }
}

/// Decodes an async sequence of SSE elements into wire events.
@_spi(Wire) public struct WireEventSequence<Base: AsyncSequence, Decoder: WireStreamDecoder>: AsyncSequence
    where Base.Element == SSEElement
{
    public typealias Element = WireEvent

    let base: Base
    let decoder: Decoder

    public init(_ base: Base, decoder: Decoder) {
        self.base = base
        self.decoder = decoder
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), decoder: decoder)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var decoder: Decoder
        var pending: [WireEvent] = []
        var pendingIndex = 0
        var finished = false

        public mutating func next() async throws -> WireEvent? {
            while true {
                if pendingIndex < pending.count {
                    defer { pendingIndex += 1 }
                    return pending[pendingIndex]
                }
                guard !finished else { return nil }
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
                // A throw (from the base or the decoder) ends the sequence.
                let element: SSEElement?
                do {
                    element = try await base.next(isolation: #isolation)
                    if let element { pending = try decoder.decode(element) }
                } catch {
                    finished = true
                    throw error
                }
                if element == nil {
                    finished = true
                    pending = decoder.finish()
                }
            }
        }
    }
}

extension WireEventSequence: Sendable where Base: Sendable {}

extension AsyncSequence where Element == SSEElement {
    /// Decodes this SSE stream with `decoder`.
    @_spi(Wire) public func wireEvents<D: WireStreamDecoder>(_ decoder: D) -> WireEventSequence<Self, D> {
        WireEventSequence(self, decoder: decoder)
    }
}
