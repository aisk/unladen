@_spi(Wire) import UnladenCore

let responsesDefaults = ResponsesResponseDefaults(id: "resp_default", model: "default-model", created: 1_700_000_000)

func decodeResponsesStream(_ elements: [SSEElement]) throws -> (events: [WireEvent], warnings: [WireWarning]) {
    var decoder = ResponsesStreamDecoder()
    var events: [WireEvent] = []
    for element in elements {
        events += try decoder.decode(element)
    }
    events += decoder.finish()
    return (events, decoder.warnings)
}

func encodeResponsesStream(
    _ events: [WireEvent],
    defaults: ResponsesResponseDefaults = responsesDefaults,
) -> (elements: [SSEElement], warnings: [WireWarning]) {
    var encoder = ResponsesStreamEncoder(defaults: defaults)
    var elements: [SSEElement] = []
    for event in events {
        elements += encoder.encode(event)
    }
    elements += encoder.finish()
    return (elements, encoder.warnings)
}

/// The JSON payloads of a stream's events, with their SSE event names.
func responsesPayloads(_ elements: [SSEElement]) -> [(name: String?, json: JSONValue)] {
    elements.compactMap { element in
        guard case .event(let event) = element, let json = try? JSONValue(parsing: event.data) else { return nil }
        return (event.event, json)
    }
}

/// The `response` object of a stream's final event.
func finalResponse(_ elements: [SSEElement]) -> JSONValue? {
    responsesPayloads(elements).last { ["response.completed", "response.incomplete", "response.failed"].contains($0.name ?? "") }?
        .json["response"]
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
func checkResponsesStream(_ elements: [SSEElement]) -> [String] {
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
