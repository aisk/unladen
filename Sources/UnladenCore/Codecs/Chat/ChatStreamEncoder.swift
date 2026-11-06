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
///   be carried and produce a warning.
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
    private var reasoningKeyByBlock: [String: String] = [:]
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
                var ignored = JSONObject()
                appendExtra(metadata.extra, to: &ignored, include: false, path: "", warnings: &warnings)
            }

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
            let key = sameProtocol ? reasoning.sourceKey.flatMap { chatReasoningKeys.contains($0) ? $0 : nil } : nil
            reasoningKeyByBlock[block] = key ?? "reasoning_content"
            if reasoning.hasSignedData { dropFidelity(block) }

        case .reasoningDelta(let block, let delta):
            if !delta.isEmpty {
                content([reasoningKeyByBlock[block] ?? "reasoning_content": .string(delta)], into: &output)
            }

        case .reasoningSignatureDelta(let block, _):
            dropFidelity(block)

        case .reasoningEnd(let block, let reasoning):
            if reasoning?.hasSignedData == true { dropFidelity(block) }

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
        if call.signature != nil { dropSignature("tool call") }
        appendExtra(call.extra, to: &fragment, include: sameProtocol, path: "tool_calls[\(index)]", warnings: &warnings)
        var output: [SSEElement] = []
        content(["tool_calls": [.object(fragment)]], into: &output)
        return output
    }

    private mutating func dropSignature(_ what: String) {
        warnings.append(WireWarning(.droppedContent, "\(what) signature cannot be carried by Chat"))
    }

    /// Part bags have no place in Chat stream deltas.
    private mutating func dropExtra(_ extra: JSONObject) {
        var ignored = JSONObject()
        appendExtra(extra, to: &ignored, include: false, path: "", warnings: &warnings)
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
