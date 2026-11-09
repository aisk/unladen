/// Encodes wire events as a Chat Completions SSE stream for a client.
///
/// - Assigns `tool_calls[].index` itself, contiguously from 0 in the order
///   calls start; deltas of several calls may interleave.
/// - Sends a `{"role":"assistant","content":""}` chunk before the first
///   content, as OpenAI does.
/// - ``WireEvent/ping`` becomes an SSE comment (`: ping`).
/// - ``WireEvent/finish(_:)`` becomes a `finish_reason` chunk (omitted after
///   an in-stream error), a usage-only chunk (when `includeUsage` and usage
///   is known), then `data: [DONE]`.
/// - Reasoning goes out as `reasoning_content` (or `reasoning`, if that is
///   what a Chat upstream used); signatures and encrypted reasoning cannot
///   be carried and produce a warning, except what a Chat upstream sent in
///   its own dialect, which goes back there: OpenRouter `reasoning_details`
///   (``ChatReasoningDetails``), Gemini's `extra_content` thought marker and
///   signatures (``ChatGemini``), Mistral `thinking` parts
///   (``ChatMistral``).
/// - Unknown fields from the upstream (``WireResponseMetadata/extra``, usage
///   and finish bags, tool-call bags, Chat opaque tool calls) and spelling
///   hints are written only if the metadata says the source was Chat.
/// - Early usage (``WireResponseMetadata/usage``) is not written: Chat
///   reports usage once, at the end, and the finish usage supersedes it.
/// - Item ids are dropped silently; signatures produce a warning.
package struct ChatCompletionsStreamEncoder: Sendable {
    package var includeUsage: Bool
    package private(set) var warnings: [WireWarning] = []

    private var id: String
    private var model: String
    private var created: Int
    private var chunkExtra: JSONObject = [:]
    private var sameProtocol = false
    private var roleSent = false
    private var done = false
    private var errored = false
    private var nextToolIndex = 0
    private var toolIndexByBlock: [String: Int] = [:]
    /// How a reasoning block is written, and its end metadata so far.
    private struct ReasoningOut: Sendable {
        /// The plain field (`reasoning_content`…), if one is written.
        var key: String?
        var style: Style
        var signature: String?
        var encrypted: String?
        var extra: JSONObject

        enum Style: Sendable { case plain, details(JSONObject), thought, thinking }
    }

    private var reasoningByBlock: [String: ReasoningOut] = [:]
    /// Start metadata of same-protocol text blocks, written at their end.
    private var textByBlock: [String: WireText] = [:]
    private var warned: Set<String> = []

    package init(defaults: ChatResponseDefaults, includeUsage: Bool) {
        self.id = defaults.id
        self.model = defaults.model
        self.created = defaults.created
        self.includeUsage = includeUsage
    }

    package mutating func encode(_ event: WireEvent) -> [SSEElement] {
        guard !done else { return [] }
        var output: [SSEElement] = []
        switch event {
        case .responseMetadata(let metadata):
            if let value = metadata.id { id = value }
            if let value = metadata.model { model = value }
            if let value = metadata.created { created = value }
            sameProtocol = metadata.source == .chatCompletions
            chunkExtra = metadata.extra
            if !sameProtocol, !metadata.extra.isEmpty {
                discardExtra(metadata.extra, path: "", warnings: &warnings)
            }

        case .textStart(let block, let text) where sameProtocol:
            // Kept for the end (a whole reply replayed as events signs the
            // start; a stream signs the end).
            if text.signature != nil || !text.extra.isEmpty { textByBlock[block] = text }

        case .textEnd(let block, let late) where sameProtocol:
            // A Chat upstream's text signature is Gemini's: back into a
            // delta's `extra_content`, with the rest of it.
            var text = textByBlock.removeValue(forKey: block) ?? WireText("")
            if let late {
                if let value = late.signature { text.signature = value }
                for (key, value) in late.extra { text.extra[key] = value }
            }
            var extra = text.extra
            if let joined = ChatGemini.join(rest: extra.removeValue(forKey: ChatGemini.key), signature: text.signature) {
                content([ChatGemini.key: joined], into: &output)
            }
            if !extra.isEmpty { dropExtra(extra) }

        case .textStart(_, let text), .textEnd(_, let text?):
            if text.signature != nil { dropSignature("text") }
            if !text.extra.isEmpty { dropExtra(text.extra) }

        case .refusalStart(_, let refusal), .refusalEnd(_, let refusal?):
            if !refusal.extra.isEmpty { dropExtra(refusal.extra) }

        case .textEnd(_, nil), .refusalEnd(_, nil), .toolInputEnd:
            break

        case .textDelta(_, let delta):
            if !delta.isEmpty { content(["content": .string(delta)], into: &output) }

        case .refusalDelta(_, let delta):
            if !delta.isEmpty { content(["refusal": .string(delta)], into: &output) }

        case .reasoningStart(let block, let reasoning):
            var out = ReasoningOut(
                key: nil, style: .plain, signature: reasoning.signature, encrypted: reasoning.encrypted, extra: reasoning.extra,
            )
            let spelling = sameProtocol ? reasoning.sourceKey.flatMap { chatReasoningKeys.contains($0) ? $0 : nil } : nil
            if sameProtocol, case .object(let meta)? = reasoning.extra[ChatReasoningDetails.key] {
                out.style = .details(meta)
                out.key = spelling
                out.extra[ChatReasoningDetails.key] = nil
            } else if sameProtocol, reasoning.sourceKey == ChatGemini.thoughtSourceKey {
                out.style = .thought
            } else if sameProtocol, reasoning.sourceKey == ChatMistral.thinkingSourceKey {
                out.style = .thinking
            } else {
                out.key = spelling ?? "reasoning_content"
            }
            reasoningByBlock[block] = out

        case .reasoningDelta(let block, let delta):
            if !delta.isEmpty, let out = reasoningByBlock[block] {
                var object = JSONObject()
                if let key = out.key { object[key] = .string(delta) }
                switch out.style {
                case .plain:
                    break
                case .details(let meta):
                    object[ChatReasoningDetails.key] = [ChatReasoningDetails.encode(meta: meta, text: delta, signature: nil, data: nil)]
                case .thought:
                    object["content"] = .string(delta)
                    object[ChatGemini.key] = ChatGemini.join(rest: nil, signature: nil, thought: true)
                case .thinking:
                    object["content"] = [ChatMistral.thinking(delta)]
                }
                content(object, into: &output)
            }

        case .reasoningSignatureDelta(let block, let delta):
            if var out = reasoningByBlock[block] {
                out.signature = (out.signature ?? "") + delta
                reasoningByBlock[block] = out
            }

        case .reasoningEnd(let block, let late):
            guard var out = reasoningByBlock.removeValue(forKey: block) else { break }
            if let late {
                if let value = late.signature { out.signature = value }
                if let value = late.encrypted { out.encrypted = value }
                for (key, value) in late.extra { out.extra[key] = value }
            }
            output += endReasoning(block, out)
        case .toolInputStart(let block, let call):
            output += startTool(block: block, call: call, arguments: "")

        case .toolInputDelta(let block, let delta):
            guard let index = toolIndexByBlock[block], !delta.isEmpty else { break }
            let fragment: JSONObject = ["index": .number(JSONNumber(index)), "function": ["arguments": .string(delta)]]
            content(["tool_calls": [.object(fragment)]], into: &output)

        case .toolCall(let block, let call):
            // Already streamed through tool-input events, or delivered whole.
            if toolIndexByBlock[block] == nil {
                output += startTool(block: block, call: call, arguments: call.arguments)
            }

        case .opaque(let opaque):
            // A Chat tool call of a non-function type, mirroring ChatEncode.messages.
            if opaque.protocol == .chatCompletions, opaque.slot == "tool_calls", case .object(var fragment) = opaque.value {
                fragment["index"] = .number(JSONNumber(nextToolIndex))
                nextToolIndex += 1
                content(["tool_calls": [.object(fragment)]], into: &output)
            } else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) stream content cannot be carried by Chat"))
            }

        case .ping:
            output.append(.comment("ping"))

        case .error(let error):
            var object = JSONObject()
            if sameProtocol, case .object(let raw)? = error.raw {
                object = raw
            } else {
                object["message"] = .string(error.message)
                if let type = error.type { object["type"] = .string(type) }
                if let code = error.code { object["code"] = .string(code) }
            }
            output.append(self.event(["error": .object(object)]))
            errored = true

        case .finish(let finish):
            // After an in-stream error the error chunk is the ending; a
            // finish_reason chunk would contradict it.
            if !errored {
                ensureRole(into: &output)
                let reason = ChatFinish.encode(finish.reason, sameProtocol: sameProtocol)
                output.append(chunk(delta: [:], finishReason: reason, choiceExtra: finish.extra))
            } else if !finish.extra.isEmpty {
                dropExtra(finish.extra)
            }
            if includeUsage, let usage = finish.usage {
                var object = header()
                object["choices"] = []
                object["usage"] = ChatUsage.encode(usage, include: sameProtocol, path: "usage", warnings: &warnings)
                appendChunkExtra(to: &object)
                output.append(self.event(object))
            }
            output.append(.event(SSEEvent(data: "[DONE]")))
            done = true
        }
        return output
    }

    /// End of input. Writes `data: [DONE]` if no finish event did.
    package mutating func finish() -> [SSEElement] {
        guard !done else { return [] }
        done = true
        return [.event(SSEEvent(data: "[DONE]"))]
    }

    // MARK: Internals

    private mutating func startTool(block: String, call: WireToolCall, arguments: String) -> [SSEElement] {
        let index = nextToolIndex
        nextToolIndex += 1
        toolIndexByBlock[block] = index
        var fragment = JSONObject()
        fragment["index"] = .number(JSONNumber(index))
        fragment["id"] = .string(call.id)
        fragment["type"] = "function"
        fragment["function"] = ["name": .string(call.name), "arguments": .string(arguments)]
        if call.signature != nil, !sameProtocol { dropSignature("tool call") }
        ChatGemini.appendBag(call.extra, signature: call.signature, write: sameProtocol, to: &fragment, include: sameProtocol, path: "tool_calls[\(index)]", warnings: &warnings)
        var output: [SSEElement] = []
        content(["tool_calls": [.object(fragment)]], into: &output)
        return output
    }

    /// The end of a reasoning block: its signature or encrypted data, if
    /// the block's dialect can carry them (same protocol), as a last delta.
    private mutating func endReasoning(_ block: String, _ out: ReasoningOut) -> [SSEElement] {
        var output: [SSEElement] = []
        let signed = out.signature != nil || out.encrypted != nil
        switch out.style {
        case .details(let started):
            // Keys learned late (an `id`…) come with the end metadata.
            let meta = out.extra[ChatReasoningDetails.key]?.objectValue ?? started
            let type = meta["type"]?.stringValue
            if out.signature != nil && type != "reasoning.text" || out.encrypted != nil && type != "reasoning.encrypted" {
                dropFidelity(block)
            } else if signed || meta != started {
                let entry = ChatReasoningDetails.encode(meta: meta, text: nil, signature: out.signature, data: out.encrypted)
                content([ChatReasoningDetails.key: [entry]], into: &output)
            }
        case .thought, .plain:
            if sameProtocol, out.encrypted == nil {
                if let joined = ChatGemini.join(rest: out.extra[ChatGemini.key], signature: out.signature) {
                    content([ChatGemini.key: joined], into: &output)
                }
            } else if signed {
                dropFidelity(block)
            }
        case .thinking:
            if signed { dropFidelity(block) }
        }
        return output
    }

    private mutating func dropSignature(_ what: String) {
        warnings.append(WireWarning(.droppedContent, "\(what) signature cannot be carried by Chat"))
    }

    /// Part bags have no place in Chat stream deltas.
    private mutating func dropExtra(_ extra: JSONObject) {
        discardExtra(extra, path: "", warnings: &warnings)
    }

    private mutating func dropFidelity(_ block: String) {
        if warned.insert(block).inserted {
            warnings.append(WireWarning(.droppedContent, "reasoning signature/encrypted data cannot be carried by Chat"))
        }
    }

    private mutating func ensureRole(into output: inout [SSEElement]) {
        guard !roleSent else { return }
        roleSent = true
        output.append(chunk(delta: ["role": "assistant", "content": ""], finishReason: .null))
    }

    private mutating func content(_ delta: JSONObject, into output: inout [SSEElement]) {
        ensureRole(into: &output)
        output.append(chunk(delta: delta, finishReason: .null))
    }

    private func header() -> JSONObject {
        var object = JSONObject()
        object["id"] = .string(id)
        object["object"] = "chat.completion.chunk"
        object["created"] = .number(JSONNumber(created))
        object["model"] = .string(model)
        return object
    }

    private func appendChunkExtra(to object: inout JSONObject) {
        guard sameProtocol else { return }
        var ignored: [WireWarning] = []
        appendExtra(chunkExtra, to: &object, include: true, path: "", warnings: &ignored)
    }

    private mutating func chunk(delta: JSONObject, finishReason: JSONValue, choiceExtra: JSONObject = [:]) -> SSEElement {
        var object = header()
        var choice: JSONObject = ["index": 0, "delta": .object(delta), "finish_reason": finishReason]
        appendExtra(choiceExtra, to: &choice, include: sameProtocol, path: "choices[0]", warnings: &warnings)
        object["choices"] = [.object(choice)]
        appendChunkExtra(to: &object)
        return event(object)
    }

    private func event(_ object: JSONObject) -> SSEElement {
        .event(SSEEvent(data: String(decoding: JSONValue.object(object).encoded(), as: UTF8.self)))
    }
}
