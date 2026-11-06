/// One of the four protocols' stream decoders, chosen at run time.
@_spi(Wire) public enum AnyWireStreamDecoder: WireStreamDecoder {
    case chat(ChatCompletionsStreamDecoder)
    case responses(ResponsesStreamDecoder)
    case anthropic(AnthropicMessagesStreamDecoder)
    case gemini(GeminiStreamDecoder)

    /// The decoder for `protocol`, stamping `origin` on fidelity data.
    public init(for protocol: WireProtocol, origin: WireSystemID?) {
        switch `protocol` {
        case .chatCompletions: self = .chat(ChatCompletionsStreamDecoder(origin: origin))
        case .responses: self = .responses(ResponsesStreamDecoder(origin: origin))
        case .anthropicMessages: self = .anthropic(AnthropicMessagesStreamDecoder(origin: origin))
        case .gemini: self = .gemini(GeminiStreamDecoder(origin: origin))
        }
    }

    public mutating func decode(_ element: SSEElement) throws(WireDecodingError) -> [WireEvent] {
        switch self {
        case .chat(var decoder): defer { self = .chat(decoder) }; return try decoder.decode(element)
        case .responses(var decoder): defer { self = .responses(decoder) }; return try decoder.decode(element)
        case .anthropic(var decoder): defer { self = .anthropic(decoder) }; return try decoder.decode(element)
        case .gemini(var decoder): defer { self = .gemini(decoder) }; return try decoder.decode(element)
        }
    }

    public mutating func finish() -> [WireEvent] {
        switch self {
        case .chat(var decoder): defer { self = .chat(decoder) }; return decoder.finish()
        case .responses(var decoder): defer { self = .responses(decoder) }; return decoder.finish()
        case .anthropic(var decoder): defer { self = .anthropic(decoder) }; return decoder.finish()
        case .gemini(var decoder): defer { self = .gemini(decoder) }; return decoder.finish()
        }
    }

    public var warnings: [WireWarning] {
        switch self {
        case .chat(let decoder): decoder.warnings
        case .responses(let decoder): decoder.warnings
        case .anthropic(let decoder): decoder.warnings
        case .gemini(let decoder): decoder.warnings
        }
    }
}

/// The wire events of an upstream reply: decoded from its SSE body as they
/// arrive, or replayed from a complete reply when the model does not stream.
///
/// Single pass, like the body under it. Cancelling the iterating task
/// cancels the upstream request (through the transport) and makes `next()`
/// throw `CancellationError`. Decoder warnings are on the iterator
/// (``Iterator/warnings``), complete once it returned `nil`.
@_spi(Wire) public struct UpstreamEventStream: AsyncSequence, Sendable {
    public typealias Element = WireEvent

    enum Source: Sendable {
        case sse(HTTPResponseBody, AnyWireStreamDecoder)
        case replay([WireEvent])
    }

    let source: Source
    let mapper: CustomToolReplyMapper

    init(body: HTTPResponseBody, decoder: AnyWireStreamDecoder, mapper: CustomToolReplyMapper) {
        self.source = .sse(body, decoder)
        self.mapper = mapper
    }

    /// Replays `events` (already mapped).
    public init(replaying events: [WireEvent]) {
        self.source = .replay(events)
        self.mapper = CustomToolReplyMapper(names: [])
    }

    public func makeAsyncIterator() -> Iterator {
        switch source {
        case .sse(let body, let decoder):
            Iterator(elements: body.sseElements().makeAsyncIterator(), decoder: decoder, pending: [], mapper: mapper)
        case .replay(let events):
            Iterator(elements: nil, decoder: nil, pending: events, mapper: mapper)
        }
    }

    public struct Iterator: AsyncIteratorProtocol {
        var elements: SSEElementSequence<HTTPResponseBody>.AsyncIterator?
        var decoder: AnyWireStreamDecoder?
        var pending: [WireEvent]
        var index = 0
        var mapper: CustomToolReplyMapper
        /// Warnings of the stream decoder so far.
        public private(set) var warnings: [WireWarning] = []

        init(
            elements: SSEElementSequence<HTTPResponseBody>.AsyncIterator?,
            decoder: AnyWireStreamDecoder?,
            pending: [WireEvent],
            mapper: CustomToolReplyMapper,
        ) {
            self.elements = elements
            self.decoder = decoder
            self.pending = pending
            self.mapper = mapper
        }

        public mutating func next() async throws -> WireEvent? {
            while true {
                if index < pending.count {
                    defer { index += 1 }
                    return pending[index]
                }
                guard var source = elements, var decoder else { return nil }
                pending = []
                index = 0
                let element: SSEElement?
                do {
                    element = try await source.next()
                } catch {
                    elements = nil
                    throw error
                }
                // A cancelled body may just end; that is not a short reply.
                if Task.isCancelled {
                    elements = nil
                    throw CancellationError()
                }
                let events: [WireEvent]
                if let element {
                    do {
                        events = try decoder.decode(element)
                    } catch {
                        elements = nil
                        warnings = decoder.warnings
                        throw error
                    }
                    elements = source
                    self.decoder = decoder
                } else {
                    events = decoder.finish()
                    elements = nil
                    self.decoder = nil
                }
                warnings = decoder.warnings
                for event in events { pending += mapper.map(event) }
            }
        }
    }
}
