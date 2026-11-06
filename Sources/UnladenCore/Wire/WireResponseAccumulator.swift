/// Folds a stream of wire events into the reply they describe, for a
/// client that asked for a non-streaming reply when the upstream streamed.
///
/// Protocol-agnostic: it reads only the wire model.
/// - ``WireEvent/responseMetadata(_:)`` sets the source, id, model, creation
///   time and bag (``WireResponse/extra``); its early usage stands until the
///   finish brings the final one.
/// - Each block becomes one part, in the order blocks *start* (interleaved
///   tool calls keep their start order). Deltas append; `*End` metadata
///   replaces the start's non-nil fields and merges its bag keys;
///   ``WireEvent/toolCall(id:call:)`` replaces the streamed call with the
///   complete one (or appends a call delivered whole).
/// - ``WireEvent/opaque(_:)`` appends an opaque part.
/// - ``WireEvent/finish(_:)`` sets the finish reason and usage; its bag goes
///   to ``WireResponse/choiceExtra``, where non-streaming decoders keep the
///   same keys (Chat: the choice's; Anthropic: `stop_sequence`,
///   `stop_details`).
/// - In-stream errors are collected in ``errors``; pings are ignored.
///
/// Differences from decoding the equivalent non-streaming body:
/// - ``WireMessage/contentForm`` and ``WireMessage/extra`` stay empty
///   (streams do not say how content was written, and carry no message-level
///   keys such as Chat's `refusal: null`);
/// - tool-call arguments are the concatenated deltas, which may differ in
///   whitespace from a non-streaming reply's re-encoded `input`;
/// - keys a stream decoder does not carry are missing (Chat: `null` choice
///   keys and `logprobs`; Anthropic: content that arrived in `message_start`).
@_spi(Wire) public struct WireResponseAccumulator: Sendable {
    /// The reply so far; complete once ``isFinished``.
    public private(set) var response: WireResponse
    /// Errors reported inside the stream, in order.
    public private(set) var errors: [WireStreamError] = []
    /// Events that did not fit the block structure (ignored).
    public private(set) var warnings: [WireWarning] = []
    /// `true` after the ``WireEvent/finish(_:)`` event.
    public private(set) var isFinished = false

    private var partByBlock: [String: Int] = [:]

    public init() {
        response = WireResponse(message: WireMessage(role: .assistant, parts: []))
    }

    /// Accumulates all of `events`.
    public init(_ events: some Sequence<WireEvent>) {
        self.init()
        for event in events { add(event) }
    }

    public mutating func add(_ event: WireEvent) {
        guard !isFinished else {
            warnings.append(WireWarning(.malformedStream, "event after finish ignored"))
            return
        }
        switch event {
        case .responseMetadata(let metadata):
            response.source = metadata.source
            if let value = metadata.id { response.id = value }
            if let value = metadata.model { response.model = value }
            if let value = metadata.created { response.created = value }
            if let usage = metadata.usage { response.usage = usage }
            for (key, value) in metadata.extra { response.extra[key] = value }

        case .textStart(let block, let text):
            start(block, .text(text))
        case .textDelta(let block, let delta):
            update(block) { part in
                guard case .text(var text) = part else { return false }
                text.text += delta
                part = .text(text)
                return true
            }
        case .textEnd(let block, let late):
            update(block) { part in
                guard case .text(var text) = part else { return false }
                if let late {
                    if let value = late.signature { text.signature = value }
                    if let value = late.itemID { text.itemID = value }
                    if let value = late.origin { text.origin = value }
                    for (key, value) in late.extra { text.extra[key] = value }
                }
                part = .text(text)
                return true
            }

        case .reasoningStart(let block, let reasoning):
            start(block, .reasoning(reasoning))
        case .reasoningDelta(let block, let delta):
            update(block) { part in
                guard case .reasoning(var reasoning) = part else { return false }
                reasoning.text += delta
                part = .reasoning(reasoning)
                return true
            }
        case .reasoningSignatureDelta(let block, let delta):
            update(block) { part in
                guard case .reasoning(var reasoning) = part else { return false }
                reasoning.signature = (reasoning.signature ?? "") + delta
                part = .reasoning(reasoning)
                return true
            }
        case .reasoningEnd(let block, let late):
            update(block) { part in
                guard case .reasoning(var reasoning) = part else { return false }
                if let late {
                    if let value = late.signature { reasoning.signature = value }
                    if let value = late.encrypted { reasoning.encrypted = value }
                    if let value = late.itemID { reasoning.itemID = value }
                    if let value = late.summaryIndex { reasoning.summaryIndex = value }
                    if let value = late.origin { reasoning.origin = value }
                    if let value = late.sourceKey { reasoning.sourceKey = value }
                    for (key, value) in late.extra { reasoning.extra[key] = value }
                }
                part = .reasoning(reasoning)
                return true
            }

        case .refusalStart(let block, let refusal):
            start(block, .refusal(refusal))
        case .refusalDelta(let block, let delta):
            update(block) { part in
                guard case .refusal(var refusal) = part else { return false }
                refusal.text += delta
                part = .refusal(refusal)
                return true
            }
        case .refusalEnd(let block, let late):
            update(block) { part in
                guard case .refusal(var refusal) = part else { return false }
                if let late {
                    if let value = late.itemID { refusal.itemID = value }
                    if let value = late.origin { refusal.origin = value }
                    if let value = late.sourceKey { refusal.sourceKey = value }
                    for (key, value) in late.extra { refusal.extra[key] = value }
                }
                part = .refusal(refusal)
                return true
            }

        case .toolInputStart(let block, let call):
            start(block, .toolCall(call))
        case .toolInputDelta(let block, let delta):
            update(block) { part in
                guard case .toolCall(var call) = part else { return false }
                call.arguments += delta
                part = .toolCall(call)
                return true
            }
        case .toolInputEnd(let block):
            update(block) { part in
                if case .toolCall = part { return true }
                return false
            }
        case .toolCall(let block, let call):
            if let index = partByBlock[block], case .toolCall = response.message.parts[index] {
                response.message.parts[index] = .toolCall(call)
            } else {
                start(block, .toolCall(call))
            }

        case .opaque(let opaque):
            response.message.parts.append(.opaque(opaque))

        case .ping:
            break

        case .error(let error):
            errors.append(error)

        case .finish(let finish):
            if let reason = finish.reason { response.finishReason = reason }
            if let usage = finish.usage { response.usage = usage }
            for (key, value) in finish.extra { response.choiceExtra[key] = value }
            isFinished = true
        }
    }

    private mutating func start(_ block: String, _ part: WirePart) {
        if partByBlock[block] != nil {
            warnings.append(WireWarning(.malformedStream, "block \(block) started twice"))
        }
        partByBlock[block] = response.message.parts.count
        response.message.parts.append(part)
    }

    /// Applies `change` to the block's part; `change` returns `false` if the
    /// event does not match the part's kind.
    private mutating func update(_ block: String, _ change: (inout WirePart) -> Bool) {
        guard let index = partByBlock[block], change(&response.message.parts[index]) else {
            warnings.append(WireWarning(.malformedStream, "event for block \(block) that is not open with that kind"))
            return
        }
    }
}
