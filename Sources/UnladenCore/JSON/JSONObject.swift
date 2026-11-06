/// An insertion-ordered JSON object with hashed key lookup.
///
/// Key order is part of the value: it is preserved from parsing, kept by
/// in-place updates, and reproduced by the encoder, which is what makes
/// encoding deterministic. Consequently `==` is order-sensitive.
///
/// Keys are unique. Assigning to an existing key replaces its value in place
/// (position unchanged); assigning to a new key appends it; assigning `nil`
/// removes the key (O(n), positions of later keys shift down).
///
/// Duplicate keys in parsed input are handled by
/// ``JSONParser/Options-swift.struct/duplicateKeys``.
public struct JSONObject: Sendable {
    public private(set) var keys: [String] = []
    public private(set) var values: [JSONValue] = []
    private var indices: [String: Int] = [:]

    public init() {}

    public init(minimumCapacity: Int) {
        keys.reserveCapacity(minimumCapacity)
        values.reserveCapacity(minimumCapacity)
        indices.reserveCapacity(minimumCapacity)
    }

    /// Creates an object from key-value pairs; a repeated key keeps the
    /// position of its first occurrence and the value of its last.
    public init(_ pairs: some Sequence<(String, JSONValue)>) {
        for (key, value) in pairs { self[key] = value }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func index(forKey key: String) -> Int? { indices[key] }

    public func contains(key: String) -> Bool { indices[key] != nil }

    public subscript(key: String) -> JSONValue? {
        get { indices[key].map { values[$0] } }
        set {
            if let newValue {
                if let index = indices[key] {
                    values[index] = newValue
                } else {
                    indices[key] = keys.count
                    keys.append(key)
                    values.append(newValue)
                }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    /// Removes `key` and returns its value, preserving the order of the rest.
    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let index = indices.removeValue(forKey: key) else { return nil }
        keys.remove(at: index)
        let removed = values.remove(at: index)
        for i in index..<keys.count { indices[keys[i]] = i }
        return removed
    }

    /// Appends a key that is known not to be present (parser fast path).
    mutating func appendUnique(_ key: String, _ value: JSONValue) {
        indices[key] = keys.count
        keys.append(key)
        values.append(value)
    }

    mutating func replaceValue(at index: Int, with value: JSONValue) {
        values[index] = value
    }
}

extension JSONObject: RandomAccessCollection {
    public typealias Element = (key: String, value: JSONValue)
    public typealias Index = Int

    public var startIndex: Int { 0 }
    public var endIndex: Int { keys.count }

    public subscript(position: Int) -> (key: String, value: JSONValue) {
        (keys[position], values[position])
    }
}

extension JSONObject: Hashable {
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.keys == rhs.keys && lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keys)
        hasher.combine(values)
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(minimumCapacity: elements.count)
        for (key, value) in elements { self[key] = value }
    }
}

extension JSONObject: CustomStringConvertible {
    public var description: String { JSONValue.object(self).description }
}
