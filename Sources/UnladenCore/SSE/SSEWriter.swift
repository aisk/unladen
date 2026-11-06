/// Encodes ``SSEElement`` values as `text/event-stream` frame bytes.
///
/// Output is deterministic, uses LF line endings, and always ends with the
/// terminating blank line for events, so each call yields a complete frame
/// that can be written to the client immediately.
///
/// - Events are written as `event:`, `id:`, then one `data:` line per line of
///   ``SSEEvent/data`` (split at CRLF, LF or CR, so data containing line
///   breaks round-trips as `\n`-joined text). Fields are written `name: value`,
///   or `name:` when the value is empty.
/// - `event` and `id` values cannot contain line breaks; CR and LF are
///   removed from them. U+0000 is removed from `id` (parsers ignore such ids).
/// - Comments are written as `: text` lines; multi-line text becomes several
///   comment lines. A comment frame is not followed by a blank line, so it
///   never dispatches or terminates an event (`:\n` is also valid on its own).
public enum SSEWriter {
    public static func encode(_ element: SSEElement) -> [UInt8] {
        var output: [UInt8] = []
        encode(element, into: &output)
        return output
    }

    public static func encode(_ event: SSEEvent) -> [UInt8] {
        encode(.event(event))
    }

    public static func encodeComment(_ text: String) -> [UInt8] {
        encode(.comment(text))
    }

    public static func encode(_ element: SSEElement, into output: inout [UInt8]) {
        switch element {
        case .event(let event):
            if let type = event.event {
                writeField("event", sanitized(type, removingNUL: false), into: &output)
            }
            if let id = event.id {
                writeField("id", sanitized(id, removingNUL: true), into: &output)
            }
            for line in lines(event.data) {
                writeField("data", line, into: &output)
            }
            output.append(0x0A)
        case .comment(let text):
            for line in lines(text) {
                writeField("", line, into: &output)
            }
        case .retry(let milliseconds):
            writeField("retry", Array(String(max(0, milliseconds)).utf8)[...], into: &output)
        }
    }

    private static func writeField(_ name: String, _ value: ArraySlice<UInt8>, into output: inout [UInt8]) {
        output.append(contentsOf: name.utf8)
        output.append(UInt8(ascii: ":"))
        if !value.isEmpty {
            output.append(UInt8(ascii: " "))
            output.append(contentsOf: value)
        }
        output.append(0x0A)
    }

    private static func sanitized(_ string: String, removingNUL: Bool) -> ArraySlice<UInt8> {
        Array(string.utf8.filter { $0 != 0x0A && $0 != 0x0D && !(removingNUL && $0 == 0) })[...]
    }

    /// Splits at CRLF, LF or CR. Always returns at least one (possibly empty) line.
    private static func lines(_ string: String) -> [ArraySlice<UInt8>] {
        let bytes = Array(string.utf8)
        var result: [ArraySlice<UInt8>] = []
        var start = 0
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 0x0A:
                result.append(bytes[start..<i])
                start = i + 1
            case 0x0D:
                result.append(bytes[start..<i])
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
                start = i + 1
            default:
                break
            }
            i += 1
        }
        result.append(bytes[start...])
        return result
    }
}
