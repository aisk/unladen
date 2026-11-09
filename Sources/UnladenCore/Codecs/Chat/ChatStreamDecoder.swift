/// Decodes a Chat Completions SSE stream into block-structured wire events.
///
/// Handles:
/// - `data: [DONE]` (emits ``WireEvent/finish(_:)``);
/// - tool-call fragments interleaved by `index` (each index is its own
///   block; a new `id` on a known index starts a new call, as some relays
///   reuse indices); a call's block starts once its name is known. A call
///   ends at index reuse, at `finish_reason`, or when answer text follows
///   (fragments for it after that are dropped with a warning). Parallel
///   calls are otherwise left open until the end: a fragment for a new
///   index does not prove the previous call complete;
/// - `reasoning_content` (DeepSeek) and `reasoning` (OpenRouter) deltas;
/// - OpenRouter `reasoning_details` (see ``ChatReasoningDetails``): each
///   entry (`type` and `index`) is one reasoning block, its fragments
///   appended, its signature and encrypted data typed with ``origin``; the
///   plain `reasoning` text sent beside them is not read twice;
/// - Gemini's `extra_content` (see ``ChatGemini``): `google.thought` makes
///   the delta's `content` a reasoning block, `google.thought_signature`
///   signs the open text or reasoning block and ends it (as Gemini signs a
///   part with its last chunk; with no block open, an empty text block is
///   signed); the rest stays in the block's bag;
/// - Mistral typed content parts (`text`, `thinking`; see ``ChatMistral``);
/// - `refusal` deltas;
/// - the usage-only final chunk of `stream_options.include_usage` (and
///   usage on any chunk; the last one wins);
/// - `finish_reason` (closes all open blocks; the finish event itself waits
///   for `[DONE]` or ``finish()`` so it can carry the usage; unknown keys of
///   that choice, e.g. OpenRouter `native_finish_reason`, go to
///   ``WireFinish/extra``). Content after it is still decoded, with a warning;
/// - tool-call fragments without `index` (their position in the array is used)
///   and without `id` (a position-based id is synthesized, marked as such);
/// - in-stream `{"error": …}` objects, and a stream cut short (see
///   ``finish()``), as ``WireEvent/error(_:)``;
/// - SSE comments as ``WireEvent/ping``.
///
/// Only the first choice index seen is followed; others produce a warning.
@_spi(Wire) public struct ChatCompletionsStreamDecoder: WireStreamDecoder {
    /// System id stamped on fidelity data (Gemini's thought signatures,
    /// OpenRouter's `reasoning_details` signatures and encrypted data).
    public var origin: WireSystemID?
    public private(set) var warnings: [WireWarning] = []

    private enum TextKind: Hashable, Sendable { case text, reasoning, refusal }

    private struct ToolState: Sendable {
        var block: String
        var index: Int
        var id: String?
        var name: String
        var extra: JSONObject
        var signature: String?
        /// Set once started; holds the arguments received so far.
        var call: WireToolCall?
        var bufferedArguments: String
        var ended: Bool
    }

    private var started = false
    private var done = false
    private var choiceIndex: Int?
    private var nextBlock = 0
    /// The open text, reasoning or refusal block.
    private struct OpenBlock: Sendable {
        var kind: TextKind
        var block: String
        var sourceKey: String?
        /// The `reasoning_details` entry (`type#index`) this block holds.
        var detail: String?
        /// The entry's `type`, `format`, `index`… as the block started.
        var detailMeta: JSONObject = [:]
        /// Metadata for the end event.
        var signature: String?
        var encrypted: String?
        var extra: JSONObject = [:]
        var hasLate = false
        /// Stamped on the end metadata's signature or data.
        var origin: WireSystemID?
    }

    /// The open text, reasoning or refusal block (not a details entry).
    private var open: OpenBlock?
    /// Open `reasoning_details` blocks, in start order: entries may
    /// interleave by index, so each stays open until other content comes.
    private var details: [OpenBlock] = []
    /// Every details entry (`type#index`) that had a block.
    private var seenDetails: Set<String> = []
    private var tools: [ToolState] = []
    private var toolByIndex: [Int: Int] = [:]
    private var finishReason: WireFinishReason?
    private var finishExtra: JSONObject = [:]
    private var usage: WireUsage?
    private var warned: Set<String> = []

    private static let knownDeltaKeys = Set(["role", "content", "refusal", "tool_calls", ChatGemini.key, ChatReasoningDetails.key] + chatReasoningKeys)
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
    ///
    /// The terminal signal is a `finish_reason` (or an in-stream error), not
    /// `[DONE]`: several Chat-compatible upstreams never send `[DONE]`, and
    /// a reply with a finish reason is complete. A stream that started and
    /// ends without either was cut short: an ``WireEvent/error(_:)``
    /// precedes the finish, whose reason is ``WireFinishReason/Unified/error``.
    public mutating func finish() -> [WireEvent] {
        guard !done else { return [] }
        var events: [WireEvent] = []
        if started {
            warnings.append(WireWarning(.malformedStream, "stream ended without [DONE]"))
            if finishReason == nil {
                closeAll(into: &events)
                events.append(.error(.endedEarly(missing: "finish_reason")))
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
        events.append(.finish(WireFinish(reason: finishReason, usage: usage, extra: finishExtra)))
        return events
    }

    private mutating func newBlock(_ prefix: String) -> String {
        defer { nextBlock += 1 }
        return "\(prefix)-\(nextBlock)"
    }

    private mutating func decodeDelta(_ delta: JSONObject, into events: inout [WireEvent]) {
        let details = reasoningDetails(delta[ChatReasoningDetails.key])
        // Some relays send the same thought under both names; take one.
        // Details with text are the reasoning (as in non-streaming
        // replies); the plain field OpenRouter repeats it in is then only
        // its spelling.
        let detailsHaveText = ChatReasoningDetails.text(details) != nil
        var plainKey: String?
        for key in chatReasoningKeys {
            if case .string(let text)? = delta[key] {
                if !text.isEmpty {
                    if detailsHaveText {
                        plainKey = key
                    } else {
                        appendText(.reasoning, text, sourceKey: key, into: &events)
                    }
                }
                break
            }
        }
        for (position, entry) in details.enumerated() {
            appendDetail(entry, position: position, sourceKey: plainKey, into: &events)
        }
        let gemini = ChatGemini.split(delta[ChatGemini.key])
        switch delta["content"] {
        case .string(let text)?:
            if !text.isEmpty {
                if gemini.thought {
                    appendText(.reasoning, text, sourceKey: ChatGemini.thoughtSourceKey, into: &events)
                } else {
                    appendText(.text, text, sourceKey: nil, into: &events)
                }
            }
        case .array(let parts)?:
            // Mistral streams typed parts (Magistral, and GLM on
            // api.mistral.ai): text parts, and `thinking` parts that hold
            // the thought as a list of text parts.
            for part in parts {
                switch part["type"]?.stringValue {
                case "text":
                    if case .string(let text)? = part["text"], !text.isEmpty { appendText(.text, text, sourceKey: nil, into: &events) }
                case "thinking":
                    for inner in part["thinking"]?.arrayValue ?? [] where inner["type"] == "text" {
                        if case .string(let text)? = inner["text"], !text.isEmpty {
                            appendText(.reasoning, text, sourceKey: ChatMistral.thinkingSourceKey, into: &events)
                        }
                    }
                default:
                    warnOnce("content-array", WireWarning(.unsupportedValue, "a stream delta content part other than text or thinking is not carried", path: "choices[].delta.content"))
                }
            }
        default:
            break
        }
        if gemini.signature != nil || gemini.rest != nil {
            signOpen(gemini, into: &events)
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
        if kind == .text {
            // Answer text after tool calls means they are complete; ending
            // them now lets encoders that write one block at a time
            // (Anthropic, Responses) stop buffering them.
            for slot in tools.indices where !tools[slot].ended {
                endTool(slot, into: &events)
            }
        }
        if let open, open.kind == kind, open.sourceKey == sourceKey, open.detail == nil {
            events.append(Self.delta(kind, open.block, text))
            return
        }
        closeOpen(into: &events)
        let block = startBlock(kind, sourceKey: sourceKey, into: &events)
        events.append(Self.delta(kind, block, text))
    }

    /// Starts a block (the open one must be closed) and returns its id.
    private mutating func startBlock(_ kind: TextKind, sourceKey: String?, into events: inout [WireEvent]) -> String {
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
        open = OpenBlock(kind: kind, block: block, sourceKey: sourceKey, origin: origin)
        return block
    }

    /// The readable entries of a delta's `reasoning_details`.
    private mutating func reasoningDetails(_ value: JSONValue?) -> [ChatReasoningDetails.Entry] {
        switch value {
        case nil, .null?:
            return []
        case .array(let items)?:
            return items.compactMap { item in
                let entry = ChatReasoningDetails.entry(item)
                if entry == nil {
                    warnOnce("details-entry", WireWarning(.droppedContent, "a `reasoning_details` entry of an unknown type or shape is not carried", path: "choices[].delta.reasoning_details"))
                }
                return entry
            }
        default:
            warnOnce("details", WireWarning(.droppedField, "stream delta field `reasoning_details` is not a list", path: "choices[].delta.reasoning_details"))
            return []
        }
    }

    /// Appends a `reasoning_details` entry to its block (`type` and
    /// `index`), starting one for an entry not seen before. A fragment for
    /// an entry whose block has ended, or one with nothing to start a block
    /// with (a signature alone), is dropped with a warning.
    private mutating func appendDetail(_ entry: ChatReasoningDetails.Entry, position: Int, sourceKey: String?, into events: inout [WireEvent]) {
        let detail = "\(entry.type)#\(entry.meta["index"]?.numberValue?.int ?? position)"
        if let slot = details.firstIndex(where: { $0.detail == detail }) {
            var current = details[slot]
            if !entry.text.isEmpty { events.append(.reasoningDelta(id: current.block, delta: entry.text)) }
            if let signature = entry.signature {
                current.signature = signature
                current.hasLate = true
            }
            if let data = entry.data {
                current.encrypted = data
                current.hasLate = true
            }
            // Keys sent with a later fragment (an `id`…) go with the end.
            let known = current.extra[ChatReasoningDetails.key]?.objectValue ?? current.detailMeta
            var merged = known
            for (key, value) in entry.meta { merged[key] = value }
            if merged != known {
                current.extra[ChatReasoningDetails.key] = .object(merged)
                current.hasLate = true
            }
            details[slot] = current
            return
        }
        let starts = !entry.text.isEmpty || entry.data != nil
        guard starts, !seenDetails.contains(detail) else {
            if entry.signature != nil || entry.data != nil || !entry.text.isEmpty {
                warnings.append(WireWarning(
                    .malformedStream, "`reasoning_details` fragment for \(detail) has no open block; dropped",
                    path: "choices[].delta.reasoning_details",
                ))
            }
            return
        }
        closeText(into: &events)
        seenDetails.insert(detail)
        let block = newBlock("reasoning")
        var first = entry
        first.text = ""
        events.append(.reasoningStart(id: block, reasoning: ChatReasoningDetails.reasoning(first, origin: origin, sourceKey: sourceKey)))
        details.append(OpenBlock(
            kind: .reasoning, block: block, sourceKey: sourceKey, detail: detail, detailMeta: entry.meta,
            origin: ChatReasoningDetails.origin(origin, meta: entry.meta),
        ))
        if !entry.text.isEmpty { events.append(.reasoningDelta(id: block, delta: entry.text)) }
    }

    /// Gemini's delta-level `extra_content`: the signature (and the rest)
    /// go to the open text or reasoning block, or an empty text (or, for a
    /// thought, reasoning) block; a signature ends the block.
    private mutating func signOpen(_ gemini: ChatGemini.Split, into events: inout [WireEvent]) {
        if open == nil || open?.kind == .refusal {
            closeOpen(into: &events)
            _ = startBlock(
                gemini.thought ? .reasoning : .text,
                sourceKey: gemini.thought ? ChatGemini.thoughtSourceKey : nil, into: &events,
            )
        }
        guard var current = open else { return }
        current.hasLate = true
        if let rest = gemini.rest {
            current.extra[ChatGemini.key] = rest
            if !rest.isNull {
                warnOnce("extra_content", WireWarning(.unknownField, "kept unknown field `\(ChatGemini.key)`", path: "choices[].delta.\(ChatGemini.key)"))
            }
        }
        current.signature = gemini.signature ?? current.signature
        open = current
        if gemini.signature != nil { closeText(into: &events) }
    }

    private static func delta(_ kind: TextKind, _ block: String, _ text: String) -> WireEvent {
        switch kind {
        case .text: .textDelta(id: block, delta: text)
        case .reasoning: .reasoningDelta(id: block, delta: text)
        case .refusal: .refusalDelta(id: block, delta: text)
        }
    }

    /// Ends every open text, reasoning and refusal block.
    private mutating func closeOpen(into events: inout [WireEvent]) {
        closeText(into: &events)
        for block in details { end(block, into: &events) }
        details = []
    }

    /// Ends the open block that is not a details entry.
    private mutating func closeText(into events: inout [WireEvent]) {
        guard let current = open else { return }
        open = nil
        end(current, into: &events)
    }

    private func end(_ current: OpenBlock, into events: inout [WireEvent]) {
        let signedBy = current.signature != nil || current.encrypted != nil ? current.origin : nil
        switch current.kind {
        case .text:
            let late = current.hasLate ? WireText("", signature: current.signature, origin: signedBy, extra: current.extra) : nil
            events.append(.textEnd(id: current.block, text: late))
        case .reasoning:
            let late = current.hasLate
                ? WireReasoning(text: "", signature: current.signature, encrypted: current.encrypted, origin: signedBy, extra: current.extra)
                : nil
            events.append(.reasoningEnd(id: current.block, reasoning: late))
        case .refusal:
            events.append(.refusalEnd(id: current.block, refusal: nil))
        }
    }

    private mutating func toolFragment(_ fragment: JSONObject, position: Int, into events: inout [WireEvent]) {
        let index = fragment["index"]?.numberValue?.int ?? position
        let id = fragment["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let function = fragment["function"]?.objectValue
        let name = function?["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let arguments = function?["arguments"]?.stringValue ?? ""

        let gemini = ChatGemini.split(fragment[ChatGemini.key])
        if let slot = toolByIndex[index], !tools[slot].ended,
           id == nil || tools[slot].id == nil || id == tools[slot].id
        {
            if let signature = gemini.signature {
                tools[slot].signature = signature
                tools[slot].call?.signature = signature
                tools[slot].call?.origin = origin
            }
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

        if let slot = toolByIndex[index], tools[slot].ended, id == nil, name == nil {
            // More arguments for a call already ended (by text that came
            // between its fragments): too late to deliver.
            warnOnce("late-arguments", WireWarning(.malformedStream, "arguments for an ended tool call at index \(index) dropped"))
            return
        }
        // A new call (new index, or a new id on a reused index).
        if let slot = toolByIndex[index], !tools[slot].ended {
            endTool(slot, into: &events)
        }
        var extra = JSONObject()
        for (key, value) in fragment where !["index", "id", "type", "function", ChatGemini.key].contains(key) {
            extra[key] = value
        }
        if let rest = gemini.rest { extra[ChatGemini.key] = rest }
        tools.append(ToolState(
            block: newBlock("tool"), index: index, id: id, name: name ?? "", extra: extra, signature: gemini.signature,
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
        var call = WireToolCall(
            id: id, idSynthesized: state.id == nil, name: state.name, arguments: "",
            signature: state.signature, origin: state.signature == nil ? nil : origin, extra: state.extra,
        )
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
        WireStreamError(json: value)
    }
}
