/// Decodes an Anthropic Messages SSE stream into block-structured wire events.
///
/// Handles:
/// - `message_start` → ``WireEvent/responseMetadata(_:)`` with the early
///   usage; unknown keys of the message go to its bag;
/// - `content_block_start`/`delta`/`stop` for `text` (`text_delta`;
///   `citations_delta` is collected and delivered in the block's
///   ``WireEvent/textEnd(id:text:)`` bag as the full `citations` array, as a
///   non-streaming reply has it), `thinking` (`thinking_delta`,
///   `signature_delta`), `redacted_thinking` (its `data` arrives at start)
///   and `tool_use` (`input_json_delta`; a tool whose start already carries a
///   non-empty `input`, as some relays send, keeps that input and ignores
///   deltas; one that receives no input gets a `{}` delta, so its arguments
///   match a non-streaming reply's);
/// - any other block (server tools and their results) is collected whole,
///   with its `input_json_delta`s parsed into `input`, and emitted as one
///   ``WireEvent/opaque(_:)`` at its stop;
/// - `message_delta`: `stop_reason` becomes the finish reason; the other
///   keys of `delta` (`stop_sequence`, `stop_details`) go to
///   ``WireFinish/extra``; its usage is overlaid on `message_start`'s, so the
///   finish usage is complete;
/// - `message_stop` → ``WireEvent/finish(_:)``;
/// - `ping` and SSE comments → ``WireEvent/ping``;
/// - `error` events → ``WireEvent/error(_:)`` (the finish then has reason
///   ``WireFinishReason/Unified/error``);
/// - a stream cut short (see ``finish()``) → ``WireEvent/error(_:)`` too.
///
/// The event type is read from the JSON `type`, falling back to the SSE
/// `event` name.
@_spi(Wire) public struct AnthropicMessagesStreamDecoder: WireStreamDecoder {
    /// System id stamped on every reasoning block.
    public var origin: WireSystemID?
    public private(set) var warnings: [WireWarning] = []

    private enum Kind: Sendable {
        case text(citations: [JSONValue])
        case reasoning
        case tool(call: WireToolCall, whole: Bool)
        case opaque(block: JSONObject, input: String)
    }

    private struct Block: Sendable {
        var id: String
        var kind: Kind
    }

    private var started = false
    private var done = false
    private var errored = false
    private var nextBlock = 0
    private var blocks: [Int: Block] = [:]
    private var startUsage: JSONObject?
    private var deltaUsage: JSONObject?
    private var finishReason: WireFinishReason?
    private var finishExtra: JSONObject = [:]
    private var warned: Set<String> = []

    private static let knownMessageKeys: Set<String> = [
        "id", "type", "role", "model", "content", "stop_reason", "stop_sequence", "usage",
    ]

    public init(origin: WireSystemID? = "anthropic") {
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
            warnOnce("after-stop", WireWarning(.malformedStream, "data after message_stop ignored"))
            return []
        }
        if event.data.trimmingASCIIWhitespace().isEmpty { return event.event == "ping" ? [.ping] : [] }
        let json = try JSONValue.parseWire(Array(event.data.utf8))
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        let type = object["type"]?.stringValue ?? event.event ?? ""
        var events: [WireEvent] = []
        switch type {
        case "message_start":
            messageStart(object["message"]?.objectValue ?? [:], into: &events)
        case "content_block_start":
            ensureStarted(into: &events)
            blockStart(object, into: &events)
        case "content_block_delta":
            blockDelta(object, into: &events)
        case "content_block_stop":
            if let index = object["index"]?.numberValue?.int { blockStop(index, into: &events) }
        case "message_delta":
            if case .object(let delta)? = object["delta"] {
                for (key, value) in delta {
                    if key == "stop_reason" {
                        if case .string(let reason) = value { finishReason = AnthropicFinish.decode(reason) }
                    } else {
                        finishExtra[key] = value
                    }
                }
            }
            if case .object(let usage)? = object["usage"] {
                var merged = deltaUsage ?? [:]
                for (key, value) in usage { merged[key] = value }
                deltaUsage = merged
            }
        case "message_stop":
            ensureStarted(into: &events)
            events += finishEvents()
        case "ping":
            events.append(.ping)
        case "error":
            closeAll(into: &events)
            events.append(.error(AnthropicDecode.streamError(object["error"])))
            errored = true
            if finishReason == nil { finishReason = WireFinishReason(.error) }
        default:
            warnOnce("event.\(type)", WireWarning(.droppedContent, "stream event `\(type)` is not carried"))
        }
        return events
    }

    /// Ends the stream: closes open blocks and emits the finish event, unless
    /// `message_stop` already did. A stream that started and ends without
    /// `message_stop` gets a warning; if it had no `stop_reason` either (and
    /// no error event), it was cut short: an ``WireEvent/error(_:)``
    /// precedes the finish, whose reason is then
    /// ``WireFinishReason/Unified/error``. (A `stop_reason` means the reply
    /// is complete; only the closing event went missing.)
    public mutating func finish() -> [WireEvent] {
        guard !done else { return [] }
        var events: [WireEvent] = []
        if started, !errored {
            warnings.append(WireWarning(.malformedStream, "stream ended without message_stop"))
            if finishReason == nil {
                closeAll(into: &events)
                events.append(.error(.endedEarly(missing: "message_stop")))
                errored = true
                finishReason = WireFinishReason(.error)
            }
        }
        return events + finishEvents()
    }

    // MARK: Internals

    private mutating func finishEvents() -> [WireEvent] {
        var events: [WireEvent] = []
        closeAll(into: &events)
        done = true
        var usage: WireUsage?
        if startUsage != nil || deltaUsage != nil {
            var merged = startUsage ?? [:]
            for (key, value) in deltaUsage ?? [:] { merged[key] = value }
            usage = try? AnthropicUsage.decode(merged, path: "usage")
        }
        events.append(.finish(WireFinish(reason: finishReason, usage: usage, extra: finishExtra)))
        return events
    }

    private mutating func messageStart(_ message: JSONObject, into events: inout [WireEvent]) {
        guard !started else {
            warnOnce("start-twice", WireWarning(.malformedStream, "second message_start ignored"))
            return
        }
        started = true
        var metadata = WireResponseMetadata(source: .anthropicMessages)
        metadata.id = message["id"]?.stringValue
        metadata.model = message["model"]?.stringValue
        if case .object(let usage)? = message["usage"] {
            startUsage = usage
            metadata.usage = try? AnthropicUsage.decode(usage, path: "message.usage")
        }
        for (key, value) in message where !Self.knownMessageKeys.contains(key) {
            metadata.extra[key] = value
        }
        if case .array(let content)? = message["content"], !content.isEmpty {
            warnings.append(WireWarning(.droppedContent, "content in message_start is not carried", path: "message.content"))
        }
        events.append(.responseMetadata(metadata))
    }

    /// A relay that skips `message_start` still gets metadata first.
    private mutating func ensureStarted(into events: inout [WireEvent]) {
        guard !started else { return }
        started = true
        warnings.append(WireWarning(.malformedStream, "stream did not begin with message_start"))
        events.append(.responseMetadata(WireResponseMetadata(source: .anthropicMessages)))
    }

    private mutating func newBlock(_ prefix: String) -> String {
        defer { nextBlock += 1 }
        return "\(prefix)-\(nextBlock)"
    }

    private mutating func blockStart(_ event: JSONObject, into events: inout [WireEvent]) {
        guard let index = event["index"]?.numberValue?.int, case .object(let block)? = event["content_block"] else {
            warnings.append(WireWarning(.malformedStream, "content_block_start without index or block"))
            return
        }
        if blocks[index] != nil {
            warnings.append(WireWarning(.malformedStream, "block \(index) started twice"))
            blockStop(index, into: &events)
        }
        var extra = block
        extra["type"] = nil
        switch block["type"]?.stringValue {
        case "text":
            let text = block["text"]?.stringValue ?? ""
            extra["text"] = nil
            let id = newBlock("text")
            blocks[index] = Block(id: id, kind: .text(citations: []))
            events.append(.textStart(id: id, text: WireText("", extra: extra)))
            if !text.isEmpty { events.append(.textDelta(id: id, delta: text)) }

        case "thinking":
            let text = block["thinking"]?.stringValue ?? ""
            let signature = block["signature"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            extra["thinking"] = nil
            extra["signature"] = nil
            let id = newBlock("reasoning")
            blocks[index] = Block(id: id, kind: .reasoning)
            events.append(.reasoningStart(id: id, reasoning: WireReasoning(
                text: "", signature: signature, origin: origin, extra: extra,
            )))
            if !text.isEmpty { events.append(.reasoningDelta(id: id, delta: text)) }

        case "redacted_thinking":
            extra["data"] = nil
            let id = newBlock("reasoning")
            blocks[index] = Block(id: id, kind: .reasoning)
            events.append(.reasoningStart(id: id, reasoning: WireReasoning(
                text: "", encrypted: block["data"]?.stringValue ?? "", origin: origin, extra: extra,
            )))

        case "tool_use":
            extra["id"] = nil
            extra["name"] = nil
            extra["input"] = nil
            let call = WireToolCall(
                id: AnthropicToolID.inbound(block["id"]?.stringValue ?? ""), name: block["name"]?.stringValue ?? "", arguments: "", extra: extra,
            )
            let id = newBlock("tool")
            events.append(.toolInputStart(id: id, call: call))
            var whole = false
            var current = call
            if case .object(let input)? = block["input"], !input.isEmpty {
                // A relay that sends the whole input at start.
                whole = true
                current.arguments = String(decoding: JSONValue.object(input).encoded(), as: UTF8.self)
                events.append(.toolInputDelta(id: id, delta: current.arguments))
            }
            blocks[index] = Block(id: id, kind: .tool(call: current, whole: whole))

        default:
            blocks[index] = Block(id: newBlock("opaque"), kind: .opaque(block: block, input: ""))
        }
    }

    private mutating func blockDelta(_ event: JSONObject, into events: inout [WireEvent]) {
        guard let index = event["index"]?.numberValue?.int, var block = blocks[index],
              case .object(let delta)? = event["delta"] else {
            warnOnce("orphan-delta", WireWarning(.malformedStream, "content_block_delta for a block that is not open"))
            return
        }
        let type = delta["type"]?.stringValue ?? ""
        switch (type, block.kind) {
        case ("text_delta", .text):
            if case .string(let text)? = delta["text"], !text.isEmpty { events.append(.textDelta(id: block.id, delta: text)) }
        case ("citations_delta", .text(var citations)):
            if let citation = delta["citation"] { citations.append(citation) }
            block.kind = .text(citations: citations)
        case ("thinking_delta", .reasoning):
            if case .string(let text)? = delta["thinking"], !text.isEmpty { events.append(.reasoningDelta(id: block.id, delta: text)) }
        case ("signature_delta", .reasoning):
            if case .string(let text)? = delta["signature"], !text.isEmpty {
                events.append(.reasoningSignatureDelta(id: block.id, delta: text))
            }
        case ("input_json_delta", .tool(var call, let whole)):
            if !whole, case .string(let text)? = delta["partial_json"], !text.isEmpty {
                call.arguments += text
                events.append(.toolInputDelta(id: block.id, delta: text))
                block.kind = .tool(call: call, whole: whole)
            }
        case ("input_json_delta", .opaque(let value, var input)):
            if case .string(let text)? = delta["partial_json"] { input += text }
            block.kind = .opaque(block: value, input: input)
        default:
            warnOnce("delta.\(type)", WireWarning(.droppedContent, "content delta `\(type)` is not carried"))
        }
        blocks[index] = block
    }

    private mutating func blockStop(_ index: Int, into events: inout [WireEvent]) {
        guard let block = blocks.removeValue(forKey: index) else {
            warnOnce("orphan-stop", WireWarning(.malformedStream, "content_block_stop for a block that is not open"))
            return
        }
        switch block.kind {
        case .text(let citations):
            let late = citations.isEmpty ? nil : WireText("", extra: ["citations": .array(citations)])
            events.append(.textEnd(id: block.id, text: late))
        case .reasoning:
            events.append(.reasoningEnd(id: block.id, reasoning: nil))
        case .tool(var call, _):
            if call.arguments.isEmpty {
                call.arguments = "{}"
                events.append(.toolInputDelta(id: block.id, delta: "{}"))
            }
            events.append(.toolInputEnd(id: block.id))
            events.append(.toolCall(id: block.id, call: call))
        case .opaque(var value, let input):
            if !input.trimmingASCIIWhitespace().isEmpty {
                if let parsed = try? JSONValue(parsing: input) {
                    value["input"] = parsed
                } else {
                    warnings.append(WireWarning(.malformedStream, "invalid input JSON of a `\(value["type"]?.stringValue ?? "")` block"))
                }
            }
            events.append(.opaque(WireOpaque(protocol: .anthropicMessages, value: .object(value))))
        }
    }

    private mutating func closeAll(into events: inout [WireEvent]) {
        for index in blocks.keys.sorted() {
            blockStop(index, into: &events)
        }
    }

    private mutating func warnOnce(_ key: String, _ warning: WireWarning) {
        if warned.insert(key).inserted { warnings.append(warning) }
    }
}
