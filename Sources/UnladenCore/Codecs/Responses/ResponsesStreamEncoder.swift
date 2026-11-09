/// Encodes wire events as an OpenAI Responses SSE stream for a client.
///
/// Numbering: the encoder alone assigns every index and id.
/// - `sequence_number` counts every event from 0 (`response.created`)
///   without gaps; keepalive comments are not events.
/// - `output_index` counts output items from 0 in the order they are
///   added; `content_index` counts a message's (or a reasoning item's
///   `reasoning_text`) parts from 0, `summary_index` a reasoning item's
///   summary parts from 0. Wire block ids and ``WireReasoning/summaryIndex``
///   are ignored.
/// - Item ids: a given ``WireText/itemID`` / ``WireToolCall/itemID`` is
///   kept, as is a reasoning item id whose origin ``ResponsesReplay``
///   accepts; anything else gets a deterministic, recognisable id
///   `<prefix>_unladen_<seed>_<output_index>` (see ``ResponsesItemID``),
///   which the request parser clears when a client echoes it.
///
/// Items:
/// - One item is open at a time and Responses items are written one after
///   another, so blocks that start while another is live (Chat's
///   interleaved parallel tool calls) are buffered and written in start
///   order once it ends, as in ``AnthropicMessagesStreamEncoder``.
/// - Consecutive text/refusal blocks with the same item id (or none) are
///   parts of one `message` item; consecutive reasoning blocks with the
///   same non-nil item id are summary (or `reasoning_text`) parts of one
///   `reasoning` item. An item is done (`response.output_item.done`) when
///   the next item starts or the reply ends.
/// - A reasoning item is added lazily, at its first text or at its end if
///   it carries data to replay, so reasoning with nothing to show produces
///   no item. Its `encrypted_content` is the upstream's own when
///   ``ResponsesReplay`` accepts the origin, and otherwise an envelope
///   (``ResponsesSeal``) of the origin's signature/encrypted data.
/// - Tool calls are `function_call` (or `custom_tool_call`, by
///   ``WireToolCall/itemType``) items; a call that received no arguments
///   gets `{}`. A call's signature from another system (Gemini's
///   `thoughtSignature`) is sealed into a reasoning item written just
///   before the call (see ``ResponsesSeal``). Responses opaque items are written whole; other protocols'
///   opaque content is dropped with a warning.
///
/// The reply:
/// - `response.created` and `response.in_progress` go out on
///   ``WireEvent/responseMetadata(_:)`` (or before the first content).
/// - The final event is `response.completed`, `response.incomplete`
///   (length/content-filter finishes; the open item is then `incomplete`)
///   or `response.failed` (an error finish, or any ``WireEvent/error(_:)``,
///   whose error becomes `response.error`; no separate `error` event is
///   written). Its `response.output` is the list of items exactly as their
///   `response.output_item.done` events carried them, and
///   ``finalResponse`` keeps it for non-streaming replies.
/// - Same-protocol bags are written: the metadata bag in every `response`
///   object (overlaid with the finish bag at the end), part bags in parts,
///   item bags in items. Another protocol's reply gets the fields SDKs
///   expect (`resp_` id prefix, `parallel_tool_calls`, `tool_choice`,
///   `tools`, a complete `usage`).
/// - ``WireEvent/ping`` becomes an SSE comment.
package struct ResponsesStreamEncoder: Sendable {
    package private(set) var warnings: [WireWarning] = []
    /// The `response` object of the final event, once written.
    package private(set) var finalResponse: JSONValue?

    private enum ItemKind: Equatable, Sendable { case message, reasoning, call(custom: Bool) }

    private struct Item: Sendable {
        var kind: ItemKind
        /// The wire item id it was opened for (the merge key).
        var sourceID: String?
        var id = ""
        /// Set once `response.output_item.added` is written.
        var index: Int?
        var parts: [JSONValue] = []
        var summary: [JSONValue] = []
        var content: [JSONValue] = []
        var accepted = false
        var origin: WireSystemID?
        var signature: String?
        var encrypted: String?
        /// ``ResponsesSeal/Contents/target`` of a sealed call signature.
        var target: String?
        var extra: JSONObject = [:]
        var call: WireToolCall?
        var arguments = ""
    }

    private enum PartKind: Sendable { case text, refusal, summary, reasoningText, tool }

    private struct Live: Sendable {
        var block: String
        var kind: PartKind
        /// Content/summary index, once the part is opened on the wire.
        var index: Int?
        var text = ""
        var extra: JSONObject = [:]
    }

    private var id: String
    private var model: String
    private var created: Int
    private var trusted: Set<WireSystemID>
    private var sameProtocol = false
    private var startExtra: JSONObject = [:]
    private var started = false
    private var done = false
    private var sequence = 0
    private var output: [JSONValue] = []
    private var item: Item?
    private var live: Live?
    private var errors: [WireStreamError] = []
    /// Blocks (or whole events, `id == nil`) waiting for the live block.
    private var waiting: [(id: String?, events: [WireEvent])] = []
    private var streamedTools: Set<String> = []
    private var warned: Set<String> = []

    package init(defaults: ResponsesResponseDefaults) {
        self.id = defaults.id
        self.model = defaults.model
        self.created = defaults.created
        self.trusted = defaults.trustedReasoningOrigins
    }

    package mutating func encode(_ event: WireEvent) -> [SSEElement] {
        guard !done else { return [] }
        var out: [SSEElement] = []
        switch event {
        case .responseMetadata(let metadata):
            guard !started else { break }
            sameProtocol = metadata.source == .responses
            if let value = metadata.id { id = value }
            if !sameProtocol, !id.hasPrefix("resp_") { id = "resp_" + id }
            if let value = metadata.model { model = value }
            if let value = metadata.created { created = value }
            startExtra = metadata.extra
            if !sameProtocol, !metadata.extra.isEmpty {
                var ignored = JSONObject()
                appendExtra(metadata.extra, to: &ignored, include: false, path: "", warnings: &warnings)
            }
            ensureStarted(into: &out)

        case .ping:
            out.append(.comment("ping"))

        case .error(let error):
            errors.append(error)

        case .finish(let finish):
            out += finishEvents(finish)

        case .textStart(let block, _), .reasoningStart(let block, _), .refusalStart(let block, _),
             .toolInputStart(let block, _):
            if case .toolInputStart = event { streamedTools.insert(block) }
            if live == nil, waiting.isEmpty {
                write(event, into: &out)
            } else {
                waiting.append((block, [event]))
            }

        case .textDelta(let block, _), .textEnd(let block, _), .reasoningDelta(let block, _),
             .reasoningSignatureDelta(let block, _), .reasoningEnd(let block, _), .refusalDelta(let block, _),
             .refusalEnd(let block, _), .toolInputDelta(let block, _), .toolInputEnd(let block):
            if live?.block == block {
                write(event, into: &out)
                if live == nil { drain(into: &out) }
            } else if let slot = waiting.firstIndex(where: { $0.id == block }) {
                waiting[slot].events.append(event)
            } else {
                warnOnce("orphan.\(block)", WireWarning(.malformedStream, "event for block \(block) that was never started"))
            }

        case .toolCall(let block, _):
            // Already streamed through tool-input events, or delivered whole.
            guard !streamedTools.contains(block) else { break }
            fallthrough
        case .opaque:
            if live == nil, waiting.isEmpty {
                write(event, into: &out)
            } else {
                waiting.append((nil, [event]))
            }
        }
        return out
    }

    /// End of input. Ends the reply if no finish event did.
    package mutating func finish() -> [SSEElement] {
        guard !done else { return [] }
        return finishEvents(WireFinish())
    }

    /// A keepalive that is an event, for a gateway client whose idle timer
    /// ignores SSE comments (Codex counts events only): the reply's
    /// `response.created`/`response.in_progress` if it has not started yet,
    /// else another `response.in_progress` with the next `sequence_number`.
    /// Nothing once the reply ended. Starting the reply here fixes its id
    /// and model before upstream metadata arrives (later metadata is then
    /// ignored), as for content arriving first.
    package mutating func keepalive() -> [SSEElement] {
        guard !done else { return [] }
        var out: [SSEElement] = []
        if !started {
            ensureStarted(into: &out)
        } else {
            let response = responseObject(status: "in_progress", error: .null, incompleteReason: nil, usage: nil, overlay: [:])
            emit("response.in_progress", ["response": response], into: &out)
        }
        return out
    }

    // MARK: Scheduling

    private mutating func drain(into out: inout [SSEElement]) {
        while live == nil, !waiting.isEmpty {
            let next = waiting.removeFirst()
            for event in next.events { write(event, into: &out) }
        }
    }

    private mutating func flushAll(into out: inout [SSEElement]) {
        closeLive(into: &out)
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            for event in next.events { write(event, into: &out) }
            closeLive(into: &out)
        }
    }

    private mutating func closeLive(into out: inout [SSEElement]) {
        guard let current = live else { return }
        switch current.kind {
        case .text: write(.textEnd(id: current.block, text: nil), into: &out)
        case .refusal: write(.refusalEnd(id: current.block, refusal: nil), into: &out)
        case .summary, .reasoningText: write(.reasoningEnd(id: current.block, reasoning: nil), into: &out)
        case .tool: write(.toolInputEnd(id: current.block), into: &out)
        }
    }

    private mutating func finishEvents(_ finish: WireFinish) -> [SSEElement] {
        var out: [SSEElement] = []
        ensureStarted(into: &out)
        flushAll(into: &out)
        var (status, incomplete) = ResponsesFinish.encode(finish.reason, sameProtocol: sameProtocol)
        if !errors.isEmpty { (status, incomplete) = ("failed", nil) }
        closeItem(status: status == "incomplete" ? "incomplete" : "completed", into: &out)

        var error: JSONValue = .null
        if status == "failed" {
            if sameProtocol, case .object? = finish.extra["error"] {
                error = finish.extra["error"] ?? .null
            } else if let last = errors.last {
                if sameProtocol, case .object? = last.raw {
                    error = last.raw ?? .null
                } else {
                    error = ["code": .string(last.code ?? "server_error"), "message": .string(last.message)]
                }
            } else {
                error = ["code": "server_error", "message": ""]
            }
        }
        var overlay = finish.extra
        overlay["error"] = nil
        if !sameProtocol, !overlay.isEmpty {
            var ignored = JSONObject()
            appendExtra(overlay, to: &ignored, include: false, path: "", warnings: &warnings)
        }
        let response = responseObject(
            status: status, error: error, incompleteReason: incomplete, usage: finish.usage,
            overlay: sameProtocol ? overlay : [:],
        )
        finalResponse = response
        let type = switch status {
        case "incomplete": "response.incomplete"
        case "failed": "response.failed"
        default: "response.completed"
        }
        emit(type, ["response": response], into: &out)
        done = true
        return out
    }

    // MARK: Writing

    private mutating func ensureStarted(into out: inout [SSEElement]) {
        guard !started else { return }
        started = true
        if !sameProtocol, !id.hasPrefix("resp_") { id = "resp_" + id }
        let response = responseObject(status: "in_progress", error: .null, incompleteReason: nil, usage: nil, overlay: [:])
        emit("response.created", ["response": response], into: &out)
        emit("response.in_progress", ["response": response], into: &out)
    }

    private func responseObject(
        status: String,
        error: JSONValue,
        incompleteReason: String?,
        usage: WireUsage?,
        overlay: JSONObject,
    ) -> JSONValue {
        var object = JSONObject()
        object["id"] = .string(id)
        object["object"] = "response"
        object["created_at"] = .number(JSONNumber(created))
        object["status"] = .string(status)
        object["error"] = error
        object["incomplete_details"] = incompleteReason.map { ["reason": .string($0)] } ?? .null
        object["model"] = .string(model)
        object["output"] = .array(output)
        if status == "in_progress" {
            object["usage"] = .null
        } else if let usage {
            object["usage"] = ResponsesUsage.encode(usage, include: sameProtocol)
        } else {
            object["usage"] = sameProtocol ? .null : ResponsesUsage.encode(WireUsage(), include: false)
        }
        if sameProtocol {
            var bag = startExtra
            for (key, value) in overlay { bag[key] = value }
            var ignored: [WireWarning] = []
            appendExtra(bag, to: &object, include: true, path: "response", warnings: &ignored)
        } else {
            object["parallel_tool_calls"] = true
            object["tool_choice"] = "auto"
            object["tools"] = []
        }
        return .object(object)
    }

    private mutating func write(_ event: WireEvent, into out: inout [SSEElement]) {
        ensureStarted(into: &out)
        switch event {
        case .textStart(let block, let text):
            if text.signature != nil { dropOnce("text-signature", "text signature cannot be carried by Responses") }
            openContent(block: block, kind: .text, itemID: text.itemID, extra: text.extra, into: &out)

        case .refusalStart(let block, let refusal):
            openContent(block: block, kind: .refusal, itemID: refusal.itemID, extra: refusal.extra, into: &out)

        case .textDelta(_, let delta), .refusalDelta(_, let delta):
            guard !delta.isEmpty, var current = live, let item, let index = item.index, let part = current.index else { break }
            current.text += delta
            live = current
            if current.kind == .text {
                emit("response.output_text.delta", [
                    "item_id": .string(item.id), "output_index": number(index), "content_index": number(part),
                    "delta": .string(delta), "logprobs": [],
                ], into: &out)
            } else {
                emit("response.refusal.delta", [
                    "item_id": .string(item.id), "output_index": number(index), "content_index": number(part),
                    "delta": .string(delta),
                ], into: &out)
            }

        case .textEnd(_, let late):
            if let late {
                if late.signature != nil { dropOnce("text-signature", "text signature cannot be carried by Responses") }
                for (key, value) in late.extra { live?.extra[key] = value }
            }
            closeContent(into: &out)

        case .refusalEnd(_, let late):
            if let late {
                for (key, value) in late.extra { live?.extra[key] = value }
            }
            closeContent(into: &out)

        case .reasoningStart(let block, let reasoning):
            if let current = item, current.kind == .reasoning, let source = current.sourceID, source == reasoning.itemID {
                // Another part of the same reasoning item.
            } else {
                closeItem(status: "completed", into: &out)
                var next = Item(kind: .reasoning, sourceID: reasoning.itemID)
                next.accepted = ResponsesReplay.accepts(reasoning, sameProtocol: sameProtocol, trusted: trusted)
                next.origin = reasoning.origin
                item = next
            }
            mergeReasoning(reasoning)
            live = Live(block: block, kind: reasoning.sourceKey == "content" ? .reasoningText : .summary)

        case .reasoningDelta(_, let delta):
            guard !delta.isEmpty else { break }
            addItem(into: &out)
            openReasoningPart(into: &out)
            guard var current = live, let item, let index = item.index, let part = current.index else { break }
            current.text += delta
            live = current
            if current.kind == .summary {
                emit("response.reasoning_summary_text.delta", [
                    "item_id": .string(item.id), "output_index": number(index), "summary_index": number(part),
                    "delta": .string(delta),
                ], into: &out)
            } else {
                emit("response.reasoning_text.delta", [
                    "item_id": .string(item.id), "output_index": number(index), "content_index": number(part),
                    "delta": .string(delta),
                ], into: &out)
            }

        case .reasoningSignatureDelta(_, let delta):
            if var current = item {
                current.signature = (current.signature ?? "") + delta
                item = current
            }

        case .reasoningEnd(_, let late):
            if let late { mergeReasoning(late) }
            if let current = live, let part = current.index, let item, let index = item.index {
                let common: JSONObject = ["item_id": .string(item.id), "output_index": number(index)]
                if current.kind == .summary {
                    let json: JSONValue = ["type": "summary_text", "text": .string(current.text)]
                    emit("response.reasoning_summary_text.done", common.merging(["summary_index": number(part), "text": .string(current.text)]), into: &out)
                    emit("response.reasoning_summary_part.done", common.merging(["summary_index": number(part), "part": json]), into: &out)
                    self.item?.summary.append(json)
                } else {
                    let json: JSONValue = ["type": "reasoning_text", "text": .string(current.text)]
                    emit("response.reasoning_text.done", common.merging(["content_index": number(part), "text": .string(current.text)]), into: &out)
                    emit("response.content_part.done", common.merging(["content_index": number(part), "part": json]), into: &out)
                    self.item?.content.append(json)
                }
            }
            live = nil
            if let current = item, current.index == nil,
               current.signature != nil || current.encrypted != nil || (current.accepted && current.sourceID != nil)
            {
                addItem(into: &out)
            }

        case .toolInputStart(let block, let call):
            openCall(call, into: &out)
            live = Live(block: block, kind: .tool)

        case .toolInputDelta(_, let delta):
            appendArguments(delta, into: &out)

        case .toolInputEnd:
            closeCall(into: &out)

        case .toolCall(let block, let call):
            var start = call
            start.arguments = ""
            openCall(start, into: &out)
            live = Live(block: block, kind: .tool)
            appendArguments(call.arguments, into: &out)
            closeCall(into: &out)

        case .opaque(let opaque):
            guard opaque.protocol == .responses, case .object = opaque.value else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) stream content cannot be carried by Responses"))
                break
            }
            closeItem(status: "completed", into: &out)
            let index = output.count
            emit("response.output_item.added", ["output_index": number(index), "item": opaque.value], into: &out)
            emit("response.output_item.done", ["output_index": number(index), "item": opaque.value], into: &out)
            output.append(opaque.value)

        case .responseMetadata, .ping, .error, .finish:
            break
        }
    }

    // MARK: Messages

    private mutating func openContent(block: String, kind: PartKind, itemID: String?, extra: JSONObject, into out: inout [SSEElement]) {
        if let current = item, current.kind == .message, current.sourceID == itemID {
            // Another part of the same message.
        } else {
            closeItem(status: "completed", into: &out)
            item = Item(kind: .message, sourceID: itemID)
            addItem(into: &out)
        }
        guard let item, let index = item.index else { return }
        let part = item.parts.count
        live = Live(block: block, kind: kind, index: part, extra: extra)
        var ignored: [WireWarning] = []
        emit("response.content_part.added", [
            "item_id": .string(item.id), "output_index": number(index), "content_index": number(part),
            "part": contentPart(kind, text: "", extra: extra, warnings: &ignored),
        ], into: &out)
    }

    private mutating func closeContent(into out: inout [SSEElement]) {
        guard let current = live, let part = current.index, let item, let index = item.index else {
            live = nil
            return
        }
        let common: JSONObject = ["item_id": .string(item.id), "output_index": number(index), "content_index": number(part)]
        if current.kind == .text {
            emit("response.output_text.done", common.merging(["text": .string(current.text), "logprobs": []]), into: &out)
        } else {
            emit("response.refusal.done", common.merging(["refusal": .string(current.text)]), into: &out)
        }
        let json = contentPart(current.kind, text: current.text, extra: current.extra, warnings: &warnings)
        emit("response.content_part.done", common.merging(["part": json]), into: &out)
        self.item?.parts.append(json)
        live = nil
    }

    /// An `output_text` or `refusal` part; the same protocol's bag supplies
    /// `annotations`/`logprobs` when it has them.
    private func contentPart(_ kind: PartKind, text: String, extra: JSONObject, warnings: inout [WireWarning]) -> JSONValue {
        var object = JSONObject()
        var bag = extra
        if kind == .text {
            object["type"] = "output_text"
            object["annotations"] = (sameProtocol ? bag.removeValue(forKey: "annotations") : nil) ?? []
            object["logprobs"] = (sameProtocol ? bag.removeValue(forKey: "logprobs") : nil) ?? []
            object["text"] = .string(text)
        } else {
            object["type"] = "refusal"
            object["refusal"] = .string(text)
        }
        appendExtra(bag, to: &object, include: sameProtocol, path: "part", warnings: &warnings)
        return .object(object)
    }

    // MARK: Reasoning

    private mutating func mergeReasoning(_ reasoning: WireReasoning) {
        guard item?.kind == .reasoning else { return }
        if let value = reasoning.signature { item?.signature = value }
        if let value = reasoning.encrypted { item?.encrypted = value }
        for (key, value) in reasoning.extra { item?.extra[key] = value }
    }

    private mutating func openReasoningPart(into out: inout [SSEElement]) {
        guard var current = live, current.index == nil, let item, let index = item.index else { return }
        let common: JSONObject = ["item_id": .string(item.id), "output_index": number(index)]
        if current.kind == .summary {
            current.index = item.summary.count
            emit("response.reasoning_summary_part.added", common.merging([
                "summary_index": number(item.summary.count), "part": ["type": "summary_text", "text": ""],
            ]), into: &out)
        } else {
            current.index = item.content.count
            emit("response.content_part.added", common.merging([
                "content_index": number(item.content.count), "part": ["type": "reasoning_text", "text": ""],
            ]), into: &out)
        }
        live = current
    }

    // MARK: Calls

    private mutating func openCall(_ call: WireToolCall, into out: inout [SSEElement]) {
        closeItem(status: "completed", into: &out)
        if let signature = call.signature {
            if ResponsesReplay.acceptsID(origin: call.origin, sameProtocol: sameProtocol, trusted: trusted) {
                dropOnce("tool-signature", "tool call signature cannot be carried by Responses")
            } else {
                // Sealed into a reasoning item just before the call.
                var carrier = Item(kind: .reasoning, sourceID: nil)
                carrier.origin = call.origin
                carrier.signature = signature
                carrier.target = ResponsesSeal.callTarget
                item = carrier
                addItem(into: &out)
                closeItem(status: "completed", into: &out)
            }
        }
        var next = Item(kind: .call(custom: call.itemType == "custom_tool_call"), sourceID: call.itemID)
        next.call = call
        item = next
        addItem(into: &out)
    }

    private mutating func appendArguments(_ delta: String, into out: inout [SSEElement]) {
        guard !delta.isEmpty, let item, case .call(let custom) = item.kind, let index = item.index else { return }
        self.item?.arguments += delta
        emit(custom ? "response.custom_tool_call_input.delta" : "response.function_call_arguments.delta", [
            "item_id": .string(item.id), "output_index": number(index), "delta": .string(delta),
        ], into: &out)
    }

    private mutating func closeCall(into out: inout [SSEElement]) {
        live = nil
        guard let current = item, case .call(let custom) = current.kind, let index = current.index else { return }
        if !custom, current.arguments.trimmingASCIIWhitespace().isEmpty {
            appendArguments("{}", into: &out)
        }
        let arguments = item?.arguments ?? ""
        if custom {
            emit("response.custom_tool_call_input.done", [
                "item_id": .string(current.id), "output_index": number(index), "input": .string(arguments),
            ], into: &out)
        } else {
            emit("response.function_call_arguments.done", [
                "item_id": .string(current.id), "output_index": number(index), "arguments": .string(arguments),
            ], into: &out)
        }
        closeItem(status: "completed", into: &out)
    }

    // MARK: Items

    /// Writes `response.output_item.added` for the open item, if not yet.
    private mutating func addItem(into out: inout [SSEElement]) {
        guard var current = item, current.index == nil else { return }
        let index = output.count
        current.index = index
        func synthesized(_ prefix: String) -> String { ResponsesItemID.mint(prefix: prefix, responseID: id, index: index) }
        var object = JSONObject()
        switch current.kind {
        case .message:
            current.id = current.sourceID ?? synthesized("msg")
            object["id"] = .string(current.id)
            object["type"] = "message"
            object["status"] = "in_progress"
            object["content"] = []
            object["role"] = "assistant"
        case .reasoning:
            current.id = (current.accepted ? current.sourceID : nil) ?? synthesized("rs")
            object["id"] = .string(current.id)
            object["type"] = "reasoning"
            object["summary"] = []
        case .call(let custom):
            current.id = current.sourceID ?? synthesized(custom ? "ctc" : "fc")
            var ignored: [WireWarning] = []
            object = callObject(current, status: "in_progress", arguments: "", warnings: &ignored)
        }
        item = current
        emit("response.output_item.added", ["output_index": number(index), "item": .object(object)], into: &out)
    }

    private mutating func closeItem(status: String, into out: inout [SSEElement]) {
        defer { item = nil }
        guard let current = item, let index = current.index else { return }
        var object = JSONObject()
        switch current.kind {
        case .message:
            object["id"] = .string(current.id)
            object["type"] = "message"
            object["status"] = .string(status)
            object["content"] = .array(current.parts)
            object["role"] = "assistant"
        case .reasoning:
            object["id"] = .string(current.id)
            object["type"] = "reasoning"
            object["summary"] = .array(current.summary)
            if !current.content.isEmpty { object["content"] = .array(current.content) }
            // Bare `encrypted_content` comes back read as OpenAI's
            // (``ResponsesReplay/system``): another system's, even a trusted
            // one, goes sealed so its origin comes back with it.
            let bare = current.accepted && current.signature == nil
                && (current.origin == nil || current.origin == ResponsesReplay.system)
            if bare {
                if let value = current.encrypted { object["encrypted_content"] = .string(value) }
            } else if current.signature != nil || current.encrypted != nil {
                object["encrypted_content"] = .string(ResponsesSeal.seal(ResponsesSeal.Contents(
                    origin: current.origin ?? "unknown", signature: current.signature, encrypted: current.encrypted,
                    target: current.target,
                )))
            }
            appendExtra(current.extra, to: &object, include: sameProtocol, path: "item", warnings: &warnings)
        case .call:
            object = callObject(current, status: status, arguments: current.arguments, warnings: &warnings)
        }
        emit("response.output_item.done", ["output_index": number(index), "item": .object(object)], into: &out)
        output.append(.object(object))
    }

    private func callObject(_ item: Item, status: String, arguments: String, warnings: inout [WireWarning]) -> JSONObject {
        let call = item.call ?? WireToolCall(id: "", name: "", arguments: "")
        let custom = item.kind == .call(custom: true)
        var object = JSONObject()
        object["id"] = .string(item.id)
        object["type"] = custom ? "custom_tool_call" : "function_call"
        object["status"] = .string(status)
        object[custom ? "input" : "arguments"] = .string(arguments)
        object["call_id"] = .string(call.id)
        object["name"] = .string(call.name)
        appendExtra(call.extra, to: &object, include: sameProtocol, path: "item", warnings: &warnings)
        return object
    }

    // MARK: Output

    private mutating func emit(_ type: String, _ fields: JSONObject, into out: inout [SSEElement]) {
        var object = JSONObject()
        object["type"] = .string(type)
        object["sequence_number"] = .number(JSONNumber(sequence))
        sequence += 1
        for (key, value) in fields { object[key] = value }
        out.append(.event(SSEEvent(event: type, data: String(decoding: JSONValue.object(object).encoded(), as: UTF8.self))))
    }

    private func number(_ value: Int) -> JSONValue { .number(JSONNumber(value)) }

    private mutating func dropOnce(_ key: String, _ message: String) {
        if warned.insert(key).inserted { warnings.append(WireWarning(.droppedContent, message)) }
    }

    private mutating func warnOnce(_ key: String, _ warning: WireWarning) {
        if warned.insert(key).inserted { warnings.append(warning) }
    }
}

extension JSONObject {
    /// This object with `other`'s keys appended (or replaced).
    func merging(_ other: JSONObject) -> JSONObject {
        var result = self
        for (key, value) in other { result[key] = value }
        return result
    }
}
