@_spi(Wire) import UnladenCore
import UnladenTestSupport

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

/// All parts of a Gemini stream, in order.
func geminiParts(_ elements: [SSEElement]) -> [JSONValue] {
    geminiChunks(elements).flatMap { $0["candidates"]?[0]?["content"]?["parts"]?.arrayValue ?? [] }
}
