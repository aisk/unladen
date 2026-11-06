/// Deterministic compact JSON encoding.
///
/// - No insignificant whitespace.
/// - Object keys in stored order (see ``JSONObject``).
/// - Numbers written as their literal text (see ``JSONNumber``).
/// - Strings: only `"`, `\` and control characters U+0000–U+001F are escaped,
///   using `\b \f \n \r \t` where available and lowercase `\u00xx` otherwise.
///   `/`, `<`, `>`, `&`, DEL and all non-ASCII text are written as raw UTF-8.
///
/// The output is a pure function of the value: equal values produce equal bytes.
extension JSONValue {
    /// The compact UTF-8 encoding of this value.
    public func encoded() -> [UInt8] {
        var output: [UInt8] = []
        encode(into: &output)
        return output
    }

    /// Appends the compact UTF-8 encoding of this value to `output`.
    public func encode(into output: inout [UInt8]) {
        switch self {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .number(let number):
            output.append(contentsOf: number.literal.utf8)
        case .string(let string):
            JSONValue.encodeString(string, into: &output)
        case .array(let elements):
            output.append(UInt8(ascii: "["))
            for (i, element) in elements.enumerated() {
                if i > 0 { output.append(UInt8(ascii: ",")) }
                element.encode(into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let object):
            output.append(UInt8(ascii: "{"))
            for i in object.indices {
                if i > 0 { output.append(UInt8(ascii: ",")) }
                JSONValue.encodeString(object.keys[i], into: &output)
                output.append(UInt8(ascii: ":"))
                object.values[i].encode(into: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    /// Appends `string` as a quoted, escaped JSON string.
    public static func encodeString(_ string: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        var string = string
        string.withUTF8 { utf8 in
            var runStart = 0
            for i in 0..<utf8.count {
                let byte = utf8[i]
                guard byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") else { continue }
                output.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart..<i]))
                runStart = i + 1
                output.append(UInt8(ascii: "\\"))
                switch byte {
                case UInt8(ascii: "\""): output.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): output.append(UInt8(ascii: "\\"))
                case 0x08: output.append(UInt8(ascii: "b"))
                case 0x0C: output.append(UInt8(ascii: "f"))
                case 0x0A: output.append(UInt8(ascii: "n"))
                case 0x0D: output.append(UInt8(ascii: "r"))
                case 0x09: output.append(UInt8(ascii: "t"))
                default:
                    let hex: [UInt8] = Array("0123456789abcdef".utf8)
                    output.append(contentsOf: "u00".utf8)
                    output.append(hex[Int(byte >> 4)])
                    output.append(hex[Int(byte & 0x0F)])
                }
            }
            output.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart..<utf8.count]))
        }
        output.append(UInt8(ascii: "\""))
    }
}
