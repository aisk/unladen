@_spi(Wire) import UnladenCore
import UnladenTestSupport

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

/// The `response` object of a stream's final event.
func finalResponse(_ elements: [SSEElement]) -> JSONValue? {
    responsesPayloads(elements).last { ["response.completed", "response.incomplete", "response.failed"].contains($0.name ?? "") }?
        .json["response"]
}
