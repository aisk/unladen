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
