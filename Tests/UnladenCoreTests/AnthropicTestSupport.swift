@_spi(Wire) import UnladenCore

let anthropicDefaults = AnthropicResponseDefaults(id: "msg_default", model: "default-model")

func decodeAnthropicStream(_ elements: [SSEElement]) throws -> (events: [WireEvent], warnings: [WireWarning]) {
    var decoder = AnthropicMessagesStreamDecoder()
    var events: [WireEvent] = []
    for element in elements {
        events += try decoder.decode(element)
    }
    events += decoder.finish()
    return (events, decoder.warnings)
}

func encodeAnthropicStream(
    _ events: [WireEvent],
    defaults: AnthropicResponseDefaults = anthropicDefaults,
) -> (elements: [SSEElement], warnings: [WireWarning]) {
    var encoder = AnthropicMessagesStreamEncoder(defaults: defaults)
    var elements: [SSEElement] = []
    for event in events {
        elements += encoder.encode(event)
    }
    elements += encoder.finish()
    return (elements, encoder.warnings)
}

/// The JSON payloads of a stream's events, with their SSE event names.
func anthropicPayloads(_ elements: [SSEElement]) -> [(name: String?, json: JSONValue)] {
    elements.compactMap { element in
        guard case .event(let event) = element, let json = try? JSONValue(parsing: event.data) else { return nil }
        return (event.event, json)
    }
}

/// Checks an encoded Anthropic stream: `message_start` first, one content
/// block open at a time with contiguous indices from 0, deltas that match
/// their block's type, event names equal to payload types, and an ending of
/// `message_delta` + `message_stop` or an `error` event.
func checkAnthropicStream(_ elements: [SSEElement]) -> [String] {
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
