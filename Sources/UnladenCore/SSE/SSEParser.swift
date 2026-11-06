/// An incremental `text/event-stream` parser following the WHATWG HTML
/// "Server-sent events" interpretation rules.
///
/// Feed byte chunks of any size with ``parse(_:into:)`` and call ``finish()``
/// at end of stream. Chunk boundaries may fall anywhere, including between
/// the CR and LF of a CRLF pair or inside a multi-byte UTF-8 sequence.
///
/// Behaviour per the spec:
/// - A UTF-8 BOM at the very start of the stream is skipped.
/// - Lines end at CRLF, LF or CR.
/// - `field:value`, `field: value` (one leading space removed), and `field`
///   alone (empty value) are accepted; unknown fields are ignored.
/// - Multiple `data` lines are joined with `\n`.
/// - A blank line dispatches the event; a block without any `data` field is
///   not dispatched. A block whose only data line is empty (`data:` then a
///   blank line) *is* dispatched with empty data: WHATWG appends a LF per
///   data line, so its data buffer is `"\n"`, not empty, and dispatches
///   after the final LF is removed.
/// - An `id` containing U+0000 is ignored; `retry` must be ASCII digits.
/// - At end of stream an incomplete line or undispatched block is discarded.
/// - Text is decoded as UTF-8 with replacement of invalid sequences.
///
/// Additions: comments and `retry` are surfaced as ``SSEElement`` values
/// rather than swallowed.
///
/// Memory is bounded: a line, or the data of one event, longer than
/// ``maxBufferSize`` bytes throws ``SSEParserError``. After a throw the
/// parser state is unspecified; call ``finish()`` before reusing it.
public struct SSEParser: Sendable {
    /// Default limit for ``maxBufferSize``: 16 MiB.
    public static let defaultMaxBufferSize = 16 << 20

    /// The longest line and the largest event data accepted, in bytes.
    public let maxBufferSize: Int

    /// The EventSource "last event ID buffer": the most recent `id` value,
    /// persisting across events (an empty `id` resets it to `""`).
    public private(set) var lastEventID: String = ""

    private var line: [UInt8] = []
    private var sawCR = false
    /// Bytes of a possible BOM seen so far; `nil` once past the stream start.
    private var bomMatched: Int? = 0

    private var dataBuffer: [UInt8] = []
    private var hasData = false
    private var eventType: String?
    private var blockID: String?

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    public init(maxBufferSize: Int = SSEParser.defaultMaxBufferSize) {
        self.maxBufferSize = maxBufferSize
    }

    /// Parses a chunk, calling `emit` for each element completed by it.
    public mutating func parse(
        _ chunk: some Sequence<UInt8>,
        into emit: (SSEElement) -> Void,
    ) throws(SSEParserError) {
        for byte in chunk {
            if let matched = bomMatched {
                if byte == Self.bom[matched] {
                    if matched == 2 { bomMatched = nil } else { bomMatched = matched + 1 }
                    continue
                }
                // Not a BOM: replay the partial match as ordinary bytes.
                bomMatched = nil
                for b in Self.bom[0..<matched] { try consume(b, emit) }
            }
            try consume(byte, emit)
        }
    }

    /// Parses a chunk and returns the completed elements.
    public mutating func parse(_ chunk: some Sequence<UInt8>) throws(SSEParserError) -> [SSEElement] {
        var elements: [SSEElement] = []
        try parse(chunk) { elements.append($0) }
        return elements
    }

    /// Signals end of stream. Per spec, pending partial data is discarded;
    /// the parser is reset (``lastEventID`` is kept) and can be reused.
    public mutating func finish() {
        line.removeAll(keepingCapacity: true)
        sawCR = false
        bomMatched = 0
        resetBlock()
    }

    private mutating func consume(_ byte: UInt8, _ emit: (SSEElement) -> Void) throws(SSEParserError) {
        switch byte {
        case 0x0A:
            if sawCR {
                sawCR = false // second half of CRLF
            } else {
                try processLine(emit)
            }
        case 0x0D:
            sawCR = true
            try processLine(emit)
        default:
            sawCR = false
            guard line.count < maxBufferSize else { throw SSEParserError(maxBufferSize: maxBufferSize) }
            line.append(byte)
        }
    }

    private mutating func processLine(_ emit: (SSEElement) -> Void) throws(SSEParserError) {
        defer { line.removeAll(keepingCapacity: true) }

        if line.isEmpty {
            dispatch(emit)
            return
        }

        let colon = line.firstIndex(of: UInt8(ascii: ":"))
        if colon == 0 {
            emit(.comment(Self.decode(Self.valueBytes(line[1...]))))
            return
        }
        let name = colon.map { line[..<$0] } ?? line[...]
        let value = colon.map { Self.valueBytes(line[($0 + 1)...]) } ?? []

        switch String(decoding: name, as: UTF8.self) {
        case "event":
            eventType = Self.decode(value)
        case "data":
            guard dataBuffer.count + (hasData ? 1 : 0) + value.count <= maxBufferSize else {
                throw SSEParserError(maxBufferSize: maxBufferSize)
            }
            if hasData { dataBuffer.append(0x0A) }
            dataBuffer.append(contentsOf: value)
            hasData = true
        case "id":
            if !value.contains(0) {
                let id = Self.decode(value)
                lastEventID = id
                blockID = id
            }
        case "retry":
            if !value.isEmpty, value.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
               let retry = Int(Self.decode(value))
            {
                emit(.retry(retry))
            }
        default:
            break
        }
    }

    private mutating func dispatch(_ emit: (SSEElement) -> Void) {
        defer { resetBlock() }
        guard hasData else { return }
        emit(.event(SSEEvent(event: eventType, data: Self.decode(dataBuffer[...]), id: blockID)))
    }

    private mutating func resetBlock() {
        dataBuffer.removeAll(keepingCapacity: true)
        hasData = false
        eventType = nil
        blockID = nil
    }

    private static func valueBytes(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        bytes.first == UInt8(ascii: " ") ? bytes.dropFirst() : bytes
    }

    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Thrown when a line or an event's data exceeds ``SSEParser/maxBufferSize``.
public struct SSEParserError: Error, Hashable, Sendable {
    public var maxBufferSize: Int

    public init(maxBufferSize: Int) {
        self.maxBufferSize = maxBufferSize
    }
}

/// Parses an async sequence of byte chunks into ``SSEElement`` values.
///
/// Errors from the base sequence and ``SSEParserError`` are rethrown; after
/// a throw the sequence ends (`next()` returns `nil`). Cancellation is
/// whatever the base sequence does; dropping the iterator drops the base
/// iterator.
public struct SSEElementSequence<Base: AsyncSequence>: AsyncSequence
    where Base.Element: Sequence, Base.Element.Element == UInt8
{
    public typealias Element = SSEElement

    let base: Base
    let maxBufferSize: Int

    public init(_ base: Base, maxBufferSize: Int = SSEParser.defaultMaxBufferSize) {
        self.base = base
        self.maxBufferSize = maxBufferSize
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), parser: SSEParser(maxBufferSize: maxBufferSize))
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var parser: SSEParser
        var pending: [SSEElement] = []
        var pendingIndex = 0
        var finished = false

        public mutating func next() async throws -> SSEElement? {
            while true {
                if pendingIndex < pending.count {
                    defer { pendingIndex += 1 }
                    return pending[pendingIndex]
                }
                guard !finished else { return nil }
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
                do {
                    guard let chunk = try await base.next(isolation: #isolation) else {
                        finished = true
                        parser.finish()
                        return nil
                    }
                    try parser.parse(chunk) { pending.append($0) }
                } catch {
                    finished = true
                    pending.removeAll()
                    throw error
                }
            }
        }
    }
}

extension SSEElementSequence: Sendable where Base: Sendable {}

extension AsyncSequence where Element: Sequence, Element.Element == UInt8 {
    /// Interprets this sequence of byte chunks as a `text/event-stream`.
    public func sseElements(maxBufferSize: Int = SSEParser.defaultMaxBufferSize) -> SSEElementSequence<Self> {
        SSEElementSequence(self, maxBufferSize: maxBufferSize)
    }
}
