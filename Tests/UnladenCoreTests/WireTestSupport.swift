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
        let elements = try parser.parse(try bytes(path))
        parser.finish()
        return elements
    }
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
