@_spi(Wire) import UnladenCore

/// One event of a streamed response.
///
/// Content arrives in blocks: `…Start` → `…Delta`* → `…End`, correlated by
/// a block `id` unique within the stream; several blocks can be open at
/// once (parallel tool calls). End events carry the block's
/// ``ReplayToken``. A tool call's input streams as a block, then arrives
/// whole as ``toolCall(_:)``. Keepalive pings are not surfaced.
///
/// Order: ``warnings(_:)`` (request-side, if any), ``metadata(_:)``,
/// content blocks, ``warnings(_:)`` (response-side, if any), ``finish(_:usage:)``.
public enum StreamPart: Hashable, Sendable {
    case warnings([CallWarning])
    case metadata(ResponseMetadata)

    case textStart(id: String)
    case textDelta(id: String, delta: String)
    case textEnd(id: String, replay: ReplayToken?)

    case reasoningStart(id: String)
    case reasoningDelta(id: String, delta: String)
    case reasoningEnd(id: String, replay: ReplayToken?)

    case refusalStart(id: String)
    case refusalDelta(id: String, delta: String)
    case refusalEnd(id: String, replay: ReplayToken?)

    case toolInputStart(id: String, toolCallID: String, toolName: String)
    case toolInputDelta(id: String, delta: String)
    case toolInputEnd(id: String)
    /// A complete tool call.
    case toolCall(ToolCall)

    case finish(FinishReason, usage: Usage)
}

/// The parts of a streamed response, from ``LanguageModel/stream(_:)``.
///
/// Cold: the request is sent when iteration starts, and each iteration
/// sends its own. Cancelling the iterating task cancels the upstream
/// request; `next()` then throws `CancellationError`.
public struct ResponseStream: AsyncSequence, Sendable {
    public typealias Element = StreamPart
    public typealias Failure = any Error

    let model: LanguageModel
    let request: ModelRequest

    public func makeAsyncIterator() -> Iterator {
        Iterator(model: model, request: request)
    }

    /// Iterates the stream and returns the accumulated response.
    public func collect() async throws -> ModelResponse {
        var accumulator = ResponseAccumulator()
        for try await part in self { accumulator.add(part) }
        return accumulator.response
    }

    public struct Iterator: AsyncIteratorProtocol {
        enum State {
            case idle
            case running(UpstreamEventStream.Iterator)
            case finished
        }

        let model: LanguageModel
        let request: ModelRequest
        var state = State.idle
        var pending: [StreamPart] = []
        var index = 0
        var translator: StreamTranslator

        init(model: LanguageModel, request: ModelRequest) {
            self.model = model
            self.request = request
            self.translator = StreamTranslator(system: model.target.endpoint.system)
        }

        public mutating func next() async throws -> StreamPart? {
            while true {
                if index < pending.count {
                    defer { index += 1 }
                    return pending[index]
                }
                pending = []
                index = 0
                switch state {
                case .finished:
                    return nil
                case .idle:
                    do {
                        let call = try model.prepare(request, stream: true)
                        let reply = try await call.upstream.send(call.request, stream: true)
                        guard case .events(let events) = reply.body else {
                            throw UnladenError.invalidResponse("expected a stream")
                        }
                        state = .running(events.makeAsyncIterator())
                        if !call.warnings.isEmpty { pending = [.warnings(call.warnings)] }
                    } catch {
                        state = .finished
                        throw UnladenError.map(error)
                    }
                case .running(var events):
                    do {
                        if let event = try await events.next() {
                            state = .running(events)
                            pending = try translator.translate(event)
                        } else {
                            state = .finished
                            pending = translator.end(decoderWarnings: events.warnings)
                        }
                    } catch {
                        state = .finished
                        throw UnladenError.map(error)
                    }
                }
            }
        }
    }
}

/// Wire events → stream parts: folds each block's start metadata,
/// signature deltas and late metadata into the token on its end event, and
/// holds the finish back until the decoder's warnings are complete.
struct StreamTranslator {
    let system: String
    var texts: [String: WireText] = [:]
    var reasonings: [String: WireReasoning] = [:]
    var refusals: [String: WireRefusal] = [:]
    var finish: WireFinish?
    var warnings: [CallWarning] = []

    init(system: String) {
        self.system = system
    }

    mutating func translate(_ event: WireEvent) throws(UnladenError) -> [StreamPart] {
        switch event {
        case .responseMetadata(let metadata):
            return [.metadata(ResponseMetadata(id: metadata.id, model: metadata.model, created: metadata.created))]

        case .textStart(let id, let text):
            texts[id] = text
            return [.textStart(id: id)]
        case .textDelta(let id, let delta):
            return [.textDelta(id: id, delta: delta)]
        case .textEnd(let id, let late):
            var text = texts.removeValue(forKey: id) ?? WireText("")
            if let late {
                text.signature = late.signature ?? text.signature
                text.itemID = late.itemID ?? text.itemID
                text.origin = late.origin ?? text.origin
            }
            guard case .text(_, let token)? = WireConversion.part(.text(text), system: system) else { return [] }
            return [.textEnd(id: id, replay: token)]

        case .reasoningStart(let id, let reasoning):
            reasonings[id] = reasoning
            return [.reasoningStart(id: id)]
        case .reasoningDelta(let id, let delta):
            return [.reasoningDelta(id: id, delta: delta)]
        case .reasoningSignatureDelta(let id, let delta):
            reasonings[id, default: WireReasoning(text: "")].signature = (reasonings[id]?.signature ?? "") + delta
            return []
        case .reasoningEnd(let id, let late):
            var reasoning = reasonings.removeValue(forKey: id) ?? WireReasoning(text: "")
            if let late {
                reasoning.signature = late.signature ?? reasoning.signature
                reasoning.encrypted = late.encrypted ?? reasoning.encrypted
                reasoning.itemID = late.itemID ?? reasoning.itemID
                reasoning.summaryIndex = late.summaryIndex ?? reasoning.summaryIndex
                reasoning.origin = late.origin ?? reasoning.origin
                reasoning.sourceKey = late.sourceKey ?? reasoning.sourceKey
            }
            guard case .reasoning(_, let token)? = WireConversion.part(.reasoning(reasoning), system: system) else { return [] }
            return [.reasoningEnd(id: id, replay: token)]

        case .refusalStart(let id, let refusal):
            refusals[id] = refusal
            return [.refusalStart(id: id)]
        case .refusalDelta(let id, let delta):
            return [.refusalDelta(id: id, delta: delta)]
        case .refusalEnd(let id, let late):
            var refusal = refusals.removeValue(forKey: id) ?? WireRefusal("")
            if let late {
                refusal.itemID = late.itemID ?? refusal.itemID
                refusal.origin = late.origin ?? refusal.origin
            }
            guard case .refusal(_, let token)? = WireConversion.part(.refusal(refusal), system: system) else { return [] }
            return [.refusalEnd(id: id, replay: token)]

        case .toolInputStart(let id, let call):
            return [.toolInputStart(id: id, toolCallID: call.id, toolName: call.name)]
        case .toolInputDelta(let id, let delta):
            return [.toolInputDelta(id: id, delta: delta)]
        case .toolInputEnd(let id):
            return [.toolInputEnd(id: id)]
        case .toolCall(_, let call):
            return [.toolCall(WireConversion.toolCall(call, system: system))]

        case .opaque:
            warnings.append(CallWarning(.opaqueContent, "provider content Unladen does not model was left out of the message"))
            return []
        case .ping:
            return []
        case .error(let error):
            throw .stream(ProviderStreamError(error))
        case .finish(let finish):
            self.finish = finish
            return []
        }
    }

    /// The parts after the last event: response-side warnings, then the finish.
    mutating func end(decoderWarnings: [WireWarning]) -> [StreamPart] {
        var parts: [StreamPart] = []
        let all = decoderWarnings.map(WireConversion.warning) + warnings
        if !all.isEmpty { parts.append(.warnings(all)) }
        if let finish {
            parts.append(.finish(WireConversion.finishReason(finish.reason), usage: WireConversion.usage(finish.usage)))
        }
        return parts
    }
}

/// Folds stream parts into a ``ModelResponse``, for callers that render a
/// stream and also want the message for their history.
///
/// ```swift
/// var accumulator = ResponseAccumulator()
/// for try await part in model.stream(history) {
///     accumulator.add(part)
///     if case .textDelta(_, let delta) = part { print(delta, terminator: "") }
/// }
/// history.append(accumulator.response.message)
/// ```
public struct ResponseAccumulator: Sendable {
    enum Slot: Sendable {
        case text(String, ReplayToken?)
        case reasoning(String, ReplayToken?)
        case refusal(String, ReplayToken?)
        case tool(id: String, name: String, arguments: String, call: ToolCall?)
    }

    var slots: [Slot] = []
    /// Stream block id → slot.
    var blocks: [String: Int] = [:]
    /// Tool call id → slot.
    var calls: [String: Int] = [:]
    var finishReason: FinishReason?
    var usage = Usage()
    var metadata = ResponseMetadata()
    var warnings: [CallWarning] = []

    public init() {}

    public mutating func add(_ part: StreamPart) {
        switch part {
        case .warnings(let list):
            warnings += list
        case .metadata(let value):
            metadata.id = value.id ?? metadata.id
            metadata.model = value.model ?? metadata.model
            metadata.created = value.created ?? metadata.created

        case .textStart(let id):
            open(id, .text("", nil))
        case .reasoningStart(let id):
            open(id, .reasoning("", nil))
        case .refusalStart(let id):
            open(id, .refusal("", nil))
        case .toolInputStart(let id, let callID, let name):
            open(id, .tool(id: callID, name: name, arguments: "", call: nil))
            calls[callID] = slots.count - 1

        case .textDelta(let id, let delta), .reasoningDelta(let id, let delta),
             .refusalDelta(let id, let delta), .toolInputDelta(let id, let delta):
            guard let i = blocks[id] else { return }
            switch slots[i] {
            case .text(let text, let token): slots[i] = .text(text + delta, token)
            case .reasoning(let text, let token): slots[i] = .reasoning(text + delta, token)
            case .refusal(let text, let token): slots[i] = .refusal(text + delta, token)
            case .tool(let callID, let name, let arguments, let call): slots[i] = .tool(id: callID, name: name, arguments: arguments + delta, call: call)
            }

        case .textEnd(let id, let token), .reasoningEnd(let id, let token), .refusalEnd(let id, let token):
            guard let i = blocks[id] else { return }
            switch slots[i] {
            case .text(let text, _): slots[i] = .text(text, token)
            case .reasoning(let text, _): slots[i] = .reasoning(text, token)
            case .refusal(let text, _): slots[i] = .refusal(text, token)
            case .tool: break
            }
        case .toolInputEnd:
            break
        case .toolCall(let call):
            if let i = calls[call.id], case .tool(let callID, let name, let arguments, _) = slots[i] {
                slots[i] = .tool(id: callID, name: name, arguments: arguments, call: call)
            } else {
                slots.append(.tool(id: call.id, name: call.name, arguments: call.arguments, call: call))
                calls[call.id] = slots.count - 1
            }

        case .finish(let reason, let usage):
            finishReason = reason
            self.usage = usage
        }
    }

    private mutating func open(_ id: String, _ slot: Slot) {
        blocks[id] = slots.count
        slots.append(slot)
    }

    /// The response so far; complete after the ``StreamPart/finish(_:usage:)``.
    public var response: ModelResponse {
        let content: [ContentPart] = slots.compactMap { slot in
            switch slot {
            case .text(let text, let token): text.isEmpty && token == nil ? nil : .text(text, replay: token)
            case .reasoning(let text, let token): .reasoning(text, replay: token)
            case .refusal(let text, let token): .refusal(text, replay: token)
            case .tool(let id, let name, let arguments, let call): .toolCall(call ?? ToolCall(id: id, name: name, arguments: arguments))
            }
        }
        return ModelResponse(
            message: .assistant(content),
            finishReason: finishReason ?? FinishReason(.other),
            usage: usage,
            warnings: warnings,
            metadata: metadata,
        )
    }
}
