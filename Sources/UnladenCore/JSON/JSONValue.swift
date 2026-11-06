/// A JSON value with lossless numbers and ordered objects.
///
/// Parse with ``init(parsing:options:)`` and encode with ``encoded()``.
/// Equality is structural and order-sensitive for objects, and compares
/// number literals textually (see ``JSONNumber``), so `a == b` implies
/// `a.encoded() == b.encoded()`.
///
/// The JSON and SSE types are deliberately plain `public` (not SPI): they
/// are stable building blocks library users need for tool schemas, raw
/// extras and custom transports. Wire-model types are `@_spi(Wire)`.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

extension JSONValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: JSONNumber? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Member lookup; `nil` if this is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Element lookup; `nil` if this is not an array or the index is out of range.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(JSONNumber(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(JSONNumber(floatLiteral: value)) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = JSONObject(minimumCapacity: elements.count)
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

extension JSONValue: CustomStringConvertible {
    /// The compact encoding as a string.
    public var description: String {
        String(decoding: encoded(), as: UTF8.self)
    }
}
