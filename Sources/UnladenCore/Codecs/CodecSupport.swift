// Shared helpers for protocol codecs: reading JSON objects with presence
// tracking and unknown-field bags, and writing bags back.

/// Builds diagnostic paths like `messages[2].content[0]`.
enum WirePath {
    static func key(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    static func index(_ path: String, _ index: Int) -> String {
        "\(path)[\(index)]"
    }
}

/// Reads known keys from a JSON object, remembering which were consumed so
/// the rest can go into an unknown-field bag in their original order.
///
/// Typed accessors treat an explicit `null` like an absent key but leave it
/// unconsumed, so it lands in the bag and is written back as `null` by the
/// same protocol: presence is preserved without a tri-state in the model.
struct FieldReader {
    let object: JSONObject
    let path: String
    private(set) var consumed: Set<String> = []

    init(_ object: JSONObject, path: String) {
        self.object = object
        self.path = path
    }

    func path(_ key: String) -> String { WirePath.key(path, key) }

    func has(_ key: String) -> Bool { object.contains(key: key) }

    /// The raw value (including `null`); marks the key consumed.
    mutating func raw(_ key: String) -> JSONValue? {
        guard let value = object[key] else { return nil }
        consumed.insert(key)
        return value
    }

    /// A non-null value; `null` is left for the bag.
    private mutating func present(_ key: String) -> JSONValue? {
        guard let value = object[key], !value.isNull else { return nil }
        consumed.insert(key)
        return value
    }

    mutating func string(_ key: String) throws(WireDecodingError) -> String? {
        guard let value = present(key) else { return nil }
        guard case .string(let string) = value else { throw mismatch(key, "a string") }
        return string
    }

    mutating func requiredString(_ key: String) throws(WireDecodingError) -> String {
        guard object[key] != nil else { throw WireDecodingError(.missingField, path: path(key)) }
        guard let value = try string(key) else { throw mismatch(key, "a string") }
        return value
    }

    mutating func bool(_ key: String) throws(WireDecodingError) -> Bool? {
        guard let value = present(key) else { return nil }
        guard case .bool(let bool) = value else { throw mismatch(key, "a boolean") }
        return bool
    }

    mutating func number(_ key: String) throws(WireDecodingError) -> JSONNumber? {
        guard let value = present(key) else { return nil }
        guard case .number(let number) = value else { throw mismatch(key, "a number") }
        return number
    }

    mutating func int(_ key: String) throws(WireDecodingError) -> Int? {
        guard let number = try number(key) else { return nil }
        guard let int = number.int else { throw mismatch(key, "an integer") }
        return int
    }

    mutating func object(_ key: String) throws(WireDecodingError) -> JSONObject? {
        guard let value = present(key) else { return nil }
        guard case .object(let object) = value else { throw mismatch(key, "an object") }
        return object
    }

    mutating func array(_ key: String) throws(WireDecodingError) -> [JSONValue]? {
        guard let value = present(key) else { return nil }
        guard case .array(let array) = value else { throw mismatch(key, "an array") }
        return array
    }

    mutating func requiredArray(_ key: String) throws(WireDecodingError) -> [JSONValue] {
        guard object[key] != nil else { throw WireDecodingError(.missingField, path: path(key)) }
        guard let value = try array(key) else { throw mismatch(key, "an array") }
        return value
    }

    func mismatch(_ key: String, _ expected: String) -> WireDecodingError {
        WireDecodingError(.typeMismatch(expected: expected), path: path(key))
    }

    /// Unconsumed keys in their original order. Each non-null key yields an
    /// ``WireWarning/Code/unknownField`` warning.
    func remaining(warnings: inout [WireWarning]) -> JSONObject {
        var bag = JSONObject()
        for (key, value) in object where !consumed.contains(key) {
            bag[key] = value
            if !value.isNull {
                warnings.append(WireWarning(.unknownField, "kept unknown field `\(key)`", path: path(key)))
            }
        }
        return bag
    }

    /// Unconsumed keys are dropped, with a ``WireWarning/Code/droppedField``
    /// warning each (for nested objects the model has no bag for).
    func dropRemaining(warnings: inout [WireWarning]) {
        for (key, value) in object where !consumed.contains(key) && !value.isNull {
            warnings.append(WireWarning(.droppedField, "dropped unknown field `\(key)`", path: path(key)))
        }
    }
}

extension JSONValue {
    /// Wraps the value as a typed-throw JSON parse.
    static func parseWire(_ bytes: some Collection<UInt8>) throws(WireDecodingError) -> JSONValue {
        do {
            return try JSONParser.parse(bytes)
        } catch {
            throw WireDecodingError(.invalidJSON(error), path: "")
        }
    }
}

/// Appends an unknown-field bag after the known fields of `object`.
///
/// - `include`: the target is the bag's source protocol. Otherwise the bag is
///   dropped and every non-null entry produces a warning.
/// - A bag key that collides with a known field is not written (the known
///   value wins) and produces a warning.
func appendExtra(
    _ extra: JSONObject,
    to object: inout JSONObject,
    include: Bool,
    path: String,
    warnings: inout [WireWarning],
) {
    for (key, value) in extra {
        if !include {
            if !value.isNull {
                warnings.append(WireWarning(
                    .droppedField,
                    "field `\(key)` from another protocol cannot be carried",
                    path: WirePath.key(path, key),
                ))
            }
        } else if object.contains(key: key) {
            warnings.append(WireWarning(
                .lossyConversion,
                "unknown field `\(key)` collides with a known field and was dropped",
                path: WirePath.key(path, key),
            ))
        } else {
            object[key] = value
        }
    }
}

/// `data:<media-type>;base64,<data>` URLs.
enum DataURL {
    /// Splits a base64 data URL with a plain media type (no parameters).
    /// Returns `nil` for anything else, which is then kept as a URL so it
    /// round-trips unchanged.
    static func parse(_ url: String) -> (mediaType: String, data: String)? {
        guard url.hasPrefix("data:") else { return nil }
        let rest = url.dropFirst(5)
        guard let marker = rest.firstRange(of: ";base64,") else { return nil }
        let mediaType = rest[..<marker.lowerBound]
        guard !mediaType.isEmpty, !mediaType.contains(";"), !mediaType.contains(",") else { return nil }
        return (String(mediaType), String(rest[marker.upperBound...]))
    }

    static func make(mediaType: String, data: String) -> String {
        "data:\(mediaType);base64,\(data)"
    }
}

/// RFC 4648 base64, standard or URL-safe alphabet (Foundation-free).
enum Base64 {
    private static let standard = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let urlSafe = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// Encodes `bytes`; the URL-safe form is unpadded.
    static func encode(_ bytes: some Collection<UInt8>, urlSafe url: Bool = false) -> String {
        let table = url ? urlSafe : standard
        let input = Array(bytes)
        var output: [UInt8] = []
        output.reserveCapacity((input.count + 2) / 3 * 4)
        var i = 0
        while i < input.count {
            let b0 = input[i]
            let b1 = i + 1 < input.count ? input[i + 1] : 0
            let b2 = i + 2 < input.count ? input[i + 2] : 0
            output.append(table[Int(b0 >> 2)])
            output.append(table[Int((b0 & 0x03) << 4 | b1 >> 4)])
            if i + 1 < input.count {
                output.append(table[Int((b1 & 0x0F) << 2 | b2 >> 6)])
            } else if !url {
                output.append(UInt8(ascii: "="))
            }
            if i + 2 < input.count {
                output.append(table[Int(b2 & 0x3F)])
            } else if !url {
                output.append(UInt8(ascii: "="))
            }
            i += 3
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes `string`, or `nil` if it is not valid in the chosen alphabet.
    /// Padding is optional; non-zero trailing bits are rejected, so every
    /// accepted string is the encoding of its result.
    static func decode(_ string: String, urlSafe url: Bool = false) -> [UInt8]? {
        let table = url ? urlSafe : standard
        var values: [UInt8] = []
        values.reserveCapacity(string.utf8.count)
        var padding = 0
        for byte in string.utf8 {
            if byte == UInt8(ascii: "=") {
                padding += 1
                continue
            }
            guard padding == 0, let index = table.firstIndex(of: byte) else { return nil }
            values.append(UInt8(index))
        }
        if padding > 0, (values.count + padding) % 4 != 0 || padding > 2 { return nil }
        if values.count % 4 == 1 { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(values.count * 3 / 4)
        var i = 0
        while i + 1 < values.count {
            let v0 = values[i], v1 = values[i + 1]
            output.append(v0 << 2 | v1 >> 4)
            if i + 2 < values.count {
                let v2 = values[i + 2]
                output.append((v1 & 0x0F) << 4 | v2 >> 2)
                if i + 3 < values.count {
                    output.append((v2 & 0x03) << 6 | values[i + 3])
                } else if v2 & 0x03 != 0 {
                    return nil
                }
            } else if v1 & 0x0F != 0 {
                return nil
            }
            i += 4
        }
        return output
    }
}

// MARK: - Truncated streams

extension WireStreamError {
    /// What a stream decoder reports when the upstream stream ends after it
    /// started but before its protocol's terminal event, without an error:
    /// a dropped connection or a relay that cut the reply short. Reported
    /// as an error (with a finish of reason ``WireFinishReason/Unified/error``)
    /// so a client sees a failed reply, not a clean but truncated one.
    static func endedEarly(missing: String) -> WireStreamError {
        WireStreamError(message: "upstream stream ended early, without \(missing)")
    }
}
