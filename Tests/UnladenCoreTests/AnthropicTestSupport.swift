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
