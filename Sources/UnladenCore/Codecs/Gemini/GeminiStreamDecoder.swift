/// Decodes a Gemini `streamGenerateContent?alt=sse` stream into
/// block-structured wire events.
///
/// Every SSE `data:` frame is a whole `GenerateContentResponse` fragment:
/// - the first frame gives ``WireEvent/responseMetadata(_:)`` (`responseId`,
///   `modelVersion`, and its other unknown top-level keys);
/// - contiguous text parts are one text block, contiguous `thought` parts
///   one reasoning block. A `thoughtSignature` on the part that starts a
///   block is in the start payload; one on a later part of the block (often
///   a final part with empty text) is in the end payload. A block gets at
///   most one signature: a second signed part starts a new block. A signed
///   empty part right after a block of the other kind belongs to that block;
///   with no block open it is an empty text block of its own;
/// - a `functionCall` arrives whole: start, one delta with the compact
///   `args`, end and ``WireEvent/toolCall(id:call:)``. Calls without `id`
///   get `unladen_gc_<responseId>_<n>` (or a hash-based id without
///   `responseId`, see ``GeminiToolID``), as from
///   ``GeminiCodec/parseResponse(_:origin:)``;
/// - other parts (media, executable code) are ``WireEvent/opaque(_:)``;
/// - `finishReason` (`STOP` with calls is
///   ``WireFinishReason/Unified/toolCalls``), the last `usageMetadata`, the
///   candidate's other keys (`safetyRatings`, `citationMetadata`…, the
///   latest value of each) and `promptFeedback` are delivered in the
///   ``WireEvent/finish(_:)`` emitted by ``finish()``: Gemini has no end
///   event, the stream just ends;
/// - a `{"error":{…}}` frame is ``WireEvent/error(_:)`` (the finish then has
///   reason ``WireFinishReason/Unified/error``), as is a stream cut short
///   (see ``finish()``);
/// - SSE comments are ``WireEvent/ping``.
@_spi(Wire) public struct GeminiStreamDecoder: WireStreamDecoder {
    /// System id stamped on reasoning and on signatures.
    public var origin: WireSystemID?
    public private(set) var warnings: [WireWarning] = []

    private enum Kind: Sendable { case text, reasoning }

    private struct Block: Sendable {
        var id: String
        var kind: Kind
        var signed: Bool
        var endSignature: String?
    }

    private var started = false
    private var done = false
    private var errored = false
    private var nextBlock = 0
    private var calls = 0
    private var seed = GeminiToolID.ReplySeed()
    private var open: Block?
    private var responseID: String?
    private var usage: WireUsage?
    private var finishReason: WireFinishReason?
    private var finishExtra: JSONObject = [:]
    private var warned: Set<String> = []

    public init(origin: WireSystemID? = "gemini") {
        self.origin = origin
    }

    public mutating func decode(_ element: SSEElement) throws(WireDecodingError) -> [WireEvent] {
        switch element {
        case .comment: return done ? [] : [.ping]
        case .retry: return []
        case .event(let event): return try decode(event)
        }
    }

    public mutating func decode(_ event: SSEEvent) throws(WireDecodingError) -> [WireEvent] {
        guard !done else { return [] }
        if event.data.trimmingASCIIWhitespace().isEmpty { return [] }
        let json = try JSONValue.parseWire(Array(event.data.utf8))
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var events: [WireEvent] = []
        if let error = object["error"] {
            ensureStarted(object, into: &events)
            close(into: &events)
            events.append(.error(GeminiDecode.streamError(error)))
            errored = true
            finishReason = WireFinishReason(.error)
            return events
        }
        ensureStarted(object, into: &events)
        if case .object(let value)? = object["usageMetadata"] {
            usage = try GeminiUsage.decode(value, path: "usageMetadata")
        }
        let candidates = object["candidates"]?.arrayValue ?? []
        if candidates.count > 1 {
            warnOnce("candidates", WireWarning(.droppedContent, "only the first candidate is kept", path: "candidates"))
        }
        if case .object(let candidate)? = candidates.first {
            if case .object(let content)? = candidate["content"] {
                let parts = try GeminiDecode.parts(content["parts"], path: "candidates[0].content.parts", origin: origin, isReply: true, warnings: &warnings)
                for part in parts { add(part, into: &events) }
            }
            for (key, value) in candidate {
                switch key {
                case "content", "index": break
                case "finishReason":
                    if case .string(let raw) = value { finishReason = GeminiFinish.decode(raw, hasToolCalls: calls > 0) }
                default: finishExtra[key] = value
                }
            }
        }
        if let feedback = object["promptFeedback"] {
            finishExtra["promptFeedback"] = feedback
            if candidates.isEmpty, feedback["blockReason"] != nil, finishReason == nil { finishReason = GeminiFinish.blockedPrompt }
        }
        return events
    }

    /// Ends the stream: closes the open block and emits the finish event.
    /// Gemini has no end event, so a `finishReason` (or a prompt
    /// `blockReason`) is what marks a complete stream: one that started and
    /// ends without it, and without an error, was cut short. It gets a
    /// warning and an ``WireEvent/error(_:)`` before the finish, whose
    /// reason is ``WireFinishReason/Unified/error``. Idempotent.
    public mutating func finish() -> [WireEvent] {
        guard !done else { return [] }
        var events: [WireEvent] = []
        close(into: &events)
        done = true
        if started, finishReason == nil, !errored {
            warnings.append(WireWarning(.malformedStream, "stream ended without finishReason"))
            events.append(.error(.endedEarly(missing: "finishReason")))
            errored = true
            finishReason = WireFinishReason(.error)
        }
        events.append(.finish(WireFinish(reason: finishReason, usage: usage, extra: finishExtra)))
        return events
    }

    // MARK: Internals

    private mutating func ensureStarted(_ chunk: JSONObject, into events: inout [WireEvent]) {
        guard !started else { return }
        started = true
        responseID = chunk["responseId"]?.stringValue
        var metadata = WireResponseMetadata(source: .gemini)
        metadata.id = responseID
        metadata.model = chunk["modelVersion"]?.stringValue
        for (key, value) in chunk where !GeminiCodec.knownResponseKeys.contains(key) && key != "error" {
            metadata.extra[key] = value
        }
        events.append(.responseMetadata(metadata))
    }

    private mutating func add(_ part: WirePart, into events: inout [WireEvent]) {
        seed.add(part)
        switch part {
        case .text(let text):
            addText(.text, text: text.text, signature: text.signature, extra: text.extra, into: &events)
        case .reasoning(let reasoning):
            addText(.reasoning, text: reasoning.text, signature: reasoning.signature, extra: reasoning.extra, into: &events)
        case .toolCall(var call):
            close(into: &events)
            if call.idSynthesized { call.id = GeminiToolID.reply(responseID: responseID, call: calls, seed: seed) }
            calls += 1
            let id = newBlock("tool")
            let arguments = call.arguments
            call.arguments = ""
            events.append(.toolInputStart(id: id, call: call))
            if !arguments.isEmpty { events.append(.toolInputDelta(id: id, delta: arguments)) }
            events.append(.toolInputEnd(id: id))
            call.arguments = arguments
            events.append(.toolCall(id: id, call: call))
        case .opaque(let opaque):
            close(into: &events)
            events.append(.opaque(opaque))
        case .image, .file, .toolResult, .refusal:
            warnOnce("part", WireWarning(.droppedContent, "a reply part of this kind is not carried"))
        }
    }

    private mutating func addText(_ kind: Kind, text: String, signature: String?, extra: JSONObject, into events: inout [WireEvent]) {
        if text.isEmpty, signature == nil, extra.isEmpty { return }
        if var block = open {
            if block.kind == kind, extra.isEmpty, signature == nil || !block.signed {
                if !text.isEmpty { events.append(delta(block, text)) }
                if let signature {
                    block.signed = true
                    block.endSignature = signature
                }
                open = block
                return
            }
            if text.isEmpty, extra.isEmpty, let signature, !block.signed {
                block.signed = true
                block.endSignature = signature
                open = block
                return
            }
            close(into: &events)
        }
        let id = newBlock(kind == .text ? "text" : "reasoning")
        let block = Block(id: id, kind: kind, signed: signature != nil)
        switch kind {
        case .text:
            events.append(.textStart(id: id, text: WireText("", signature: signature, origin: signature == nil ? nil : origin, extra: extra)))
        case .reasoning:
            events.append(.reasoningStart(id: id, reasoning: WireReasoning(text: "", signature: signature, origin: origin, extra: extra)))
        }
        open = block
        if !text.isEmpty { events.append(delta(block, text)) }
    }

    private func delta(_ block: Block, _ text: String) -> WireEvent {
        block.kind == .text ? .textDelta(id: block.id, delta: text) : .reasoningDelta(id: block.id, delta: text)
    }

    private mutating func close(into events: inout [WireEvent]) {
        guard let block = open else { return }
        open = nil
        switch block.kind {
        case .text:
            events.append(.textEnd(id: block.id, text: block.endSignature.map { WireText("", signature: $0, origin: origin) }))
        case .reasoning:
            events.append(.reasoningEnd(id: block.id, reasoning: block.endSignature.map { WireReasoning(text: "", signature: $0, origin: origin) }))
        }
    }

    private mutating func newBlock(_ prefix: String) -> String {
        defer { nextBlock += 1 }
        return "\(prefix)-\(nextBlock)"
    }

    private mutating func warnOnce(_ key: String, _ warning: WireWarning) {
        if warned.insert(key).inserted { warnings.append(warning) }
    }
}
