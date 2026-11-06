import Testing
import UnladenCore

private let representativeStream: [UInt8] = [0xEF, 0xBB, 0xBF] + Array((
    ": ping\r\n"
        + "event: message_start\r\n"
        + "data: {\"a\":1}\r\n"
        + "\r\n"
        + "data: line1\n"
        + "data:line2\n"
        + "data\n"
        + "id: 42\n"
        + "\n"
        + "retry: 3000\r"
        + "retry: 3s\r"
        + "event: noData\r"
        + "id: 7\r"
        + "\r"
        + ":\r\n"
        + "data:  two spaces\r"
        + "foo: bar\r"
        + "id\r"
        + "\r\n"
        + "data: é🎉\n\n"
        + "event: x\n"
        + "data: incomplete\n"
).utf8)

private let expectedElements: [SSEElement] = [
    .comment("ping"),
    .event(SSEEvent(event: "message_start", data: #"{"a":1}"#)),
    .event(SSEEvent(data: "line1\nline2\n", id: "42")),
    .retry(3000),
    .comment(""),
    .event(SSEEvent(data: " two spaces", id: "")),
    .event(SSEEvent(data: "é🎉")),
]

private func parseAll(_ chunks: [ArraySlice<UInt8>]) -> (elements: [SSEElement], lastEventID: String) {
    var parser = SSEParser()
    var elements: [SSEElement] = []
    for chunk in chunks { try! parser.parse(chunk) { elements.append($0) } }
    parser.finish()
    return (elements, parser.lastEventID)
}

@Suite struct SSEParserTests {
    @Test func wholeStream() {
        let result = parseAll([representativeStream[...]])
        #expect(result.elements == expectedElements)
        #expect(result.lastEventID == "")
    }

    @Test func everySingleSplitPosition() {
        let bytes = representativeStream
        for split in 0...bytes.count {
            let result = parseAll([bytes[..<split], bytes[split...]])
            #expect(result.elements == expectedElements, "split at \(split)")
        }
    }

    @Test func everyPairOfSplitPositions() {
        let bytes = representativeStream
        for i in 0...bytes.count {
            for j in i...bytes.count {
                let result = parseAll([bytes[..<i], bytes[i..<j], bytes[j...]]).elements
                if result != expectedElements {
                    Issue.record("splits at \(i), \(j): \(result)")
                    return
                }
            }
        }
    }

    @Test func oneBytePerChunk() {
        let chunks = representativeStream.indices.map { representativeStream[$0...$0] }
        #expect(parseAll(chunks).elements == expectedElements)
    }

    @Test func crAtChunkEndFollowedByLF() {
        let a = Array("data: a\r".utf8)[...]
        let b = Array("\n\r\ndata: b\r\n\r\n".utf8)[...]
        #expect(parseAll([a, b]).elements == [.event(SSEEvent(data: "a")), .event(SSEEvent(data: "b"))])
    }

    @Test func bomOnlySkippedAtStart() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let bytes = bom + Array("data: 1\n\n".utf8) + bom + Array("data: 2\n\n".utf8)
        // The second BOM becomes part of the field name "\u{FEFF}data", which is unknown.
        #expect(parseAll([bytes[...]]).elements == [.event(SSEEvent(data: "1"))])
        // A partial BOM is not swallowed.
        let partial: [UInt8] = [0xEF, 0xBB] + Array("\ndata: x\n\n".utf8)
        #expect(parseAll([partial[...]]).elements == [.event(SSEEvent(data: "x"))])
    }

    @Test func idPersistsAndNullIdIsIgnored() throws {
        var parser = SSEParser()
        let elements = try parser.parse(Array("id: 1\ndata: a\n\ndata: b\n\nid: x\u{0}y\ndata: c\n\n".utf8))
        #expect(elements == [
            .event(SSEEvent(data: "a", id: "1")),
            .event(SSEEvent(data: "b")),
            .event(SSEEvent(data: "c")),
        ])
        #expect(parser.lastEventID == "1")
    }

    @Test func eventTypeResetsAfterEachBlock() throws {
        var parser = SSEParser()
        let elements = try parser.parse(Array("event: a\n\ndata: 1\n\nevent: b\nevent: c\ndata: 2\n\n".utf8))
        #expect(elements == [.event(SSEEvent(data: "1")), .event(SSEEvent(event: "c", data: "2"))])
    }

    @Test func asyncSequenceAdapter() async throws {
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        let bytes = representativeStream
        var start = 0
        var size = 1
        while start < bytes.count {
            let end = min(bytes.count, start + size)
            continuation.yield(Array(bytes[start..<end]))
            start = end
            size = size % 7 + 1
        }
        continuation.finish()

        var elements: [SSEElement] = []
        for try await element in stream.sseElements() {
            elements.append(element)
        }
        #expect(elements == expectedElements)
    }
}

@Suite struct SSEWriterTests {
    @Test func eventFrame() {
        let bytes = SSEWriter.encode(SSEEvent(event: "message_delta", data: "{\"a\":1}\nsecond", id: "9"))
        #expect(String(decoding: bytes, as: UTF8.self) == "event: message_delta\nid: 9\ndata: {\"a\":1}\ndata: second\n\n")
    }

    @Test func emptyDataAndComments() {
        #expect(String(decoding: SSEWriter.encode(SSEEvent(data: "")), as: UTF8.self) == "data:\n\n")
        #expect(String(decoding: SSEWriter.encodeComment("ping"), as: UTF8.self) == ": ping\n")
        #expect(String(decoding: SSEWriter.encodeComment(""), as: UTF8.self) == ":\n")
        #expect(String(decoding: SSEWriter.encodeComment("a\nb"), as: UTF8.self) == ": a\n: b\n")
        #expect(String(decoding: SSEWriter.encode(.retry(1500)), as: UTF8.self) == "retry: 1500\n")
    }

    @Test func lineBreaksAreSanitized() {
        let bytes = SSEWriter.encode(SSEEvent(event: "a\nb", data: "x\r\ny\rz", id: "1\r2\u{0}"))
        #expect(String(decoding: bytes, as: UTF8.self) == "event: ab\nid: 12\ndata: x\ndata: y\ndata: z\n\n")
    }

    @Test func roundTripsThroughParser() throws {
        let elements: [SSEElement] = [
            .comment(" leading space"),
            .event(SSEEvent(event: "e", data: " padded \n\nlines ", id: "abc")),
            .retry(10),
            .event(SSEEvent(data: "")),
            .comment("é"),
            .event(SSEEvent(data: "{\"json\":true}")),
        ]
        var bytes: [UInt8] = []
        for element in elements { SSEWriter.encode(element, into: &bytes) }
        var parser = SSEParser()
        #expect(try parser.parse(bytes) == elements)
    }
}

@Suite struct SSELimitTests {
    @Test func emptyDataLineDispatchesEmptyEvent() throws {
        // WHATWG: the data buffer is "\n" (not empty), so the event fires with "".
        var parser = SSEParser()
        #expect(try parser.parse(Array("data:\n\n".utf8)) == [.event(SSEEvent(data: ""))])
        #expect(try parser.parse(Array("event: x\n\n".utf8)) == [])
    }

    @Test func overlongLineThrows() {
        var parser = SSEParser(maxBufferSize: 16)
        #expect(throws: SSEParserError(maxBufferSize: 16)) {
            try parser.parse(Array(": \(String(repeating: "x", count: 32))\n".utf8))
        }
    }

    @Test func overlongEventDataThrows() throws {
        var parser = SSEParser(maxBufferSize: 16)
        // Each line fits; their sum does not.
        #expect(try parser.parse(Array("data: 0123456789\n".utf8)) == [])
        #expect(throws: SSEParserError(maxBufferSize: 16)) {
            try parser.parse(Array("data: 0123456789\n".utf8))
        }
        parser.finish()
        #expect(try parser.parse(Array("data: ok\n\n".utf8)) == [.event(SSEEvent(data: "ok"))])
    }

    @Test func dataAtTheLimitIsAccepted() throws {
        // The limit applies to the whole line, field name included.
        var parser = SSEParser(maxBufferSize: 15)
        #expect(try parser.parse(Array("data:0123456789\n\n".utf8)) == [.event(SSEEvent(data: "0123456789"))])
        var tight = SSEParser(maxBufferSize: 14)
        #expect(throws: SSEParserError.self) { try tight.parse(Array("data:0123456789\n\n".utf8)) }
    }

    @Test func sequenceEndsAfterAThrow() async throws {
        struct Boom: Error {}
        // A base that would keep producing after it throws.
        struct Chunks: AsyncSequence, Sendable {
            typealias Element = [UInt8]
            struct AsyncIterator: AsyncIteratorProtocol {
                var count = 0
                mutating func next() async throws -> [UInt8]? {
                    count += 1
                    if count == 2 { throw Boom() }
                    return Array("data: \(count)\n\n".utf8)
                }
            }
            func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
        }
        var iterator = Chunks().sseElements().makeAsyncIterator()
        #expect(try await iterator.next() == .event(SSEEvent(data: "1")))
        await #expect(throws: Boom.self) { try await iterator.next() }
        #expect(try await iterator.next() == nil)

        // A parser error ends it too.
        var limited = Chunks().sseElements(maxBufferSize: 2).makeAsyncIterator()
        await #expect(throws: SSEParserError.self) { try await limited.next() }
        #expect(try await limited.next() == nil)
    }
}
