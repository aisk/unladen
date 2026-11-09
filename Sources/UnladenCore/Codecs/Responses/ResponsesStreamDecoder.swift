/// Decodes an OpenAI Responses SSE stream into block-structured wire events.
///
/// Handles:
/// - `response.created` (or, failing that, the first `response.in_progress`
///   or content event) → ``WireEvent/responseMetadata(_:)``; the response
///   object's unknown keys (the echoed request parameters) go to its bag;
/// - `message` items: each `output_text`/`refusal` content part is a block
///   (`content_part.added` → `output_text.delta`/`refusal.delta` →
///   `content_part.done`, whose non-default part keys, e.g. annotations,
///   arrive in the block's end);
/// - `reasoning` items: each summary part (`reasoning_summary_part.added`,
///   `reasoning_summary_text.delta`) and each `reasoning_text` content part
///   is a block with the item id and its index (see ``WireReasoning``). A
///   reasoning block stays open until the item's next part starts or the
///   item is done, so the item-level `encrypted_content` and bag of
///   `output_item.done` arrive in the last block's end; an item with no
///   parts is one empty block at its done;
/// - `function_call`/`custom_tool_call` items: tool-input blocks fed by
///   `function_call_arguments.delta`/`custom_tool_call_input.delta`, then
///   the complete call from `output_item.done`;
/// - other items (`web_search_call`, `mcp_call`, …) → one
///   ``WireEvent/opaque(_:)`` with slot `"item"` at their
///   `output_item.done`; their own progress events are ignored silently;
/// - `response.completed`/`incomplete`/`failed` → ``WireEvent/finish(_:)``
///   with the reason from `status` and `incomplete_details`, the usage, and
///   in its bag the final object's unknown keys that differ from
///   `response.created`'s, plus a failed reply's `error` (which is also sent
///   as ``WireEvent/error(_:)``). A final object whose items never streamed
///   (a relay that only sends the end) has them emitted as blocks first;
/// - `error` events → ``WireEvent/error(_:)``; the finish then has reason
///   ``WireFinishReason/Unified/error``;
/// - SSE comments → ``WireEvent/ping``.
///
/// `*.done` events that repeat accumulated text are ignored. Other unknown
/// event types are ignored with one warning each. `sequence_number` is only
/// checked (a gap or repeat produces one ``WireWarning/Code/malformedStream``
/// warning). The event type is read from the JSON `type`, falling back to
/// the SSE `event` name.
@_spi(Wire) public struct ResponsesStreamDecoder: WireStreamDecoder {
    /// System id stamped on reasoning and item ids.
    public var origin: WireSystemID?
    public private(set) var warnings: [WireWarning] = []

    private enum BlockKind: Sendable { case text, refusal, reasoning, tool }

    private struct ItemState: Sendable {
        var type: String
        var itemID: String?
        /// Block ids by part key (`c<i>`, `s<i>`, `r<i>` for reasoning text,
        /// `call`), and their kinds.
        var blocks: [String: (id: String, kind: BlockKind)] = [:]
        /// Keys of the open blocks, in open order.
        var open: [String] = []
        var call: WireToolCall?
    }

    private var started = false
    private var done = false
    private var errored = false
    private var sawItems = false
    private var sawToolCalls = false
    private var nextBlock = 0
    private var expectedSequence: Int?
    private var items: [Int: ItemState] = [:]
    private var startExtra: JSONObject = [:]
    private var warned: Set<String> = []

    /// Events that only repeat what deltas already said.
    private static let ignoredEvents: Set<String> = [
        "response.in_progress", "response.queued", "response.output_text.done", "response.refusal.done",
        "response.reasoning_summary_text.done", "response.reasoning_summary_part.done", "response.reasoning_text.done",
        "response.function_call_arguments.done", "response.custom_tool_call_input.done",
        "response.output_text.annotation.added",
    ]

    public init(origin: WireSystemID? = "openai") {
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
        guard !done else {
            warnOnce("after-end", WireWarning(.malformedStream, "data after the final response event ignored"))
            return []
        }
        if event.data.trimmingASCIIWhitespace().isEmpty { return [] }
        let json = try JSONValue.parseWire(Array(event.data.utf8))
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        let type = object["type"]?.stringValue ?? event.event ?? ""
        if let sequence = object["sequence_number"]?.numberValue?.int {
            if let expected = expectedSequence, sequence != expected {
                warnOnce("sequence", WireWarning(.malformedStream, "sequence_number \(sequence), expected \(expected)"))
            }
            expectedSequence = sequence + 1
        }
        let index = object["output_index"]?.numberValue?.int ?? -1
        var events: [WireEvent] = []
        switch type {
        case "response.created":
            try start(object["response"]?.objectValue ?? [:], into: &events)
        case "response.in_progress" where !started:
            try start(object["response"]?.objectValue ?? [:], into: &events)
        case "response.output_item.added":
            try ensureStarted(into: &events)
            itemAdded(index, object["item"]?.objectValue ?? [:], into: &events)
        case "response.output_item.done":
            try ensureStarted(into: &events)
            try itemDone(index, object["item"]?.objectValue ?? [:], into: &events)
        case "response.content_part.added":
            if case .object(let part)? = object["part"] {
                openPart(index, contentIndex: object["content_index"]?.numberValue?.int ?? 0, part: part, into: &events)
            }
        case "response.content_part.done":
            if case .object(let part)? = object["part"] {
                closePart(index, contentIndex: object["content_index"]?.numberValue?.int ?? 0, part: part, into: &events)
            }
        case "response.output_text.delta", "response.refusal.delta":
            let key = "c\(object["content_index"]?.numberValue?.int ?? 0)"
            let kind: BlockKind = type == "response.output_text.delta" ? .text : .refusal
            if let block = block(index, key, kind: kind, into: &events), case .string(let delta)? = object["delta"], !delta.isEmpty {
                events.append(kind == .text ? .textDelta(id: block, delta: delta) : .refusalDelta(id: block, delta: delta))
            }
        case "response.reasoning_summary_part.added":
            let summary = object["summary_index"]?.numberValue?.int ?? 0
            _ = block(index, "s\(summary)", kind: .reasoning, into: &events)
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            let key = type == "response.reasoning_text.delta"
                ? "r\(object["content_index"]?.numberValue?.int ?? 0)"
                : "s\(object["summary_index"]?.numberValue?.int ?? 0)"
            if let block = block(index, key, kind: .reasoning, into: &events), case .string(let delta)? = object["delta"], !delta.isEmpty {
                events.append(.reasoningDelta(id: block, delta: delta))
            }
        case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
            if let block = items[index]?.blocks["call"]?.id, case .string(let delta)? = object["delta"] {
                guard !delta.isEmpty else { break }
                items[index]?.call?.arguments += delta
                events.append(.toolInputDelta(id: block, delta: delta))
            } else {
                warnOnce("orphan-call", WireWarning(.malformedStream, "call arguments for an item that is not an open call"))
            }
        case "response.completed", "response.incomplete", "response.failed":
            try ensureStarted(into: &events)
            try end(type, object["response"]?.objectValue ?? [:], into: &events)
        case "error":
            closeAll(into: &events)
            var error = object
            error["type"] = nil
            error["sequence_number"] = nil
            // OpenAI sends the error object nested (`{"type":"error",
            // "error":{…}}`), not at the top level as its reference shows.
            if error["message"] == nil, case .object(let nested)? = error["error"] { error = nested }
            events.append(.error(ResponsesDecode.streamError(.object(error))))
            errored = true
        default:
            if Self.ignoredEvents.contains(type) { break }
            if items[index]?.type.isOpaqueItem == true { break }
            warnOnce("event.\(type)", WireWarning(.droppedContent, "stream event `\(type)` is not carried"))
        }
        return events
    }

    /// Ends the stream: closes open blocks and emits the finish event, unless
    /// a final response event (`response.completed`, `.incomplete` or
    /// `.failed`, the terminal events) already did. A stream that started
    /// and ends without one, and without an error event, was cut short: it
    /// gets a warning and an ``WireEvent/error(_:)`` before the finish,
    /// whose reason is ``WireFinishReason/Unified/error``.
    public mutating func finish() -> [WireEvent] {
        guard !done else { return [] }
        var events: [WireEvent] = []
        closeAll(into: &events)
        if started, !errored {
            warnings.append(WireWarning(.malformedStream, "stream ended without response.completed"))
            events.append(.error(.endedEarly(missing: "response.completed")))
            errored = true
        }
        done = true
        events.append(.finish(WireFinish(reason: errored ? WireFinishReason(.error) : nil)))
        return events
    }

    // MARK: Response

    private mutating func start(_ response: JSONObject, into events: inout [WireEvent]) throws(WireDecodingError) {
        guard !started else {
            warnOnce("start-twice", WireWarning(.malformedStream, "second response.created ignored"))
            return
        }
        started = true
        var ignored: [WireWarning] = []
        let envelope = try ResponsesEnvelope(response, path: "response", warnings: &ignored)
        startExtra = envelope.extra
        events.append(.responseMetadata(WireResponseMetadata(
            id: envelope.id, model: envelope.model, created: envelope.created, usage: envelope.usage,
            extra: envelope.extra, source: .responses,
        )))
    }

    private mutating func ensureStarted(into events: inout [WireEvent]) throws(WireDecodingError) {
        guard !started else { return }
        warnings.append(WireWarning(.malformedStream, "stream did not begin with response.created"))
        try start([:], into: &events)
    }

    private mutating func end(_ type: String, _ response: JSONObject, into events: inout [WireEvent]) throws(WireDecodingError) {
        var ignored: [WireWarning] = []
        let envelope = try ResponsesEnvelope(response, path: "response", warnings: &ignored)
        if !sawItems, let output = envelope.output, !output.isEmpty {
            // A relay that sends only the final object.
            for (i, item) in output.enumerated() {
                let parts = try ResponsesDecode.outputItem(item, path: WirePath.index("response.output", i), origin: origin, warnings: &warnings)
                emitWhole(parts, into: &events)
            }
        }
        closeAll(into: &events)
        let status = envelope.status ?? String(type.dropFirst("response.".count))
        let reason = ResponsesFinish.decode(status: status, incompleteReason: envelope.incompleteReason, hasToolCalls: sawToolCalls)
        var extra = JSONObject()
        for (key, value) in envelope.extra where startExtra[key] != value {
            extra[key] = value
        }
        if let error = envelope.error {
            extra["error"] = error
            if !errored { events.append(.error(ResponsesDecode.streamError(error))) }
        } else if status == "failed", !errored {
            events.append(.error(WireStreamError(message: "response failed")))
        }
        events.append(.finish(WireFinish(reason: reason, usage: envelope.usage, extra: extra)))
        done = true
    }

    // MARK: Items

    private mutating func newBlock(_ prefix: String) -> String {
        defer { nextBlock += 1 }
        return "\(prefix)-\(nextBlock)"
    }

    private mutating func itemAdded(_ index: Int, _ item: JSONObject, into events: inout [WireEvent]) {
        sawItems = true
        if let existing = items[index] {
            warnings.append(WireWarning(.malformedStream, "output item \(index) added twice"))
            close(index, existing, late: nil, into: &events)
        }
        let type = item["type"]?.stringValue ?? ""
        var state = ItemState(type: type, itemID: item["id"]?.stringValue)
        if type == "function_call" || type == "custom_tool_call" {
            var ignored: [WireWarning] = []
            let context = ResponsesDecode.Context(origin: origin, isRequest: false)
            if var call = ResponsesDecode.toolCall(item, path: "item", context: context, warnings: &ignored) {
                let initial = call.arguments
                call.arguments = ""
                let block = newBlock("tool")
                events.append(.toolInputStart(id: block, call: call))
                if !initial.isEmpty { events.append(.toolInputDelta(id: block, delta: initial)) }
                call.arguments = initial
                state.call = call
                state.blocks["call"] = (block, .tool)
                state.open = ["call"]
                sawToolCalls = true
            } else {
                state.type = "#opaque"
            }
        }
        items[index] = state
    }

    private mutating func itemDone(_ index: Int, _ item: JSONObject, into events: inout [WireEvent]) throws(WireDecodingError) {
        sawItems = true
        let type = item["type"]?.stringValue ?? ""
        guard let state = items.removeValue(forKey: index) else {
            // Done without added: the whole item at once.
            let parts = try ResponsesDecode.outputItem(.object(item), path: "item", origin: origin, warnings: &warnings)
            emitWhole(parts, into: &events)
            return
        }
        let context = ResponsesDecode.Context(origin: origin, isRequest: false)
        switch type {
        case "reasoning" where state.type == "reasoning":
            guard let parts = ResponsesDecode.reasoning(item, path: "item", context: context, warnings: &warnings) else {
                close(index, state, late: nil, into: &events)
                events.append(.opaque(WireOpaque(protocol: .responses, value: .object(item), slot: "item")))
                return
            }
            if state.blocks.isEmpty {
                emitWhole(parts.map { .reasoning($0) }, into: &events)
                return
            }
            let last = parts[parts.count - 1]
            let hasLate = last.encrypted != nil || !last.extra.isEmpty
            let late = hasLate ? WireReasoning(text: "", encrypted: last.encrypted, extra: last.extra) : nil
            close(index, state, late: late, into: &events)

        case "function_call", "custom_tool_call":
            if var call = ResponsesDecode.toolCall(item, path: "item", context: context, warnings: &warnings),
               let block = state.blocks["call"]?.id
            {
                if call.arguments.isEmpty { call.arguments = state.call?.arguments ?? "" }
                events.append(.toolInputEnd(id: block))
                events.append(.toolCall(id: block, call: call))
            } else {
                close(index, state, late: nil, into: &events)
                events.append(.opaque(WireOpaque(protocol: .responses, value: .object(item), slot: "item")))
            }

        case "message" where state.type == "message":
            close(index, state, late: nil, into: &events)

        default:
            close(index, state, late: nil, into: &events)
            events.append(.opaque(WireOpaque(protocol: .responses, value: .object(item), slot: "item")))
        }
    }

    /// Emits complete parts as blocks (for items that never streamed).
    private mutating func emitWhole(_ parts: [WirePart], into events: inout [WireEvent]) {
        for part in parts {
            let kind: String
            switch part {
            case .text: kind = "text"
            case .refusal: kind = "refusal"
            case .reasoning: kind = "reasoning"
            case .toolCall:
                kind = "tool"
                sawToolCalls = true
            case .opaque(let opaque):
                events.append(.opaque(opaque))
                continue
            case .image, .file, .toolResult:
                continue
            }
            events += WireEvents.of(part, block: newBlock(kind), lateReasoningData: true, streamingToolInput: true) ?? []
        }
    }

    // MARK: Parts

    /// The block for a part of item `index`, opening it if needed.
    private mutating func block(_ index: Int, _ key: String, kind: BlockKind, into events: inout [WireEvent]) -> String? {
        guard var state = items[index] else {
            warnOnce("orphan-part", WireWarning(.malformedStream, "content for an output item that is not open"))
            return nil
        }
        if let existing = state.blocks[key] { return existing.id }
        let id: String
        switch kind {
        case .text, .refusal:
            guard state.type == "message" else { return nil }
            id = newBlock(kind == .text ? "text" : "refusal")
            let itemOrigin = state.itemID == nil ? nil : origin
            if kind == .text {
                events.append(.textStart(id: id, text: WireText("", itemID: state.itemID, origin: itemOrigin)))
            } else {
                events.append(.refusalStart(id: id, refusal: WireRefusal("", itemID: state.itemID, origin: itemOrigin)))
            }
        case .reasoning:
            guard state.type == "reasoning" else { return nil }
            // The previous part of the item is complete.
            for open in state.open {
                if let previous = state.blocks[open] { events.append(.reasoningEnd(id: previous.id, reasoning: nil)) }
            }
            state.open = []
            id = newBlock("reasoning")
            let partIndex = Int(key.dropFirst()) ?? 0
            events.append(.reasoningStart(id: id, reasoning: WireReasoning(
                text: "", itemID: state.itemID, summaryIndex: partIndex, origin: origin,
                sourceKey: key.hasPrefix("r") ? "content" : nil,
            )))
        case .tool:
            return nil
        }
        state.blocks[key] = (id, kind)
        state.open.append(key)
        items[index] = state
        return id
    }

    private mutating func openPart(_ index: Int, contentIndex: Int, part: JSONObject, into events: inout [WireEvent]) {
        guard let state = items[index], state.blocks["c\(contentIndex)"] == nil else { return }
        switch part["type"]?.stringValue {
        case "output_text" where state.type == "message":
            guard let id = block(index, "c\(contentIndex)", kind: .text, into: &events) else { return }
            let extra = partBag(part, textKey: "text")
            if !extra.isEmpty, case .textStart(let start, var text)? = events.last, start == id {
                text.extra = extra
                events[events.count - 1] = .textStart(id: id, text: text)
            }
        case "refusal" where state.type == "message":
            guard let id = block(index, "c\(contentIndex)", kind: .refusal, into: &events) else { return }
            let extra = partBag(part, textKey: "refusal")
            if !extra.isEmpty, case .refusalStart(let start, var refusal)? = events.last, start == id {
                refusal.extra = extra
                events[events.count - 1] = .refusalStart(id: id, refusal: refusal)
            }
        case "reasoning_text" where state.type == "reasoning":
            _ = block(index, "r\(contentIndex)", kind: .reasoning, into: &events)
        default:
            warnOnce("part.\(part["type"]?.stringValue ?? "")", WireWarning(.droppedContent, "content part of type `\(part["type"]?.stringValue ?? "")` is not carried"))
        }
    }

    private mutating func closePart(_ index: Int, contentIndex: Int, part: JSONObject, into events: inout [WireEvent]) {
        let key = "c\(contentIndex)"
        guard var state = items[index], let block = state.blocks[key], state.open.contains(key) else { return }
        let extra: JSONObject
        switch block.kind {
        case .text:
            extra = partBag(part, textKey: "text")
            events.append(.textEnd(id: block.id, text: extra.isEmpty ? nil : WireText("", extra: extra)))
        case .refusal:
            extra = partBag(part, textKey: "refusal")
            events.append(.refusalEnd(id: block.id, refusal: extra.isEmpty ? nil : WireRefusal("", extra: extra)))
        case .reasoning, .tool:
            return
        }
        state.open.removeAll { $0 == key }
        items[index] = state
    }

    /// A content part's keys besides `type`, its text and default empty
    /// `annotations`/`logprobs`.
    private func partBag(_ part: JSONObject, textKey: String) -> JSONObject {
        var bag = JSONObject()
        for (key, value) in part where key != "type" && key != textKey {
            if (key == "annotations" || key == "logprobs") && value == .array([]) { continue }
            bag[key] = value
        }
        return bag
    }

    /// Closes the item's open blocks; the last-opened reasoning block gets
    /// `late`.
    private mutating func close(_ index: Int, _ state: ItemState, late: WireReasoning?, into events: inout [WireEvent]) {
        for (i, key) in state.open.enumerated() {
            guard let block = state.blocks[key] else { continue }
            switch block.kind {
            case .text: events.append(.textEnd(id: block.id, text: nil))
            case .refusal: events.append(.refusalEnd(id: block.id, refusal: nil))
            case .reasoning: events.append(.reasoningEnd(id: block.id, reasoning: i == state.open.count - 1 ? late : nil))
            case .tool:
                events.append(.toolInputEnd(id: block.id))
                if let call = state.call { events.append(.toolCall(id: block.id, call: call)) }
            }
        }
        items[index] = nil
    }

    private mutating func closeAll(into events: inout [WireEvent]) {
        for index in items.keys.sorted() {
            if let state = items[index] { close(index, state, late: nil, into: &events) }
        }
    }

    private mutating func warnOnce(_ key: String, _ warning: WireWarning) {
        if warned.insert(key).inserted { warnings.append(warning) }
    }
}

private extension String {
    /// Item types the decoder keeps opaque (their progress events are
    /// ignored silently).
    var isOpaqueItem: Bool {
        !["message", "reasoning", "function_call", "custom_tool_call"].contains(self)
    }
}
