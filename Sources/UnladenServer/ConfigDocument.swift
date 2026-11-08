// The configuration file as the panel edits it: the file's own JSON
// (`${VAR}` kept as written), keys written out in the file replaced by
// placeholders, and a hash for optimistic concurrency.
// See docs/server-config-design.md ("面板写回文件的规则").

@_spi(Wire) import UnladenCore

enum ConfigDocument {
    /// The file as the panel sees it.
    struct Snapshot: Sendable {
        var document: JSONValue
        /// Of the file's bytes; a save names the hash it started from.
        var hash: String
        /// Placeholder → the key it hides.
        var secrets: [String: String]
    }

    /// Put at the top of a file the panel writes.
    static let header = "// Written by the unladen control panel. Comments are not kept when it saves.\n"

    /// FNV-1a over the bytes, hex. Not a security measure: it only tells
    /// whether the file changed since the panel read it.
    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// What stands for a key written out in the file.
    static func placeholder(for secret: String) -> String {
        "<hidden \(UpstreamKey.fingerprint(secret))>"
    }

    static func isPlaceholder(_ text: String) -> Bool {
        text.hasPrefix("<hidden key-") && text.hasSuffix(">") && text.count == 21
    }

    /// Paths whose values are secrets.
    static func isSecretPath(_ path: [String]) -> Bool {
        switch path.count {
        case 4: path[0] == "providers" && path[2] == "keys"
        case 5: path[0] == "providers" && path[2] == "keys" && path[4] == "key"
        case 3: (path[0] == "client_keys" && path[2] == "secret") || path == ["server", "admin", "token"]
        default: false
        }
    }

    // MARK: Reading

    static func read(_ text: String, file: String = "config") throws(ConfigError) -> Snapshot {
        let root = try ConfigFile.parseJSON(text, file: file).value
        var secrets: [String: String] = [:]
        let document = root.isNull ? .object(JSONObject()) : mask(root, path: [], secrets: &secrets)
        return Snapshot(document: document, hash: hash(text), secrets: secrets)
    }

    private static func mask(_ value: JSONValue, path: [String], secrets: inout [String: String]) -> JSONValue {
        switch value {
        case .object(let object):
            var masked = JSONObject()
            for (key, item) in object { masked[key] = mask(item, path: path + [key], secrets: &secrets) }
            return .object(masked)
        case .array(let items):
            return .array(items.enumerated().map { mask($0.element, path: path + [String($0.offset)], secrets: &secrets) })
        case .string(let text) where isSecretPath(path) && !text.contains("${") && !text.isEmpty:
            let hidden = placeholder(for: text)
            secrets[hidden] = text
            return .string(hidden)
        default:
            return value
        }
    }

    // MARK: Writing

    /// The file's text for `document`, placeholders put back from `secrets`.
    /// Nulls are left out.
    static func text(from document: JSONValue, secrets: [String: String]) throws(ConfigError) -> String {
        let value = try unmask(document, path: [], secrets: secrets) ?? .object(JSONObject())
        var output = ""
        write(value, indent: "", into: &output)
        return output + "\n"
    }

    private static func unmask(_ value: JSONValue, path: [String], secrets: [String: String]) throws(ConfigError) -> JSONValue? {
        switch value {
        case .null:
            return nil
        case .string(let text) where isPlaceholder(text):
            guard let secret = secrets[text] else {
                throw ConfigError(message: "\(path.joined(separator: ".")): \(text) is not a key of the current file; enter the key again")
            }
            return .string(secret)
        case .array(let items):
            var result: [JSONValue] = []
            for (index, item) in items.enumerated() {
                if let item = try unmask(item, path: path + [String(index)], secrets: secrets) { result.append(item) }
            }
            return .array(result)
        case .object(let object):
            var result = JSONObject()
            for (key, item) in object {
                if let item = try unmask(item, path: path + [key], secrets: secrets) { result[key] = item }
            }
            return .object(result)
        default:
            return value
        }
    }

    /// Two-space indentation; an array or object of scalars short enough
    /// stays on one line.
    private static func write(_ value: JSONValue, indent: String, into output: inout String) {
        if let line = inline(value) {
            output += line
            return
        }
        let inner = indent + "  "
        switch value {
        case .array(let items):
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += inner
                write(item, indent: inner, into: &output)
                output += index == items.count - 1 ? "\n" : ",\n"
            }
            output += indent + "]"
        case .object(let object):
            output += "{\n"
            for (index, (key, item)) in object.enumerated() {
                output += inner + encoded(.string(key)) + ": "
                write(item, indent: inner, into: &output)
                output += index == object.count - 1 ? "\n" : ",\n"
            }
            output += indent + "}"
        default:
            output += encoded(value)
        }
    }

    private static func inline(_ value: JSONValue) -> String? {
        let parts: [String]
        let open: String, close: String
        switch value {
        case .array(let items):
            guard !items.contains(where: isContainer) else { return nil }
            parts = items.map(encoded)
            (open, close) = ("[", "]")
        case .object(let object):
            guard !object.contains(where: { isContainer($0.value) }) else { return nil }
            parts = object.map { encoded(.string($0.key)) + ": " + encoded($0.value) }
            (open, close) = ("{ ", " }")
        default:
            return encoded(value)
        }
        if parts.isEmpty { return open.trimmingBlanks() + close.trimmingBlanks() }
        let line = open + parts.joined(separator: ", ") + close
        return line.count <= 72 ? line : nil
    }

    private static func isContainer(_ value: JSONValue) -> Bool {
        switch value {
        case .array, .object: true
        default: false
        }
    }

    private static func encoded(_ value: JSONValue) -> String {
        String(decoding: value.encoded(), as: UTF8.self)
    }
}
