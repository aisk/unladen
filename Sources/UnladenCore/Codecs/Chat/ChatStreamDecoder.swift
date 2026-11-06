/// Decodes a Chat Completions SSE stream into block-structured wire events.
///
/// Handles:
/// - `data: [DONE]` (emits ``WireEvent/finish(_:)``);
/// - tool-call fragments interleaved by `index` (each index is its own
///   block; a new `id` on a known index starts a new call, as some relays
///   reuse indices); a call's block starts once its name is known;
/// - `reasoning_content` (DeepSeek) and `reasoning` (OpenRouter) deltas;
/// - `refusal` deltas;
/// - the usage-only final chunk of `stream_options.include_usage` (and
///   usage on any chunk; the last one wins);
/// - `finish_reason` (closes all open blocks; the finish event itself waits
///   for `[DONE]` or ``finish()`` so it can carry the usage; unknown keys of
///   that choice, e.g. OpenRouter `native_finish_reason`, go to
///   ``WireFinish/extra``). Content after it is still decoded, with a warning;
/// - tool-call fragments without `index` (their position in the array is used)
///   and without `id` (a position-based id is synthesized, marked as such);
/// - in-stream `{"error": …}` objects;
/// - SSE comments as ``WireEvent/ping``.
///
/// Only the first choice index seen is followed; others produce a warning.
@_spi(Wire) public struct ChatCompletionsStreamDecoder: WireStreamDecoder {
    /// System id stamped on fidelity data (reserved; plain Chat has none).
    public var origin: WireSystemID?
    public private(set) var warnings: [WireWarning] = []

    private enum TextKind: Hashable, Sendable { case text, reasoning, refusal }

    private struct ToolState: Sendable {
        var block: String
        var index: Int
        var id: String?
        var name: String
        var extra: JSONObject
        /// Set once started; holds the arguments received so far.
        var call: WireToolCall?
        var bufferedArguments: String
        var ended: Bool
    }

    private var started = false
    private var done = false
    private var choiceIndex: Int?
    private var nextBlock = 0
    private var open: (kind: TextKind, block: String, sourceKey: String?)?
    private var tools: [ToolState] = []
    private var toolByIndex: [Int: Int] = [:]
    private var finishReason: WireFinishReason?
    private var finishExtra: JSONObject = [:]
    private var usage: WireUsage?
    private var warned: Set<String> = []

    private static let knownDeltaKeys = Set(["role", "content", "refusal", "tool_calls"] + chatReasoningKeys)
    private static let knownChoiceKeys: Set<String> = ["index", "delta", "finish_reason", "logprobs"]
    private static let knownChunkKeys: Set<String> = ["id", "object", "created", "model", "choices", "usage"]

    public init(origin: WireSystemID? = nil) {
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
            warnOnce("after-done", WireWarning(.malformedStream, "data after [DONE] ignored"))
            return []
        }
        let data = event.data
        if data.trimmingASCIIWhitespace() == "[DONE]" { return finishEvents() }
        if data.trimmingASCIIWhitespace().isEmpty { return [] }

        let json = try JSONValue.parseWire(Array(data.utf8))
        guard case .object(let chunk) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var events: [WireEvent] = []

        if let error = chunk["error"], !error.isNull {
            closeAll(into: &events)
            events.append(.error(Self.streamError(error)))
            if finishReason == nil { finishReason = WireFinishReason(.error) }
            return events
        }

        if !started {
            started = true
            var metadata = WireResponseMetadata(source: .chatCompletions)
            metadata.id = chunk["id"]?.stringValue
            metadata.model = chunk["model"]?.stringValue
            metadata.created = chunk["created"]?.numberValue?.int
            for (key, value) in chunk where !Self.knownChunkKeys.contains(key) {
                metadata.extra[key] = value
            }
            events.append(.responseMetadata(metadata))
        }

        if case .array(let choices)? = chunk["choices"] {
            for (position, choiceValue) in choices.enumerated() {
                guard case .object(let choice) = choiceValue else { continue }
                let index = choice["index"]?.numberValue?.int ?? position
                if let locked = choiceIndex, locked != index {
                    warnOnce("choice", WireWarning(.droppedContent, "only the first choice of a stream is kept", path: "choices"))
                    continue
                }
                choiceIndex = index
                let finishing = choice["finish_reason"]?.stringValue
                for (key, value) in choice where !Self.knownChoiceKeys.contains(key) && !value.isNull {
                    if finishing != nil {
                        finishExtra[key] = value
                    } else {
                        warnOnce("choice.\(key)", WireWarning(.droppedField, "stream choice field `\(key)` is not carried", path: "choices[].\(key)"))
                    }
                }
                if case .object(let delta)? = choice["delta"] {
                    let before = events.count
                    decodeDelta(delta, into: &events)
                    if finishReason != nil, events.count > before {
                        warnOnce("after-finish", WireWarning(.malformedStream, "content after finish_reason"))
                    }
                }
                if let finishing {
                    closeAll(into: &events)
                    finishReason = ChatFinish.decode(finishing)
                }
            }
        }

        if case .object(let usageObject)? = chunk["usage"] {
            usage = try ChatUsage.decode(usageObject, path: "usage")
        }
        return events
    }

    /// Ends the stream: closes open blocks and emits the finish event, unless
    /// `[DONE]` already did. A stream without `[DONE]` gets a warning.
    public mutating func finish() -> [WireEvent] {
        guard !done else { return [] }
        if started {
            warnings.append(WireWarning(.malformedStream, "stream ended without [DONE]"))
        }
        return finishEvents()
    }

    // MARK: Internals

    private mutating func finishEvents() -> [WireEvent] {
        var events: [WireEvent] = []
        closeAll(into: &events)
        done = true
        events.append(.finish(WireFinish(reason: finishReason, usage: usage, extra: finishExtra)))
        return events
    }

    private mutating func newBlock(_ prefix: String) -> String {
        defer { nextBlock += 1 }
        return "\(prefix)-\(nextBlock)"
    }

    private mutating func decodeDelta(_ delta: JSONObject, into events: inout [WireEvent]) {
        // Some relays send the same thought under both names; take one.
        for key in chatReasoningKeys {
            if case .string(let text)? = delta[key] {
                if !text.isEmpty { appendText(.reasoning, text, sourceKey: key, into: &events) }
                break
            }
        }
        switch delta["content"] {
        case .string(let text)?:
            if !text.isEmpty { appendText(.text, text, sourceKey: nil, into: &events) }
        case .array?:
            warnOnce("content-array", WireWarning(.unsupportedValue, "array content in a stream delta is not carried", path: "choices[].delta.content"))
        default:
            break
        }
        if case .string(let text)? = delta["refusal"], !text.isEmpty {
            appendText(.refusal, text, sourceKey: nil, into: &events)
        }
        if case .array(let calls)? = delta["tool_calls"] {
            closeOpen(into: &events)
            for (position, call) in calls.enumerated() {
                if case .object(let fragment) = call {
                    toolFragment(fragment, position: position, into: &events)
                }
            }
        }
        for (key, value) in delta where !Self.knownDeltaKeys.contains(key) && !value.isNull {
            warnOnce("delta.\(key)", WireWarning(.droppedField, "stream delta field `\(key)` is not carried", path: "choices[].delta.\(key)"))
        }
    }

    private mutating func appendText(_ kind: TextKind, _ text: String, sourceKey: String?, into events: inout [WireEvent]) {
        if let open, open.kind == kind, open.sourceKey == sourceKey {
            events.append(Self.delta(kind, open.block, text))
            return
        }
        closeOpen(into: &events)
        let block: String
        switch kind {
        case .text:
            block = newBlock("text")
            events.append(.textStart(id: block, text: WireText("")))
        case .reasoning:
            block = newBlock("reasoning")
            events.append(.reasoningStart(id: block, reasoning: WireReasoning(text: "", sourceKey: sourceKey)))
        case .refusal:
            block = newBlock("refusal")
            events.append(.refusalStart(id: block, refusal: WireRefusal("", sourceKey: "refusal")))
        }
        open = (kind, block, sourceKey)
        events.append(Self.delta(kind, block, text))
    }

    private static func delta(_ kind: TextKind, _ block: String, _ text: String) -> WireEvent {
        switch kind {
        case .text: .textDelta(id: block, delta: text)
        case .reasoning: .reasoningDelta(id: block, delta: text)
        case .refusal: .refusalDelta(id: block, delta: text)
        }
    }

    private mutating func closeOpen(into events: inout [WireEvent]) {
        guard let current = open else { return }
        open = nil
        switch current.kind {
        case .text: events.append(.textEnd(id: current.block, text: nil))
        case .reasoning: events.append(.reasoningEnd(id: current.block, reasoning: nil))
        case .refusal: events.append(.refusalEnd(id: current.block, refusal: nil))
        }
    }

    private mutating func toolFragment(_ fragment: JSONObject, position: Int, into events: inout [WireEvent]) {
        let index = fragment["index"]?.numberValue?.int ?? position
        let id = fragment["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let function = fragment["function"]?.objectValue
        let name = function?["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let arguments = function?["arguments"]?.stringValue ?? ""

        if let slot = toolByIndex[index], !tools[slot].ended,
           id == nil || tools[slot].id == nil || id == tools[slot].id
        {
            if tools[slot].call != nil {
                if !arguments.isEmpty {
                    tools[slot].call?.arguments += arguments
                    events.append(.toolInputDelta(id: tools[slot].block, delta: arguments))
                }
            } else {
                if tools[slot].id == nil { tools[slot].id = id }
                if let name { tools[slot].name = name }
                tools[slot].bufferedArguments += arguments
                if !tools[slot].name.isEmpty { startTool(slot, into: &events) }
            }
            return
        }

        // A new call (new index, or a new id on a reused index).
        if let slot = toolByIndex[index], !tools[slot].ended {
            endTool(slot, into: &events)
        }
        var extra = JSONObject()
        for (key, value) in fragment where !["index", "id", "type", "function"].contains(key) {
            extra[key] = value
        }
        tools.append(ToolState(
            block: newBlock("tool"), index: index, id: id, name: name ?? "", extra: extra,
            call: nil, bufferedArguments: arguments, ended: false,
        ))
        toolByIndex[index] = tools.count - 1
        if name != nil { startTool(tools.count - 1, into: &events) }
    }

    private mutating func startTool(_ slot: Int, into events: inout [WireEvent]) {
        let state = tools[slot]
        // Chat requires ids; a relay that sends none gets a position-based one.
        let id = state.id ?? "call_\(state.block)"
        if state.id == nil {
            warnings.append(WireWarning(.malformedStream, "tool call at index \(state.index) has no id; using `\(id)`"))
        }
        var call = WireToolCall(id: id, idSynthesized: state.id == nil, name: state.name, arguments: "", extra: state.extra)
        events.append(.toolInputStart(id: state.block, call: call))
        if !state.bufferedArguments.isEmpty {
            events.append(.toolInputDelta(id: state.block, delta: state.bufferedArguments))
        }
        call.arguments = state.bufferedArguments
        tools[slot].call = call
        tools[slot].bufferedArguments = ""
    }

    private mutating func endTool(_ slot: Int, into events: inout [WireEvent]) {
        if tools[slot].call == nil {
            warnings.append(WireWarning(.malformedStream, "tool call at index \(tools[slot].index) never received a name"))
            startTool(slot, into: &events)
        }
        tools[slot].ended = true
        let block = tools[slot].block
        events.append(.toolInputEnd(id: block))
        if let call = tools[slot].call {
            events.append(.toolCall(id: block, call: call))
        }
    }

    private mutating func closeAll(into events: inout [WireEvent]) {
        closeOpen(into: &events)
        for slot in tools.indices where !tools[slot].ended {
            endTool(slot, into: &events)
        }
    }

    private mutating func warnOnce(_ key: String, _ warning: WireWarning) {
        if warned.insert(key).inserted { warnings.append(warning) }
    }

    static func streamError(_ value: JSONValue) -> WireStreamError {
        switch value {
        case .string(let message):
            return WireStreamError(message: message, raw: value)
        case .object(let object):
            let code: String? = switch object["code"] {
            case .string(let text)?: text
            case .number(let number)?: number.literal
            default: nil
            }
            return WireStreamError(
                message: object["message"]?.stringValue ?? "",
                type: object["type"]?.stringValue,
                code: code,
                raw: value,
            )
        default:
            return WireStreamError(message: value.description, raw: value)
        }
    }
}

extension String {
    func trimmingASCIIWhitespace() -> Substring {
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard let first = firstIndex(where: { !isSpace($0) }), let last = lastIndex(where: { !isSpace($0) }) else {
            return ""
        }
        return self[first...last]
    }
}
