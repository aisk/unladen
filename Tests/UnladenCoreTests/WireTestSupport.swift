import Foundation
@_spi(Wire) import UnladenCore

enum Fixtures {
    static var root: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func bytes(_ path: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent(path)))
    }

    static func json(_ path: String) throws -> JSONValue {
        try JSONValue(parsing: bytes(path))
    }

    /// File names (sorted) in a fixture directory with the given extension.
    static func names(_ directory: String, extension ext: String) throws -> [String] {
        let url = root.appendingPathComponent(directory)
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasSuffix(".\(ext)") }
            .sorted()
    }

    static func sse(_ path: String) throws -> [SSEElement] {
        var parser = SSEParser()
        let elements = parser.parse(try bytes(path))
        parser.finish()
        return elements
    }
}

extension JSONValue {
    /// The value with every object's keys sorted, for order-insensitive
    /// structural comparison.
    var canonical: JSONValue {
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
func checkEventSequence(_ events: [WireEvent]) -> [String] {
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
        case .textStart(let id): start(id, .text)
        case .textDelta(let id, _): delta(id, .text)
        case .textEnd(let id): end(id, .text)
        case .reasoningStart(let id, _): start(id, .reasoning)
        case .reasoningDelta(let id, _), .reasoningSignatureDelta(let id, _): delta(id, .reasoning)
        case .reasoningEnd(let id, _): end(id, .reasoning)
        case .refusalStart(let id): start(id, .refusal)
        case .refusalDelta(let id, _): delta(id, .refusal)
        case .refusalEnd(let id): end(id, .refusal)
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
func checkChatStream(_ elements: [SSEElement]) -> [String] {
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
                    if call["id"]?.stringValue == nil || call["function"]?["name"]?.stringValue == nil {
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

func decodeChatStream(_ elements: [SSEElement]) throws -> (events: [WireEvent], warnings: [WireWarning]) {
    var decoder = ChatCompletionsStreamDecoder()
    var events: [WireEvent] = []
    for element in elements {
        events += try decoder.decode(element)
    }
    events += decoder.finish()
    return (events, decoder.warnings)
}

let testDefaults = ChatResponseDefaults(id: "chatcmpl-default", model: "default-model", created: 1_700_000_000)

func encodeChatStream(_ events: [WireEvent], includeUsage: Bool = true) -> (elements: [SSEElement], warnings: [WireWarning]) {
    var encoder = ChatCompletionsStreamEncoder(defaults: testDefaults, includeUsage: includeUsage)
    var elements: [SSEElement] = []
    for event in events {
        elements += encoder.encode(event)
    }
    elements += encoder.finish()
    return (elements, encoder.warnings)
}
