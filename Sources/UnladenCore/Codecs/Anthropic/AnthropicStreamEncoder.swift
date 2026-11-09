/// Encodes wire events as an Anthropic Messages SSE stream for a client.
///
/// - Every event carries its `event:` name. `message_start` is sent on
///   ``WireEvent/responseMetadata(_:)`` (or before the first content), with
///   the early usage when known and zero counts otherwise (Anthropic SDKs
///   require a usage object there).
/// - Assigns content-block `index`es itself, contiguously from 0. Anthropic
///   streams one block at a time, so blocks that start while another is open
///   (Chat's interleaved parallel tool calls) are buffered and written, in
///   start order, once the open block stops.
/// - Thinking blocks open lazily, at their first content, so reasoning that
///   turns out to carry nothing Anthropic can show (another system's
///   encrypted reasoning) produces no block. Signatures and redacted data
///   are written only if ``AnthropicReplay`` accepts their origin; foreign
///   reasoning text goes out with an empty signature and a warning.
/// - Refusals become text blocks; tool calls delivered whole become a
///   `tool_use` block with one `input_json_delta`; a tool block that received
///   no input gets `{}`. Anthropic opaque blocks are written whole (server
///   `*_tool_use` blocks send their `input` as one `input_json_delta`).
/// - Same-protocol bags are written: the message bag in `message_start`,
///   block bags in `content_block_start`, finish bag in `message_delta.delta`.
///   A text block's late `citations` (see ``AnthropicMessagesStreamDecoder``)
///   go out as `citations_delta`s before its stop.
/// - ``WireEvent/ping`` becomes `event: ping` once `message_start` is out,
///   an SSE comment before (SDKs reject events before `message_start`).
/// - ``WireEvent/error(_:)`` becomes an `error` event, which ends the stream
///   (no `message_delta`/`message_stop` follow, as with Anthropic).
package struct AnthropicMessagesStreamEncoder: Sendable {
    package private(set) var warnings: [WireWarning] = []

    private enum Kind: Sendable { case text, reasoning, tool }

    /// The block being written.
    private struct Live: Sendable {
        var block: String
        var kind: Kind
        /// Assigned when the block is opened on the wire.
        var index: Int?
        var accepted = false
        var redacted = false
        var startObject: JSONObject = [:]
        var sentInput = false
    }

    private var id: String
    private var model: String
    private var trusted: Set<WireSystemID>
    private var sameProtocol = false
    private var startUsage: WireUsage?
    private var startExtra: JSONObject = [:]
    private var started = false
    private var done = false
    private var errored = false
    private var nextIndex = 0
    private var live: Live?
    /// Blocks (or whole events, `id == nil`) waiting for the live block.
    private var waiting: [(id: String?, events: [WireEvent])] = []
    private var streamedTools: Set<String> = []
    private var warned: Set<String> = []

    package init(defaults: AnthropicResponseDefaults) {
        self.id = defaults.id
        self.model = defaults.model
        self.trusted = defaults.trustedReasoningOrigins
    }

    package mutating func encode(_ event: WireEvent) -> [SSEElement] {
        guard !done else { return [] }
        var output: [SSEElement] = []
        switch event {
        case .responseMetadata(let metadata):
            guard !started else { break }
            if let value = metadata.id { id = value }
            if let value = metadata.model { model = value }
            sameProtocol = metadata.source == .anthropicMessages
            startUsage = metadata.usage
            startExtra = metadata.extra
            if !sameProtocol, !metadata.extra.isEmpty {
                discardExtra(metadata.extra, path: "", warnings: &warnings)
            }
            ensureStarted(into: &output)

        case .ping:
            if started {
                output.append(Self.event("ping", ["type": "ping"]))
            } else {
                output.append(.comment("ping"))
            }

        case .error(let error):
            flushAll(into: &output)
            var object = JSONObject()
            if sameProtocol, case .object(let raw)? = error.raw {
                object = raw
            } else {
                object["type"] = .string(error.type ?? "api_error")
                object["message"] = .string(error.message)
            }
            output.append(Self.event("error", ["type": "error", "error": .object(object)]))
            errored = true

        case .finish(let finish):
            output += finishEvents(finish)

        case .textStart(let block, _), .reasoningStart(let block, _), .refusalStart(let block, _),
             .toolInputStart(let block, _):
            if case .toolInputStart = event { streamedTools.insert(block) }
            if live == nil, waiting.isEmpty {
                write(event, into: &output)
            } else {
                waiting.append((block, [event]))
            }

        case .textDelta(let block, _), .textEnd(let block, _), .reasoningDelta(let block, _),
             .reasoningSignatureDelta(let block, _), .reasoningEnd(let block, _), .refusalDelta(let block, _),
             .refusalEnd(let block, _), .toolInputDelta(let block, _), .toolInputEnd(let block):
            if live?.block == block {
                write(event, into: &output)
                if live == nil { drain(into: &output) }
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
                write(event, into: &output)
            } else {
                waiting.append((nil, [event]))
            }
        }
        return output
    }

    /// End of input. Closes the message if no finish event did.
    package mutating func finish() -> [SSEElement] {
        guard !done else { return [] }
        return finishEvents(WireFinish())
    }

    // MARK: Scheduling

    /// Writes waiting blocks until one is still open.
    private mutating func drain(into output: inout [SSEElement]) {
        while live == nil, !waiting.isEmpty {
            let next = waiting.removeFirst()
            for event in next.events { write(event, into: &output) }
        }
    }

    /// Closes the live block and writes every waiting one, closing each.
    private mutating func flushAll(into output: inout [SSEElement]) {
        closeLive(into: &output)
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            for event in next.events { write(event, into: &output) }
            closeLive(into: &output)
        }
    }

    private mutating func closeLive(into output: inout [SSEElement]) {
        guard let current = live else { return }
        switch current.kind {
        case .text: write(.textEnd(id: current.block, text: nil), into: &output)
        case .reasoning: write(.reasoningEnd(id: current.block, reasoning: nil), into: &output)
        case .tool: write(.toolInputEnd(id: current.block), into: &output)
        }
    }

    private mutating func finishEvents(_ finish: WireFinish) -> [SSEElement] {
        var output: [SSEElement] = []
        defer { done = true }
        // An error event is the end of an Anthropic stream.
        guard !errored else { return output }
        ensureStarted(into: &output)
        flushAll(into: &output)
        var delta = JSONObject()
        delta["stop_reason"] = .string(AnthropicFinish.encode(finish.reason, sameProtocol: sameProtocol))
        if sameProtocol, let value = finish.extra["stop_sequence"] {
            delta["stop_sequence"] = value
        } else {
            delta["stop_sequence"] = .null
        }
        var extra = finish.extra
        if sameProtocol { extra["stop_sequence"] = nil }
        appendExtra(extra, to: &delta, include: sameProtocol, path: "delta", warnings: &warnings)
        // Message-delta usage is cumulative: the final counts, whole.
        let usage = AnthropicUsage.encode(finish.usage ?? startUsage, include: sameProtocol && (finish.usage ?? startUsage) != nil)
        output.append(Self.event("message_delta", ["type": "message_delta", "delta": .object(delta), "usage": usage]))
        output.append(Self.event("message_stop", ["type": "message_stop"]))
        return output
    }

    // MARK: Writing

    private mutating func ensureStarted(into output: inout [SSEElement]) {
        guard !started else { return }
        started = true
        var message = JSONObject()
        message["id"] = .string(id)
        message["type"] = "message"
        message["role"] = "assistant"
        message["model"] = .string(model)
        message["content"] = []
        message["stop_reason"] = .null
        message["stop_sequence"] = .null
        message["usage"] = AnthropicUsage.encode(startUsage, include: sameProtocol && startUsage != nil)
        if sameProtocol {
            appendExtra(startExtra, to: &message, include: true, path: "message", warnings: &warnings)
        }
        output.append(Self.event("message_start", ["type": "message_start", "message": .object(message)]))
    }

    /// Writes one event whose block is (or becomes) the live block, or a
    /// whole event when no block is live.
    private mutating func write(_ event: WireEvent, into output: inout [SSEElement]) {
        ensureStarted(into: &output)
        switch event {
        case .textStart(let block, let text):
            var object: JSONObject = ["type": "text", "text": ""]
            if text.signature != nil { dropOnce("text-signature", "text signature cannot be carried by Anthropic") }
            appendExtra(text.extra, to: &object, include: sameProtocol, path: "content_block", warnings: &warnings)
            live = Live(block: block, kind: .text)
            open(object, into: &output)

        case .refusalStart(let block, _):
            if warned.insert("refusal").inserted {
                warnings.append(WireWarning(.lossyConversion, "refusal sent as a text block"))
            }
            live = Live(block: block, kind: .text)
            open(["type": "text", "text": ""], into: &output)

        case .textDelta(_, let delta), .refusalDelta(_, let delta):
            if !delta.isEmpty { self.delta(["type": "text_delta", "text": .string(delta)], into: &output) }

        case .textEnd(_, let text):
            if let text {
                if text.signature != nil { dropOnce("text-signature", "text signature cannot be carried by Anthropic") }
                var late = text.extra
                if sameProtocol, case .array(let citations)? = late.removeValue(forKey: "citations") {
                    for citation in citations {
                        self.delta(["type": "citations_delta", "citation": citation], into: &output)
                    }
                }
                if !late.isEmpty {
                    discardExtra(late, path: "content_block", warnings: &warnings)
                }
            }
            close(into: &output)

        case .refusalEnd:
            close(into: &output)

        case .reasoningStart(let block, let reasoning):
            var current = Live(block: block, kind: .reasoning)
            current.accepted = AnthropicReplay.accepts(reasoning, sameProtocol: sameProtocol, trusted: trusted)
            if current.accepted, let data = reasoning.encrypted {
                current.redacted = true
                current.startObject = ["type": "redacted_thinking", "data": .string(data)]
            } else {
                current.startObject = ["type": "thinking", "thinking": "", "signature": .string(current.accepted ? reasoning.signature ?? "" : "")]
                if !current.accepted, reasoning.hasSignedData { dropFidelity() }
            }
            appendExtra(reasoning.extra, to: &current.startObject, include: sameProtocol, path: "content_block", warnings: &warnings)
            live = current
            // Redacted data and an early signature are content in themselves.
            if current.redacted || (current.accepted && reasoning.signature != nil) {
                openLive(into: &output)
            }

        case .reasoningDelta(_, let delta):
            guard !delta.isEmpty else { break }
            if live?.redacted == true {
                dropOnce("redacted-text", "reasoning text beside redacted data cannot be carried")
                break
            }
            openLive(into: &output)
            self.delta(["type": "thinking_delta", "thinking": .string(delta)], into: &output)

        case .reasoningSignatureDelta(_, let delta):
            guard live?.accepted == true, live?.redacted == false else {
                dropFidelity()
                break
            }
            openLive(into: &output)
            self.delta(["type": "signature_delta", "signature": .string(delta)], into: &output)

        case .reasoningEnd(_, let reasoning):
            if let reasoning {
                if live?.accepted == true, live?.redacted == false, let signature = reasoning.signature {
                    openLive(into: &output)
                    self.delta(["type": "signature_delta", "signature": .string(signature)], into: &output)
                } else if reasoning.signature != nil || reasoning.encrypted != nil {
                    dropFidelity()
                }
            }
            close(into: &output)

        case .toolInputStart(let block, let call):
            live = Live(block: block, kind: .tool)
            open(toolStart(call), into: &output)

        case .toolInputDelta(_, let delta):
            guard !delta.isEmpty else { break }
            live?.sentInput = true
            self.delta(["type": "input_json_delta", "partial_json": .string(delta)], into: &output)

        case .toolInputEnd:
            if live?.sentInput == false {
                self.delta(["type": "input_json_delta", "partial_json": "{}"], into: &output)
            }
            close(into: &output)

        case .toolCall(let block, let call):
            live = Live(block: block, kind: .tool)
            open(toolStart(call), into: &output)
            let input = call.arguments.trimmingASCIIWhitespace().isEmpty ? "{}" : call.arguments
            self.delta(["type": "input_json_delta", "partial_json": .string(input)], into: &output)
            close(into: &output)

        case .opaque(let opaque):
            guard opaque.protocol == .anthropicMessages, case .object(var block) = opaque.value else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) stream content cannot be carried by Anthropic"))
                break
            }
            let type = block["type"]?.stringValue ?? ""
            var input: JSONValue?
            if type.hasSuffix("tool_use"), case .object(let object)? = block["input"], !object.isEmpty {
                input = block["input"]
                block["input"] = .object([:])
            }
            live = Live(block: "", kind: .text)
            open(block, into: &output)
            if let input {
                self.delta(["type": "input_json_delta", "partial_json": .string(input.description)], into: &output)
            }
            close(into: &output)

        case .responseMetadata, .ping, .error, .finish:
            break
        }
    }

    private mutating func toolStart(_ call: WireToolCall) -> JSONObject {
        var object: JSONObject = ["type": "tool_use", "id": .string(AnthropicToolID.outbound(call.id)), "name": .string(call.name), "input": [:]]
        if call.signature != nil { dropOnce("tool-signature", "tool call signature cannot be carried by Anthropic") }
        if let itemType = call.itemType {
            warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a tool_use block"))
        }
        appendExtra(call.extra, to: &object, include: sameProtocol, path: "content_block", warnings: &warnings)
        return object
    }

    /// Opens the live block with `object`.
    private mutating func open(_ object: JSONObject, into output: inout [SSEElement]) {
        live?.startObject = object
        openLive(into: &output)
    }

    /// Opens the live block with its start object, unless already open.
    private mutating func openLive(into output: inout [SSEElement]) {
        guard var current = live, current.index == nil else { return }
        current.index = nextIndex
        nextIndex += 1
        live = current
        output.append(Self.event("content_block_start", [
            "type": "content_block_start", "index": .number(JSONNumber(nextIndex - 1)),
            "content_block": .object(current.startObject),
        ]))
    }

    private mutating func delta(_ delta: JSONObject, into output: inout [SSEElement]) {
        guard let index = live?.index else { return }
        output.append(Self.event("content_block_delta", [
            "type": "content_block_delta", "index": .number(JSONNumber(index)), "delta": .object(delta),
        ]))
    }

    /// Stops the live block (if it was ever opened) and clears it.
    private mutating func close(into output: inout [SSEElement]) {
        if let index = live?.index {
            output.append(Self.event("content_block_stop", ["type": "content_block_stop", "index": .number(JSONNumber(index))]))
        }
        live = nil
    }

    private mutating func dropFidelity() {
        dropOnce("fidelity", "reasoning signature/encrypted data from another system cannot be carried by Anthropic")
    }

    private mutating func dropOnce(_ key: String, _ message: String) {
        if warned.insert(key).inserted { warnings.append(WireWarning(.droppedContent, message)) }
    }

    private mutating func warnOnce(_ key: String, _ warning: WireWarning) {
        if warned.insert(key).inserted { warnings.append(warning) }
    }

    private static func event(_ name: String, _ object: JSONObject) -> SSEElement {
        .event(SSEEvent(event: name, data: String(decoding: JSONValue.object(object).encoded(), as: UTF8.self)))
    }
}
