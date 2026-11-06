// Stream and JSON checks shared by the test targets: the core codec tests
// and the replay suite run the same well-formedness rules over what the
// encoders produce.

@_spi(Wire) import UnladenCore

extension JSONValue {
    /// The value with every object's keys sorted, for order-insensitive
    /// structural comparison.
    package var canonical: JSONValue {
        switch self {
        case .array(let values):
            return .array(values.map(\.canonical))
        case .object(let object):
            var sorted = JSONObject()
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                sorted[key] = value.canonical
            }
            return .object(sorted)
        default:
            return self
        }
    }
}

/// Checks the block structure of a wire event stream. Returns problems.
package func checkEventSequence(_ events: [WireEvent]) -> [String] {
    enum Kind { case text, reasoning, refusal, tool }
    var problems: [String] = []
    var open: [String: Kind] = [:]
    var seen: Set<String> = []
    var endedTools: Set<String> = []
    var finished = false
    var metadataCount = 0

    func start(_ id: String, _ kind: Kind) {
        if seen.contains(id) { problems.append("block \(id) started twice") }
        seen.insert(id)
        open[id] = kind
    }
    func delta(_ id: String, _ kind: Kind) {
        if open[id] != kind { problems.append("delta for block \(id) that is not an open \(kind) block") }
    }
    func end(_ id: String, _ kind: Kind) {
        if open[id] != kind { problems.append("end for block \(id) that is not an open \(kind) block") }
        open[id] = nil
    }

    for (i, event) in events.enumerated() {
        if finished { problems.append("event \(i) after finish: \(event)") }
        switch event {
        case .responseMetadata:
            metadataCount += 1
            if !seen.isEmpty { problems.append("metadata after content") }
        case .textStart(let id, _): start(id, .text)
        case .textDelta(let id, _): delta(id, .text)
        case .textEnd(let id, _): end(id, .text)
        case .reasoningStart(let id, _): start(id, .reasoning)
        case .reasoningDelta(let id, _), .reasoningSignatureDelta(let id, _): delta(id, .reasoning)
        case .reasoningEnd(let id, _): end(id, .reasoning)
        case .refusalStart(let id, _): start(id, .refusal)
        case .refusalDelta(let id, _): delta(id, .refusal)
        case .refusalEnd(let id, _): end(id, .refusal)
        case .toolInputStart(let id, let call):
            start(id, .tool)
            if !call.arguments.isEmpty { problems.append("tool start \(id) carries arguments") }
        case .toolInputDelta(let id, _): delta(id, .tool)
        case .toolInputEnd(let id):
            end(id, .tool)
            endedTools.insert(id)
        case .toolCall(let id, _):
            if seen.contains(id), !endedTools.contains(id) { problems.append("tool call \(id) before its input ended") }
        case .opaque, .ping, .error:
            break
        case .finish:
            finished = true
            if !open.isEmpty { problems.append("blocks open at finish: \(open.keys.sorted())") }
        }
    }
    if !finished { problems.append("no finish event") }
    if metadataCount > 1 { problems.append("metadata sent \(metadataCount) times") }
    return problems
}

/// Checks an encoded Chat Completions stream: contiguous tool indices that
/// start with id and name, one finish_reason, `[DONE]` last.
package func checkChatStream(_ elements: [SSEElement]) -> [String] {
    var problems: [String] = []
    var nextIndex = 0
    var finishCount = 0
    var sawDone = false
    for element in elements {
        guard case .event(let event) = element else { continue }
        if sawDone { problems.append("data after [DONE]") }
        if event.data == "[DONE]" {
            sawDone = true
            continue
        }
        guard let chunk = try? JSONValue(parsing: event.data) else {
            problems.append("invalid JSON chunk")
            continue
        }
        if chunk["error"] != nil { continue }
        for choice in chunk["choices"]?.arrayValue ?? [] {
            if case .string? = choice["finish_reason"] { finishCount += 1 }
            for call in choice["delta"]?["tool_calls"]?.arrayValue ?? [] {
                guard let index = call["index"]?.numberValue?.int else {
                    problems.append("tool call fragment without index")
                    continue
                }
                if index == nextIndex {
                    nextIndex += 1
                    let isFunction = call["type"] == nil || call["type"] == "function"
                    if call["id"]?.stringValue == nil || (isFunction && call["function"]?["name"]?.stringValue == nil) {
                        problems.append("tool call \(index) starts without id and name")
                    }
                } else if index > nextIndex {
                    problems.append("tool index \(index) skips \(nextIndex)")
                }
            }
        }
    }
    if finishCount > 1 { problems.append("\(finishCount) finish reasons") }
    if !sawDone { problems.append("no [DONE]") }
    return problems
}

/// The JSON payloads of a stream's events, with their SSE event names.
package func anthropicPayloads(_ elements: [SSEElement]) -> [(name: String?, json: JSONValue)] {
    elements.compactMap { element in
        guard case .event(let event) = element, let json = try? JSONValue(parsing: event.data) else { return nil }
        return (event.event, json)
    }
}

/// Checks an encoded Anthropic stream: `message_start` first, one content
/// block open at a time with contiguous indices from 0, deltas that match
/// their block's type, event names equal to payload types, and an ending of
/// `message_delta` + `message_stop` or an `error` event.
package func checkAnthropicStream(_ elements: [SSEElement]) -> [String] {
    var problems: [String] = []
    var started = false
    var ended = false
    var sawMessageDelta = false
    var nextIndex = 0
    var open: (index: Int, type: String)?
    let deltaTypes: [String: Set<String>] = [
        "text": ["text_delta", "citations_delta"],
        "thinking": ["thinking_delta", "signature_delta"],
        "redacted_thinking": [],
        "tool_use": ["input_json_delta"],
        "server_tool_use": ["input_json_delta"],
    ]
    for element in elements {
        guard case .event(let event) = element else { continue }
        if ended { problems.append("event after the end: \(event.data)") }
        guard let json = try? JSONValue(parsing: event.data), let type = json["type"]?.stringValue else {
            problems.append("invalid event payload: \(event.data)")
            continue
        }
        if event.event != type { problems.append("event name \(event.event ?? "nil") for payload type \(type)") }
        if !started, type != "message_start", type != "error" { problems.append("\(type) before message_start") }
        let index = json["index"]?.numberValue?.int
        switch type {
        case "message_start":
            if started { problems.append("second message_start") }
            started = true
            if json["message"]?["usage"]?["input_tokens"] == nil { problems.append("message_start without usage") }
        case "content_block_start":
            if let open { problems.append("block \(index ?? -1) started while \(open.index) is open") }
            if index != nextIndex { problems.append("block index \(index ?? -1), expected \(nextIndex)") }
            nextIndex += 1
            open = (index ?? -1, json["content_block"]?["type"]?.stringValue ?? "")
        case "content_block_delta":
            guard let current = open, current.index == index else {
                problems.append("delta for block \(index ?? -1) that is not open")
                continue
            }
            let deltaType = json["delta"]?["type"]?.stringValue ?? ""
            if let allowed = deltaTypes[current.type], !allowed.contains(deltaType) {
                problems.append("\(deltaType) in a \(current.type) block")
            }
        case "content_block_stop":
            if open?.index != index { problems.append("stop for block \(index ?? -1) that is not open") }
            open = nil
        case "message_delta":
            if let open { problems.append("message_delta while block \(open.index) is open") }
            if sawMessageDelta { problems.append("second message_delta") }
            sawMessageDelta = true
            if json["usage"]?["output_tokens"] == nil { problems.append("message_delta without output_tokens") }
        case "message_stop":
            if !sawMessageDelta { problems.append("message_stop without message_delta") }
            ended = true
        case "error":
            ended = true
        case "ping":
            break
        default:
            problems.append("unknown event type \(type)")
        }
    }
    if !ended { problems.append("stream did not end with message_stop or error") }
    return problems
}

/// The JSON payloads of a stream's events, with their SSE event names.
package func responsesPayloads(_ elements: [SSEElement]) -> [(name: String?, json: JSONValue)] {
    elements.compactMap { element in
        guard case .event(let event) = element, let json = try? JSONValue(parsing: event.data) else { return nil }
        return (event.event, json)
    }
}

/// Checks an encoded Responses stream:
/// - event names equal payload types; `sequence_number` runs 0, 1, 2, …;
/// - `response.created` (then `response.in_progress`) first, one final
///   event last;
/// - output items are added with contiguous `output_index`es from 0, one at
///   a time, and done with the same index and id; every part, delta and
///   done event names the open item's index and id;
/// - content parts (`content_index`) and summary parts (`summary_index`)
///   are contiguous from 0, added before their deltas and done once;
/// - each item's `done` text equals what its deltas built;
/// - the final `response.output` equals the list of done items.
package func checkResponsesStream(_ elements: [SSEElement]) -> [String] {
    struct Open {
        var index: Int
        var id: String
        var type: String
        var parts: [String: String] = [:]
        var openParts: Set<String> = []
        var nextContent = 0
        var nextSummary = 0
        var arguments = ""
    }
    var problems: [String] = []
    var sequence = 0
    var names: [String] = []
    var nextIndex = 0
    var open: Open?
    var doneItems: [JSONValue] = []
    var ended = false

    func text(of item: JSONValue, key: String) -> String {
        item[key]?.stringValue ?? ""
    }

    for (name, json) in responsesPayloads(elements) {
        guard let type = json["type"]?.stringValue else {
            problems.append("event without type")
            continue
        }
        names.append(type)
        if ended { problems.append("\(type) after the final event") }
        if name != type { problems.append("event name \(name ?? "nil") for payload type \(type)") }
        if json["sequence_number"]?.numberValue?.int != sequence {
            problems.append("\(type): sequence_number \(json["sequence_number"]?.description ?? "nil"), expected \(sequence)")
        }
        sequence += 1
        let outputIndex = json["output_index"]?.numberValue?.int
        let itemID = json["item_id"]?.stringValue
        if itemID != nil || (outputIndex != nil && !type.hasPrefix("response.output_item")) {
            if outputIndex != open?.index || itemID != open?.id {
                problems.append("\(type) for item \(outputIndex ?? -1)/\(itemID ?? "nil") that is not open")
                continue
            }
        }
        switch type {
        case "response.output_item.added":
            if let open { problems.append("item \(outputIndex ?? -1) added while \(open.index) is open") }
            if outputIndex != nextIndex { problems.append("output_index \(outputIndex ?? -1), expected \(nextIndex)") }
            nextIndex += 1
            open = Open(index: outputIndex ?? -1, id: json["item"]?["id"]?.stringValue ?? "", type: json["item"]?["type"]?.stringValue ?? "")
        case "response.output_item.done":
            guard let current = open, current.index == outputIndex else {
                problems.append("done for item \(outputIndex ?? -1) that is not open")
                continue
            }
            let item = json["item"] ?? .null
            if item["id"]?.stringValue != current.id { problems.append("item \(current.index) done with another id") }
            if !current.openParts.isEmpty { problems.append("item \(current.index) done with open parts \(current.openParts.sorted())") }
            switch current.type {
            case "message":
                for (i, part) in (item["content"]?.arrayValue ?? []).enumerated() {
                    let built = current.parts["c\(i)"] ?? ""
                    let done = part["text"]?.stringValue ?? part["refusal"]?.stringValue ?? ""
                    if built != done { problems.append("message \(current.index) part \(i): deltas \(built.debugDescription), done \(done.debugDescription)") }
                }
                if item["content"]?.arrayValue?.count != current.nextContent { problems.append("message \(current.index) part count") }
            case "reasoning":
                for (i, part) in (item["summary"]?.arrayValue ?? []).enumerated() where current.parts["s\(i)"] != part["text"]?.stringValue {
                    problems.append("reasoning \(current.index) summary \(i) differs from its deltas")
                }
                if (item["summary"]?.arrayValue?.count ?? 0) != current.nextSummary { problems.append("reasoning \(current.index) summary count") }
            case "function_call":
                if text(of: item, key: "arguments") != current.arguments { problems.append("call \(current.index) arguments differ from deltas") }
            case "custom_tool_call":
                if text(of: item, key: "input") != current.arguments { problems.append("call \(current.index) input differs from deltas") }
            default:
                break
            }
            doneItems.append(item)
            open = nil
        case "response.content_part.added", "response.reasoning_summary_part.added":
            let summary = type == "response.reasoning_summary_part.added"
            let index = json[summary ? "summary_index" : "content_index"]?.numberValue?.int ?? -1
            let expected = summary ? open?.nextSummary : open?.nextContent
            if index != expected { problems.append("\(type) index \(index), expected \(expected ?? -1)") }
            let key = "\(summary ? "s" : "c")\(index)"
            open?.openParts.insert(key)
            open?.parts[key] = ""
            if summary { open?.nextSummary += 1 } else { open?.nextContent += 1 }
        case "response.content_part.done", "response.reasoning_summary_part.done":
            let summary = type == "response.reasoning_summary_part.done"
            let key = "\(summary ? "s" : "c")\(json[summary ? "summary_index" : "content_index"]?.numberValue?.int ?? -1)"
            if open?.openParts.remove(key) == nil { problems.append("\(type) for part \(key) that is not open") }
            let part = json["part"] ?? .null
            let done = part["text"]?.stringValue ?? part["refusal"]?.stringValue ?? ""
            if open?.parts[key] != done { problems.append("\(type) \(key) text differs from deltas") }
        case "response.output_text.delta", "response.refusal.delta", "response.reasoning_text.delta",
             "response.reasoning_summary_text.delta":
            let summary = type == "response.reasoning_summary_text.delta"
            let key = "\(summary ? "s" : "c")\(json[summary ? "summary_index" : "content_index"]?.numberValue?.int ?? -1)"
            if open?.openParts.contains(key) != true { problems.append("\(type) for part \(key) that is not open") }
            open?.parts[key, default: ""] += json["delta"]?.stringValue ?? ""
        case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
            open?.arguments += json["delta"]?.stringValue ?? ""
        case "response.completed", "response.incomplete", "response.failed":
            ended = true
            if let open { problems.append("final event while item \(open.index) is open") }
            if json["response"]?["output"] != .array(doneItems) { problems.append("response.output differs from the done items") }
            if json["response"]?["status"] == nil { problems.append("final response without status") }
        case "response.created", "response.in_progress", "response.output_text.done", "response.refusal.done",
             "response.reasoning_summary_text.done", "response.reasoning_text.done",
             "response.function_call_arguments.done", "response.custom_tool_call_input.done":
            break
        default:
            problems.append("unexpected event \(type)")
        }
    }
    if names.prefix(2) != ["response.created", "response.in_progress"] { problems.append("stream does not begin with created, in_progress") }
    if !ended { problems.append("no final response event") }
    return problems
}

/// The JSON payloads of a Gemini stream's frames.
package func geminiChunks(_ elements: [SSEElement]) -> [JSONValue] {
    elements.compactMap { element in
        guard case .event(let event) = element else { return nil }
        return try? JSONValue(parsing: event.data)
    }
}

/// Checks an encoded Gemini stream: only unnamed `data:` frames holding JSON
/// objects (no comments, no `[DONE]`); every frame has `modelVersion` and
/// `responseId`; only the last frame has `finishReason` and
/// `usageMetadata` (or it is an `error` frame, or a blocked prompt without
/// candidates); function calls are whole, with object `args`, and never
/// carry synthesized ids.
package func checkGeminiStream(_ elements: [SSEElement]) -> [String] {
    var problems: [String] = []
    var frames: [JSONValue] = []
    for element in elements {
        guard case .event(let event) = element else {
            problems.append("non-data element \(element)")
            continue
        }
        if event.event != nil { problems.append("named event \(event.event ?? "")") }
        guard let json = try? JSONValue(parsing: event.data), case .object = json else {
            problems.append("invalid frame: \(event.data)")
            continue
        }
        frames.append(json)
    }
    guard let last = frames.last else { return problems + ["no frames"] }
    for (i, frame) in frames.enumerated() {
        let isLast = i == frames.count - 1
        if frame["error"] != nil {
            if !isLast { problems.append("frame after error") }
            continue
        }
        if frame["modelVersion"]?.stringValue == nil || frame["responseId"]?.stringValue == nil {
            problems.append("frame \(i) without modelVersion/responseId")
        }
        let candidate = frame["candidates"]?[0]
        if (candidate?["finishReason"] != nil) != isLast, candidate != nil {
            problems.append("finishReason on frame \(i) of \(frames.count)")
        }
        if frame["usageMetadata"] != nil, !isLast { problems.append("usageMetadata on frame \(i)") }
        if candidate == nil, !(isLast && frame["promptFeedback"] != nil) { problems.append("frame \(i) without candidates") }
        for part in candidate?["content"]?["parts"]?.arrayValue ?? [] {
            guard let call = part["functionCall"] else { continue }
            if let args = call["args"], args.objectValue == nil { problems.append("non-object args") }
            if let id = call["id"]?.stringValue, GeminiToolID.isSynthesized(id) { problems.append("synthesized id \(id) sent") }
        }
    }
    if last["error"] == nil, last["candidates"]?[0]?["finishReason"] == nil, last["promptFeedback"] == nil {
        problems.append("last frame without finishReason")
    }
    return problems
}
