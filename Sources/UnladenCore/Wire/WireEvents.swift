/// Turns complete content into the events a stream of it would carry: the
/// inverse of ``WireResponseAccumulator``.
enum WireEvents {
    /// One block per part (`p<i>`); tool calls whole. Tool results, images
    /// and files cannot appear in a reply and are dropped with a warning,
    /// as is the message bag.
    static func of(_ response: WireResponse, protocolName: String, warnings: inout [WireWarning]) -> [WireEvent] {
        var events: [WireEvent] = [.responseMetadata(WireResponseMetadata(
            id: response.id, model: response.model, created: response.created, extra: response.extra, source: response.source,
        ))]
        for (i, part) in response.message.parts.enumerated() {
            guard let more = of(part, block: "p\(i)") else {
                warnings.append(WireWarning(.droppedContent, "part cannot appear in a \(protocolName) reply", path: WirePath.index("output", i)))
                continue
            }
            events += more
        }
        if !response.message.extra.isEmpty {
            discardExtra(response.message.extra, path: "", warnings: &warnings)
        }
        events.append(.finish(WireFinish(reason: response.finishReason, usage: response.usage, extra: response.choiceExtra)))
        return events
    }

    /// The events of one reply part as block `block`, or `nil` for a part a
    /// reply cannot carry (a tool result, an image, a file).
    ///
    /// - `lateReasoningData`: a reasoning part's signature, encrypted data
    ///   and bag come on its end event, as a stream delivers them, not on
    ///   its start.
    /// - `streamingToolInput`: a tool call's arguments come as input
    ///   events before the whole call, not with the call alone.
    static func of(_ part: WirePart, block: String, lateReasoningData: Bool = false, streamingToolInput: Bool = false) -> [WireEvent]? {
        switch part {
        case .text(var text):
            let content = text.text
            text.text = ""
            return [.textStart(id: block, text: text)] + (content.isEmpty ? [] : [.textDelta(id: block, delta: content)])
                + [.textEnd(id: block, text: nil)]
        case .refusal(var refusal):
            let content = refusal.text
            refusal.text = ""
            return [.refusalStart(id: block, refusal: refusal)] + (content.isEmpty ? [] : [.refusalDelta(id: block, delta: content)])
                + [.refusalEnd(id: block, refusal: nil)]
        case .reasoning(let reasoning):
            var start = reasoning
            start.text = ""
            var late: WireReasoning?
            if lateReasoningData {
                start.signature = nil
                start.encrypted = nil
                start.extra = [:]
                if reasoning.signature != nil || reasoning.encrypted != nil || !reasoning.extra.isEmpty {
                    late = WireReasoning(text: "", signature: reasoning.signature, encrypted: reasoning.encrypted, extra: reasoning.extra)
                }
            }
            return [.reasoningStart(id: block, reasoning: start)]
                + (reasoning.text.isEmpty ? [] : [.reasoningDelta(id: block, delta: reasoning.text)])
                + [.reasoningEnd(id: block, reasoning: late)]
        case .toolCall(let call):
            guard streamingToolInput else { return [.toolCall(id: block, call: call)] }
            var start = call
            start.arguments = ""
            return [.toolInputStart(id: block, call: start)]
                + (call.arguments.isEmpty ? [] : [.toolInputDelta(id: block, delta: call.arguments)])
                + [.toolInputEnd(id: block), .toolCall(id: block, call: call)]
        case .opaque(let opaque):
            return [.opaque(opaque)]
        case .toolResult, .image, .file:
            return nil
        }
    }
}
