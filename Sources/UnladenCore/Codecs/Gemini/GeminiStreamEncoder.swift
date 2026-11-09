/// Encodes wire events as a Gemini `streamGenerateContent?alt=sse` stream
/// for a client.
///
/// - Every frame is a bare `data:` line holding a `GenerateContentResponse`
///   (no event names, no `[DONE]`) with `modelVersion` and `responseId`; the
///   same protocol's metadata bag goes in every frame.
/// - Each text or reasoning delta is one part (`thought: true` for
///   reasoning) in its own frame. A signature known at a block's start goes
///   on its first part; one learned at the end (``WireEvent/textEnd(id:text:)``,
///   signature deltas) on a final part with empty text, where Gemini puts
///   it. Signatures are written only if ``GeminiReplay`` accepts their
///   origin; other reasoning keeps its text without one (with a warning).
/// - Tool calls are written whole once complete (argument deltas are
///   buffered): one `functionCall` part with the call's signature. Refusals
///   become text. Gemini opaque parts are written as they are.
/// - The last frame is held back until the next one or the finish, so the
///   `finishReason` (and the final `usageMetadata`, plus the same protocol's
///   candidate keys and `promptFeedback`) ride on the last content, as
///   Gemini sends them; a same-protocol blocked prompt gets no candidate.
/// - ``WireEvent/ping`` writes nothing: Google's SDKs read `data:` lines
///   only and stall on comments.
/// - ``WireEvent/error(_:)`` becomes a `{"error":{code,message,status}}`
///   frame (the upstream's own object for the same protocol), which ends
///   the stream.
package struct GeminiStreamEncoder: Sendable {
    package private(set) var warnings: [WireWarning] = []

    private struct Live: Sendable {
        var thought: Bool
        var accepted: Bool
        /// The start signature and bag, until the first part carries them.
        var startSignature: String?
        var startExtra: JSONObject
        var wroteStart = false
        var signature: String?
    }

    private var id: String
    private var model: String
    private var trusted: Set<WireSystemID>
    private var sameProtocol = false
    private var extra: JSONObject = [:]
    private var started = false
    private var done = false
    private var held: [JSONValue]?
    private var blocks: [String: Live] = [:]
    /// Streamed calls whose ``WireEvent/toolCall(id:call:)`` has not come.
    private var tools: [String: WireToolCall] = [:]
    private var toolOrder: [String] = []
    private var warned: Set<String> = []

    package init(defaults: GeminiResponseDefaults) {
        self.id = defaults.id
        self.model = defaults.model
        self.trusted = defaults.trustedSignatureOrigins
    }

    private var context: GeminiEncode.Context {
        GeminiEncode.Context(include: sameProtocol, trusted: trusted, keepUnsignedReasoning: true)
    }

    package mutating func encode(_ event: WireEvent) -> [SSEElement] {
        guard !done else { return [] }
        var out: [SSEElement] = []
        switch event {
        case .responseMetadata(let metadata):
            guard !started else { break }
            started = true
            sameProtocol = metadata.source == .gemini
            if let value = metadata.id { id = value }
            if let value = metadata.model { model = value }
            if sameProtocol {
                extra = metadata.extra
            } else if !metadata.extra.isEmpty {
                discardExtra(metadata.extra, path: "", warnings: &warnings)
            }

        case .ping:
            break

        case .error(let error):
            flushHeld(into: &out)
            var object = JSONObject()
            if sameProtocol, case .object(let raw)? = error.raw {
                object = raw
            } else {
                object["code"] = .number(error.code.flatMap { JSONNumber(literal: $0) } ?? 500)
                object["message"] = .string(error.message)
                object["status"] = .string(error.type ?? "INTERNAL")
            }
            out.append(Self.frame(["error": .object(object)]))
            done = true

        case .finish(let finish):
            out += finishFrames(finish)

        case .textStart(let block, let text):
            var live = Live(thought: false, accepted: context.accepts(text.origin), startExtra: text.extra)
            live.startSignature = signature(text.signature, accepted: live.accepted, what: "text")
            blocks[block] = live

        case .refusalStart(let block, let refusal):
            warnOnce("refusal", WireWarning(.lossyConversion, "refusal sent as text"))
            if !refusal.extra.isEmpty {
                discardExtra(refusal.extra, path: "part", warnings: &warnings)
            }
            blocks[block] = Live(thought: false, accepted: false, startExtra: [:])

        case .reasoningStart(let block, let reasoning):
            var live = Live(thought: true, accepted: context.accepts(reasoning.origin), startExtra: reasoning.extra)
            live.startSignature = signature(reasoning.signature, accepted: live.accepted, what: "reasoning")
            if reasoning.encrypted != nil {
                warnOnce("encrypted", WireWarning(.droppedContent, "encrypted reasoning cannot be carried by Gemini"))
            }
            blocks[block] = live

        case .textDelta(let block, let delta), .reasoningDelta(let block, let delta), .refusalDelta(let block, let delta):
            guard !delta.isEmpty, blocks[block] != nil else { break }
            writeText(block, delta, signature: nil, into: &out)

        case .reasoningSignatureDelta(let block, let delta):
            guard var live = blocks[block] else { break }
            if live.accepted {
                live.signature = (live.signature ?? "") + delta
                blocks[block] = live
            } else {
                _ = signature(delta, accepted: false, what: "reasoning")
            }

        case .textEnd(let block, let late):
            endText(block, signature: late?.signature, origin: late?.origin, extra: late?.extra ?? [:], into: &out)
        case .reasoningEnd(let block, let late):
            if late?.encrypted != nil {
                warnOnce("encrypted", WireWarning(.droppedContent, "encrypted reasoning cannot be carried by Gemini"))
            }
            endText(block, signature: late?.signature, origin: late?.origin, extra: late?.extra ?? [:], into: &out)
        case .refusalEnd(let block, _):
            endText(block, signature: nil, origin: nil, extra: [:], into: &out)

        case .toolInputStart(let block, let call):
            tools[block] = call
            toolOrder.append(block)
        case .toolInputDelta(let block, let delta):
            tools[block]?.arguments += delta
        case .toolInputEnd:
            break
        case .toolCall(let block, let call):
            if tools.removeValue(forKey: block) != nil { toolOrder.removeAll { $0 == block } }
            writeCall(call, into: &out)

        case .opaque(let opaque):
            guard opaque.protocol == .gemini else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) stream content cannot be carried by Gemini"))
                break
            }
            write([opaque.value], into: &out)
        }
        return out
    }

    /// End of input. Ends the reply if no finish event did.
    package mutating func finish() -> [SSEElement] {
        guard !done else { return [] }
        return finishFrames(WireFinish())
    }

    // MARK: Content

    /// The signature to write, or `nil` (with a warning if one is dropped).
    private mutating func signature(_ value: String?, accepted: Bool, what: String) -> String? {
        guard let value else { return nil }
        if accepted { return value }
        warnOnce("signature.\(what)", WireWarning(.droppedContent, "\(what) signature from another system cannot be carried by Gemini"))
        return nil
    }

    private mutating func writeText(_ block: String, _ text: String, signature late: String?, into out: inout [SSEElement]) {
        guard var live = blocks[block] else { return }
        var object = JSONObject()
        object["text"] = .string(text)
        if live.thought { object["thought"] = true }
        var signature = late
        var bag = JSONObject()
        if !live.wroteStart {
            live.wroteStart = true
            if let start = live.startSignature {
                if signature != nil {
                    // Both: the start one on its own part first.
                    var first: JSONObject = ["text": ""]
                    if live.thought { first["thought"] = true }
                    first["thoughtSignature"] = .string(start)
                    write([.object(first)], into: &out)
                } else {
                    signature = start
                }
            }
            bag = live.startExtra
        }
        if let signature { object["thoughtSignature"] = .string(signature) }
        appendExtra(bag, to: &object, include: sameProtocol, path: "part", warnings: &warnings)
        blocks[block] = live
        write([.object(object)], into: &out)
    }

    private mutating func endText(_ block: String, signature: String?, origin: WireSystemID?, extra: JSONObject, into out: inout [SSEElement]) {
        guard let live = blocks[block] else {
            warnOnce("orphan.\(block)", WireWarning(.malformedStream, "event for block \(block) that was never started"))
            return
        }
        var late = live.signature
        if let signature {
            let accepted = origin.map { context.accepts($0) } ?? live.accepted
            if let value = self.signature(signature, accepted: accepted, what: live.thought ? "reasoning" : "text") { late = value }
        }
        if !extra.isEmpty {
            discardExtra(extra, path: "part", warnings: &warnings)
        }
        let unwritten = !live.wroteStart && (live.startSignature != nil || !live.startExtra.isEmpty)
        if late != nil || unwritten {
            writeText(block, "", signature: late, into: &out)
        }
        blocks[block] = nil
    }

    private mutating func writeCall(_ call: WireToolCall, into out: inout [SSEElement]) {
        let signature = call.signature.flatMap { context.accepts(call.origin) ? $0 : nil }
        if call.signature != nil, signature == nil {
            warnOnce("signature.call", WireWarning(.droppedContent, "tool call signature from another system cannot be carried by Gemini"))
        }
        let part = GeminiEncode.functionCall(call, signature: signature, context: context, path: "part", warnings: &warnings)
        write([part], into: &out)
    }

    // MARK: Frames

    /// Holds `parts` back as the last frame, writing the one held before.
    private mutating func write(_ parts: [JSONValue], into out: inout [SSEElement]) {
        flushHeld(into: &out)
        held = parts
    }

    private mutating func flushHeld(into out: inout [SSEElement]) {
        guard let parts = held else { return }
        held = nil
        out.append(Self.frame(chunk(parts, finish: nil)))
    }

    private mutating func finishFrames(_ finish: WireFinish) -> [SSEElement] {
        var out: [SSEElement] = []
        defer { done = true }
        // Streamed calls whose whole call never came.
        for block in toolOrder {
            if let call = tools[block] { writeCall(call, into: &out) }
        }
        tools = [:]
        toolOrder = []
        let parts = held ?? []
        held = nil
        out.append(Self.frame(chunk(parts, finish: finish)))
        return out
    }

    private mutating func chunk(_ parts: [JSONValue], finish: WireFinish?) -> JSONObject {
        GeminiChunk.make(
            parts: parts, reason: finish?.reason, writeReason: finish != nil, choiceExtra: finish?.extra ?? [:],
            usage: finish?.usage, include: sameProtocol, id: id, model: model, extra: sameProtocol ? extra : [:],
            warnings: &warnings,
        )
    }

    private mutating func warnOnce(_ key: String, _ warning: WireWarning) {
        if warned.insert(key).inserted { warnings.append(warning) }
    }

    private static func frame(_ object: JSONObject) -> SSEElement {
        .event(SSEEvent(data: String(decoding: JSONValue.object(object).encoded(), as: UTF8.self)))
    }
}
