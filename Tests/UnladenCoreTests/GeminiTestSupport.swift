@_spi(Wire) import UnladenCore

let geminiDefaults = GeminiResponseDefaults(id: "resp-default", model: "default-model")

func parseGeminiRequest(_ name: String, model: String = "gemini-3-pro-preview", stream: Bool = true) throws -> WireDecoded<WireRequest> {
    try GeminiCodec.parseRequest(Fixtures.bytes("Gemini/requests/\(name)"), model: model, stream: stream)
}

func decodeGeminiStream(_ elements: [SSEElement], origin: WireSystemID? = "gemini") throws -> (events: [WireEvent], warnings: [WireWarning]) {
    var decoder = GeminiStreamDecoder(origin: origin)
    var events: [WireEvent] = []
    for element in elements {
        events += try decoder.decode(element)
    }
    events += decoder.finish()
    return (events, decoder.warnings)
}

func encodeGeminiStream(
    _ events: [WireEvent],
    defaults: GeminiResponseDefaults = geminiDefaults,
) -> (elements: [SSEElement], warnings: [WireWarning]) {
    var encoder = GeminiStreamEncoder(defaults: defaults)
    var elements: [SSEElement] = []
    for event in events {
        elements += encoder.encode(event)
    }
    elements += encoder.finish()
    return (elements, encoder.warnings)
}

/// The JSON payloads of a Gemini stream's frames.
func geminiChunks(_ elements: [SSEElement]) -> [JSONValue] {
    elements.compactMap { element in
        guard case .event(let event) = element else { return nil }
        return try? JSONValue(parsing: event.data)
    }
}

/// All parts of a Gemini stream, in order.
func geminiParts(_ elements: [SSEElement]) -> [JSONValue] {
    geminiChunks(elements).flatMap { $0["candidates"]?[0]?["content"]?["parts"]?.arrayValue ?? [] }
}

/// Checks an encoded Gemini stream: only unnamed `data:` frames holding JSON
/// objects (no comments, no `[DONE]`); every frame has `modelVersion` and
/// `responseId`; only the last frame has `finishReason` and
/// `usageMetadata` (or it is an `error` frame, or a blocked prompt without
/// candidates); function calls are whole, with object `args`, and never
/// carry synthesized ids.
func checkGeminiStream(_ elements: [SSEElement]) -> [String] {
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
