/// A JSON number that keeps its original literal text.
///
/// Foundation-based coders normalise numbers (`1.0` becomes `1`, large
/// integers lose precision). Unladen needs re-encoding to be byte-stable, so a
/// number is stored as the exact literal it was parsed from (or produced by
/// one of the initialisers) and written back verbatim.
///
/// Equality and hashing compare the literal text, so `1.0 != 1`. That keeps
/// `==` consistent with the encoder: equal values always encode to equal bytes.
public struct JSONNumber: Hashable, Sendable {
    /// The literal text, guaranteed to match the RFC 8259 `number` grammar.
    public let literal: String

    /// Creates a number from literal text, or returns `nil` if the text is not
    /// a valid RFC 8259 number (for example `+1`, `01`, `.5`, `1.`, `NaN`).
    public init?(literal: String) {
        guard JSONNumber.isValidLiteral(Array(literal.utf8)[...]) else { return nil }
        self.literal = literal
    }

    /// Creates a number from already-validated literal bytes (parser use).
    init(validatedLiteral bytes: UnsafeBufferPointer<UInt8>) {
        self.literal = String(decoding: bytes, as: UTF8.self)
    }

    public init(_ value: some BinaryInteger) {
        self.literal = String(value)
    }

    /// Creates a number from a finite `Double` using Swift's shortest
    /// round-trip representation (`1.0`, `0.1`, `1e+20`).
    /// Returns `nil` for NaN and infinities, which JSON cannot represent.
    public init?(_ value: Double) {
        guard value.isFinite else { return nil }
        self.literal = value.description
    }

    /// The value as an `Int` if it is exactly representable
    /// (`1`, `-0`, `1.0` and `1e3` all qualify; `1.5` and `1e30` do not).
    public var int: Int? {
        if let value = Int(literal) { return value }
        guard isIntegerLiteral == false, let double = Double(literal) else { return nil }
        return Int(exactly: double)
    }

    /// The value as a `Double` (possibly rounded, e.g. for big integers).
    public var double: Double {
        // The literal is valid JSON number syntax, which `Double.init` accepts.
        Double(literal) ?? .nan
    }

    /// `true` if the literal has no fraction and no exponent.
    public var isIntegerLiteral: Bool {
        !literal.utf8.contains { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
    }

    /// Validates `-? (0 | [1-9][0-9]*) (\.[0-9]+)? ([eE][+-]?[0-9]+)?`.
    static func isValidLiteral(_ bytes: ArraySlice<UInt8>) -> Bool {
        var i = bytes.startIndex
        let end = bytes.endIndex
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        if i < end, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < end else { return false }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else if isDigit(bytes[i]) {
            while i < end, isDigit(bytes[i]) { i += 1 }
        } else {
            return false
        }
        if i < end, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard i < end, isDigit(bytes[i]) else { return false }
            while i < end, isDigit(bytes[i]) { i += 1 }
        }
        if i < end, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < end, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < end, isDigit(bytes[i]) else { return false }
            while i < end, isDigit(bytes[i]) { i += 1 }
        }
        return i == end
    }
}

extension JSONNumber: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self.init(value)
    }
}

extension JSONNumber: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        // Float literals in source are always finite.
        self.literal = value.description
    }
}

extension JSONNumber: CustomStringConvertible {
    public var description: String { literal }
}
