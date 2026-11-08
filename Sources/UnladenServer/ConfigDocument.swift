// The configuration file as the panel edits it: a JSON document with the
// file's own values (`${VAR}` kept as written), keys written out in the file
// replaced by placeholders, and a hash for optimistic concurrency.
// See docs/server-config-design.md ("面板写回文件的规则").

@_spi(Wire) import UnladenCore
import Yams

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
    static let header = "# Written by the unladen control panel. Comments are not kept when it saves.\n"

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
        let root: Node?
        do {
            root = try Yams.compose(yaml: text)
        } catch {
            throw ConfigError(message: "not valid YAML: \(error)", location: file)
        }
        var secrets: [String: String] = [:]
        let document = root.map { json($0, path: [], secrets: &secrets) } ?? .object(JSONObject())
        return Snapshot(document: document.isNull ? .object(JSONObject()) : document, hash: hash(text), secrets: secrets)
    }

    private static func json(_ node: Node, path: [String], secrets: inout [String: String]) -> JSONValue {
        switch node {
        case .mapping(let mapping):
            var object = JSONObject()
            for (key, value) in mapping {
                let name = key.scalar?.string ?? "?"
                object[name] = json(value, path: path + [name], secrets: &secrets)
            }
            return .object(object)
        case .sequence(let sequence):
            return .array(sequence.enumerated().map { json($0.element, path: path + ["\($0.offset)"], secrets: &secrets) })
        case .alias:
            return .null
        case .scalar(let scalar):
            if isSecretPath(path), !scalar.string.contains("${"), !scalar.string.isEmpty {
                let hidden = placeholder(for: scalar.string)
                secrets[hidden] = scalar.string
                return .string(hidden)
            }
            // Only plain scalars have a type besides string (`"true"` is a string).
            guard scalar.style == .plain else { return .string(scalar.string) }
            if node.null != nil { return .null }
            // YAML 1.1 also reads yes/no/on/off as booleans; the panel keeps
            // them as written (`head_timeout: off`).
            if let flag = node.bool, ["true", "false"].contains(scalar.string.lowercased()) { return .bool(flag) }
            if node.int != nil || node.float != nil, let number = JSONNumber(literal: scalar.string) { return .number(number) }
            return .string(scalar.string)
        }
    }

    // MARK: Writing

    /// YAML for `document`, placeholders put back from `secrets`. Nulls
    /// are left out.
    static func yaml(from document: JSONValue, secrets: [String: String]) throws(ConfigError) -> String {
        let node = try self.node(document, path: [], secrets: secrets)
        do {
            return try Yams.serialize(node: node ?? Node.mapping(Node.Mapping([])))
        } catch {
            throw ConfigError(message: "cannot write the configuration: \(error)")
        }
    }

    private static func node(_ value: JSONValue, path: [String], secrets: [String: String]) throws(ConfigError) -> Node? {
        switch value {
        case .null:
            return nil
        case .bool(let flag):
            return Node(flag ? "true" : "false", Tag(.bool))
        case .number(let number):
            return Node(number.description, Tag(number.int != nil ? .int : .float))
        case .string(let text):
            if isPlaceholder(text) {
                guard let secret = secrets[text] else {
                    throw ConfigError(message: "\(path.joined(separator: ".")): \(text) is not a key of the current file; enter the key again")
                }
                return scalar(secret)
            }
            return scalar(text)
        case .array(let items):
            var nodes: [Node] = []
            for (index, item) in items.enumerated() {
                if let node = try node(item, path: path + ["\(index)"], secrets: secrets) { nodes.append(node) }
            }
            return Node.sequence(Node.Sequence(nodes))
        case .object(let object):
            var pairs: [(Node, Node)] = []
            for index in 0..<object.count {
                let (key, item) = object[index]
                if let node = try node(item, path: path + [key], secrets: secrets) { pairs.append((scalar(key), node)) }
            }
            return Node.mapping(Node.Mapping(pairs))
        }
    }

    /// A string scalar: plain when YAML would read it back as the same
    /// string, double-quoted otherwise (`*`, `${VAR}`, `off`, `123`…).
    static func scalar(_ text: String) -> Node {
        Node(text, Tag(.str), isPlain(text) ? .plain : .doubleQuoted)
    }

    static func isPlain(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isLetter || first.isNumber || first == "_" || first == "." || first == "/"
        else { return false }
        let allowed = text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_./:@+-".contains($0)) }
        guard allowed, !text.hasSuffix(":") else { return false }
        let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "y", "n", "null", "~"]
        if reserved.contains(text.lowercased()) { return false }
        if Double(text) != nil || Int(text) != nil { return false }
        // 0x1F, 1e3, 1_000 and dates resolve to numbers or timestamps.
        if text.first!.isNumber { return false }
        return true
    }
}
