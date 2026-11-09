/// An error thrown when input is not valid RFC 8259 JSON.
public struct JSONParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: Hashable, Sendable {
        case unexpectedEndOfInput
        /// A byte that cannot start or continue the current production.
        case unexpectedByte(UInt8)
        /// A number that does not match the RFC 8259 grammar (e.g. `01`, `1.`, `-`).
        case invalidNumber
        /// A backslash escape other than `\" \\ \/ \b \f \n \r \t \uXXXX`.
        case invalidEscape
        /// A `\u` escape that is malformed or forms an unpaired surrogate.
        case invalidUnicodeEscape
        /// A raw control character (U+0000 to U+001F) inside a string.
        case unescapedControlCharacter
        /// Bytes that are not well-formed UTF-8 inside a string.
        case invalidUTF8
        case nestingTooDeep(limit: Int)
        /// Only thrown with ``JSONParser/DuplicateKeyPolicy/reject``.
        case duplicateKey(String)
        /// Non-whitespace bytes after the top-level value.
        case trailingData
        /// A `/*` comment without its `*/` (only with
        /// ``JSONParser/Options-swift.struct/allowsComments``).
        case unterminatedComment
    }

    public var kind: Kind
    /// Byte offset into the input where the problem was detected.
    public var offset: Int

    public init(_ kind: Kind, offset: Int) {
        self.kind = kind
        self.offset = offset
    }

    public var description: String { "JSON parse error at byte \(offset): \(kind)" }
}

/// A strict RFC 8259 JSON parser over UTF-8 bytes.
///
/// - Any value is accepted at top level; surrounding whitespace is allowed;
///   a leading BOM is not.
/// - Strings must be well-formed UTF-8; `\u` escapes must not leave an unpaired
///   surrogate (Swift strings cannot hold one).
/// - Number literals are validated and kept verbatim (see ``JSONNumber``).
/// - Nesting is limited by ``Options-swift.struct/maxDepth``.
/// - Options allow comments and trailing commas (JSONC, for files people
///   write), and record where each value starts.
public enum JSONParser {
    /// What to do when an object contains the same key twice.
    public enum DuplicateKeyPolicy: Hashable, Sendable {
        /// Keep the key where it first occurs in the object, with the value
        /// of its last occurrence (whose start is the offset recorded for
        /// it). This matches JavaScript's `JSON.parse` and Python's `json`,
        /// i.e. what most upstream providers will see, so the gateway forwards
        /// the same meaning the client most likely intended.
        case lastValueWins
        /// Throw ``JSONParseError/Kind/duplicateKey(_:)``.
        case reject
    }

    public struct Options: Hashable, Sendable {
        /// Maximum number of nested arrays/objects. The parser is recursive,
        /// so this also bounds stack use.
        public var maxDepth: Int
        public var duplicateKeys: DuplicateKeyPolicy
        /// `// line` and `/* block */` comments wherever whitespace may be.
        public var allowsComments: Bool
        /// A comma after the last element of an array or object.
        public var allowsTrailingCommas: Bool

        public init(
            maxDepth: Int = 256, duplicateKeys: DuplicateKeyPolicy = .lastValueWins,
            allowsComments: Bool = false, allowsTrailingCommas: Bool = false,
        ) {
            self.maxDepth = maxDepth
            self.duplicateKeys = duplicateKeys
            self.allowsComments = allowsComments
            self.allowsTrailingCommas = allowsTrailingCommas
        }

        /// JSON with comments and trailing commas, duplicate keys refused:
        /// for files people edit.
        public static var jsonc: Options {
            Options(duplicateKeys: .reject, allowsComments: true, allowsTrailingCommas: true)
        }
    }

    /// Where each value starts in the input: byte offsets by path (object
    /// keys, and array indices written in decimal); the top-level value's
    /// path is empty.
    public typealias Offsets = [[String]: Int]

    public static func parse(
        _ bytes: some Collection<UInt8>,
        options: Options = Options(),
    ) throws(JSONParseError) -> JSONValue {
        let result: Result<JSONValue, JSONParseError>? = bytes.withContiguousStorageIfAvailable { buffer in
            parse(buffer: buffer, options: options)
        }
        if let result { return try result.get() }
        let array = Array(bytes)
        return try array.withUnsafeBufferPointer { parse(buffer: $0, options: options) }.get()
    }

    /// Parses `bytes` and notes where each value starts.
    public static func parseWithOffsets(
        _ bytes: some Collection<UInt8>,
        options: Options = Options(),
    ) throws(JSONParseError) -> (value: JSONValue, offsets: Offsets) {
        let array = Array(bytes)
        let result: Result<(value: JSONValue, offsets: Offsets), JSONParseError> = array.withUnsafeBufferPointer { buffer in
            var parser = Parser(bytes: buffer, options: options)
            parser.offsets = [:]
            do throws(JSONParseError) {
                let value = try parser.parseDocument()
                return .success((value, parser.offsets ?? [:]))
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    private static func parse(
        buffer: UnsafeBufferPointer<UInt8>,
        options: Options,
    ) -> Result<JSONValue, JSONParseError> {
        var parser = Parser(bytes: buffer, options: options)
        return Result { () throws(JSONParseError) in try parser.parseDocument() }
    }
}

extension JSONValue {
    /// Parses JSON from UTF-8 bytes. See ``JSONParser``.
    public init(parsing bytes: some Collection<UInt8>, options: JSONParser.Options = .init()) throws(JSONParseError) {
        self = try JSONParser.parse(bytes, options: options)
    }

    /// Parses JSON from a string's UTF-8 representation.
    public init(parsing string: String, options: JSONParser.Options = .init()) throws(JSONParseError) {
        self = try JSONParser.parse(Array(string.utf8), options: options)
    }
}

private enum ASCII {
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/")
    static let comma = UInt8(ascii: ",")
    static let colon = UInt8(ascii: ":")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let minus = UInt8(ascii: "-")
    static let plus = UInt8(ascii: "+")
    static let dot = UInt8(ascii: ".")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let lowerE = UInt8(ascii: "e")
    static let upperE = UInt8(ascii: "E")
}

private struct Parser {
    let bytes: UnsafeBufferPointer<UInt8>
    let options: JSONParser.Options
    var position = 0
    var depth = 0
    /// Scratch buffer for strings containing escapes.
    var scratch: [UInt8] = []
    /// Recorded when not `nil`: where each value starts, by ``path``.
    var offsets: JSONParser.Offsets?
    var path: [String] = []

    init(bytes: UnsafeBufferPointer<UInt8>, options: JSONParser.Options) {
        self.bytes = bytes
        self.options = options
    }

    func error(_ kind: JSONParseError.Kind, at offset: Int? = nil) -> JSONParseError {
        JSONParseError(kind, offset: offset ?? position)
    }

    mutating func parseDocument() throws(JSONParseError) -> JSONValue {
        try skipWhitespace()
        let value = try parseValue()
        try skipWhitespace()
        guard position == bytes.count else { throw error(.trailingData) }
        return value
    }

    mutating func skipWhitespace() throws(JSONParseError) {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            case ASCII.slash where options.allowsComments && position + 1 < bytes.count:
                let start = position
                switch bytes[position + 1] {
                case ASCII.slash:
                    position += 2
                    while position < bytes.count, bytes[position] != 0x0A { position += 1 }
                case UInt8(ascii: "*"):
                    position += 2
                    while true {
                        guard position + 1 < bytes.count else { throw error(.unterminatedComment, at: start) }
                        if bytes[position] == UInt8(ascii: "*"), bytes[position + 1] == ASCII.slash { break }
                        position += 1
                    }
                    position += 2
                default: return
                }
            default: return
            }
        }
    }

    func peek() throws(JSONParseError) -> UInt8 {
        guard position < bytes.count else { throw error(.unexpectedEndOfInput) }
        return bytes[position]
    }

    mutating func parseValue() throws(JSONParseError) -> JSONValue {
        let byte = try peek()
        if offsets != nil { offsets![path] = position }
        switch byte {
        case ASCII.openBrace: return .object(try parseObject())
        case ASCII.openBracket: return .array(try parseArray())
        case ASCII.quote: return .string(try parseString())
        case ASCII.minus, ASCII.zero...ASCII.nine: return .number(try parseNumber())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        default: throw error(.unexpectedByte(byte))
        }
    }

    mutating func expectLiteral(_ literal: StaticString) throws(JSONParseError) {
        let utf8 = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
        for expected in utf8 {
            let byte = try peek()
            guard byte == expected else { throw error(.unexpectedByte(byte)) }
            position += 1
        }
    }

    mutating func enterContainer() throws(JSONParseError) {
        depth += 1
        guard depth <= options.maxDepth else { throw error(.nestingTooDeep(limit: options.maxDepth)) }
    }

    mutating func parseArray() throws(JSONParseError) -> [JSONValue] {
        try enterContainer()
        position += 1 // [
        var elements: [JSONValue] = []
        try skipWhitespace()
        if try peek() == ASCII.closeBracket {
            position += 1
            depth -= 1
            return elements
        }
        while true {
            try skipWhitespace()
            if offsets != nil { path.append(String(elements.count)) }
            elements.append(try parseValue())
            if offsets != nil { path.removeLast() }
            try skipWhitespace()
            let byte = try peek()
            position += 1
            if byte == ASCII.comma {
                if options.allowsTrailingCommas {
                    try skipWhitespace()
                    if try peek() == ASCII.closeBracket { position += 1; break }
                }
                continue
            }
            if byte == ASCII.closeBracket { break }
            throw error(.unexpectedByte(byte), at: position - 1)
        }
        depth -= 1
        return elements
    }

    mutating func parseObject() throws(JSONParseError) -> JSONObject {
        try enterContainer()
        position += 1 // {
        var object = JSONObject()
        try skipWhitespace()
        if try peek() == ASCII.closeBrace {
            position += 1
            depth -= 1
            return object
        }
        while true {
            try skipWhitespace()
            let keyOffset = position
            let byte = try peek()
            guard byte == ASCII.quote else { throw error(.unexpectedByte(byte)) }
            let key = try parseString()
            try skipWhitespace()
            let colon = try peek()
            guard colon == ASCII.colon else { throw error(.unexpectedByte(colon)) }
            position += 1
            try skipWhitespace()
            if offsets != nil { path.append(key) }
            let value = try parseValue()
            if offsets != nil { path.removeLast() }
            if let existing = object.index(forKey: key) {
                switch options.duplicateKeys {
                case .lastValueWins: object.replaceValue(at: existing, with: value)
                case .reject: throw error(.duplicateKey(key), at: keyOffset)
                }
            } else {
                object.appendUnique(key, value)
            }
            try skipWhitespace()
            let separator = try peek()
            position += 1
            if separator == ASCII.comma {
                if options.allowsTrailingCommas {
                    try skipWhitespace()
                    if try peek() == ASCII.closeBrace { position += 1; break }
                }
                continue
            }
            if separator == ASCII.closeBrace { break }
            throw error(.unexpectedByte(separator), at: position - 1)
        }
        depth -= 1
        return object
    }

    mutating func parseNumber() throws(JSONParseError) -> JSONNumber {
        let start = position
        func isDigit(_ b: UInt8) -> Bool { b >= ASCII.zero && b <= ASCII.nine }
        func current() -> UInt8? { position < bytes.count ? bytes[position] : nil }

        if current() == ASCII.minus { position += 1 }
        guard let first = current(), isDigit(first) else { throw error(.invalidNumber) }
        position += 1
        if first == ASCII.zero {
            if let next = current(), isDigit(next) { throw error(.invalidNumber) }
        } else {
            while let b = current(), isDigit(b) { position += 1 }
        }
        if current() == ASCII.dot {
            position += 1
            guard let b = current(), isDigit(b) else { throw error(.invalidNumber) }
            while let b = current(), isDigit(b) { position += 1 }
        }
        if let e = current(), e == ASCII.lowerE || e == ASCII.upperE {
            position += 1
            if let sign = current(), sign == ASCII.plus || sign == ASCII.minus { position += 1 }
            guard let b = current(), isDigit(b) else { throw error(.invalidNumber) }
            while let b = current(), isDigit(b) { position += 1 }
        }
        return JSONNumber(validatedLiteral: UnsafeBufferPointer(rebasing: bytes[start..<position]))
    }

    /// Parses a string starting at the opening quote.
    mutating func parseString() throws(JSONParseError) -> String {
        position += 1 // opening quote
        let start = position
        // Fast path: no escapes.
        while position < bytes.count {
            let byte = bytes[position]
            if byte == ASCII.quote {
                let raw = UnsafeBufferPointer(rebasing: bytes[start..<position])
                try validateUTF8(raw, baseOffset: start)
                position += 1
                return String(decoding: raw, as: UTF8.self)
            }
            if byte == ASCII.backslash { break }
            if byte < 0x20 { throw error(.unescapedControlCharacter) }
            position += 1
        }
        guard position < bytes.count else { throw error(.unexpectedEndOfInput) }

        // Slow path: copy segments and decode escapes into the scratch buffer.
        scratch.removeAll(keepingCapacity: true)
        var segmentStart = start
        while true {
            guard position < bytes.count else { throw error(.unexpectedEndOfInput) }
            let byte = bytes[position]
            if byte == ASCII.quote || byte == ASCII.backslash {
                let segment = UnsafeBufferPointer(rebasing: bytes[segmentStart..<position])
                try validateUTF8(segment, baseOffset: segmentStart)
                scratch.append(contentsOf: segment)
                if byte == ASCII.quote {
                    position += 1
                    return String(decoding: scratch, as: UTF8.self)
                }
                try parseEscape()
                segmentStart = position
                continue
            }
            if byte < 0x20 { throw error(.unescapedControlCharacter) }
            position += 1
        }
    }

    /// Decodes one escape at `position` (the backslash) into `scratch`.
    mutating func parseEscape() throws(JSONParseError) {
        let escapeStart = position
        position += 1
        guard position < bytes.count else { throw error(.unexpectedEndOfInput) }
        let byte = bytes[position]
        position += 1
        switch byte {
        case ASCII.quote: scratch.append(ASCII.quote)
        case ASCII.backslash: scratch.append(ASCII.backslash)
        case ASCII.slash: scratch.append(ASCII.slash)
        case UInt8(ascii: "b"): scratch.append(0x08)
        case UInt8(ascii: "f"): scratch.append(0x0C)
        case UInt8(ascii: "n"): scratch.append(0x0A)
        case UInt8(ascii: "r"): scratch.append(0x0D)
        case UInt8(ascii: "t"): scratch.append(0x09)
        case UInt8(ascii: "u"):
            let high = try parseHex4()
            var scalarValue = UInt32(high)
            if (0xD800...0xDBFF).contains(high) {
                // Must be followed by a \u low surrogate.
                guard position + 1 < bytes.count,
                      bytes[position] == ASCII.backslash,
                      bytes[position + 1] == UInt8(ascii: "u")
                else { throw error(.invalidUnicodeEscape, at: escapeStart) }
                position += 2
                let low = try parseHex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw error(.invalidUnicodeEscape, at: escapeStart) }
                scalarValue = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(high) {
                throw error(.invalidUnicodeEscape, at: escapeStart)
            }
            // Non-surrogate values are always valid scalars.
            scratch.append(contentsOf: UTF8.encode(Unicode.Scalar(scalarValue)!)!)
        default:
            throw error(.invalidEscape, at: escapeStart)
        }
    }

    mutating func parseHex4() throws(JSONParseError) -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard position < bytes.count else { throw error(.unexpectedEndOfInput) }
            let byte = bytes[position]
            let digit: UInt8
            switch byte {
            case ASCII.zero...ASCII.nine: digit = byte - ASCII.zero
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw error(.invalidUnicodeEscape)
            }
            value = value << 4 | UInt16(digit)
            position += 1
        }
        return value
    }

    /// Validates well-formed UTF-8 (Unicode Table 3-7).
    func validateUTF8(_ buffer: UnsafeBufferPointer<UInt8>, baseOffset: Int) throws(JSONParseError) {
        var i = 0
        let n = buffer.count
        while i < n {
            let b0 = buffer[i]
            if b0 < 0x80 { i += 1; continue }
            func cont(_ offset: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
                i + offset < n && range.contains(buffer[i + offset])
            }
            let length: Int
            switch b0 {
            case 0xC2...0xDF:
                length = cont(1) ? 2 : 0
            case 0xE0:
                length = cont(1, 0xA0...0xBF) && cont(2) ? 3 : 0
            case 0xE1...0xEC, 0xEE...0xEF:
                length = cont(1) && cont(2) ? 3 : 0
            case 0xED:
                length = cont(1, 0x80...0x9F) && cont(2) ? 3 : 0
            case 0xF0:
                length = cont(1, 0x90...0xBF) && cont(2) && cont(3) ? 4 : 0
            case 0xF1...0xF3:
                length = cont(1) && cont(2) && cont(3) ? 4 : 0
            case 0xF4:
                length = cont(1, 0x80...0x8F) && cont(2) && cont(3) ? 4 : 0
            default:
                length = 0
            }
            guard length > 0 else { throw error(.invalidUTF8, at: baseOffset + i) }
            i += length
        }
    }
}
