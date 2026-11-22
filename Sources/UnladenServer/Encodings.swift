// Encodings the sign-ins use: form encoding, Base64 with the URL
// alphabet, a JSON Web Token's claims, and SHA-256.

@_spi(Wire) import UnladenCore

/// `application/x-www-form-urlencoded`, also for query strings.
enum FormEncoding {
    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let hex = String(byte, radix: 16, uppercase: true)
                out += "%" + (byte < 16 ? "0" : "") + hex
            }
        }
        return out
    }

    static func decode(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            out[unescape(name)] = parts.count > 1 ? unescape(parts[1]) : ""
        }
        return out
    }

    static func unescape(_ text: Substring) -> String {
        var bytes: [UInt8] = []
        var index = text.utf8.startIndex
        let utf8 = text.utf8
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "%"), let first = utf8.index(index, offsetBy: 1, limitedBy: utf8.endIndex),
               let second = utf8.index(index, offsetBy: 2, limitedBy: utf8.endIndex), second < utf8.endIndex,
               utf8[first].isHexDigit, utf8[second].isHexDigit,
               let value = UInt8(String(decoding: [utf8[first], utf8[second]], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index = utf8.index(after: second)
                continue
            }
            bytes.append(byte == UInt8(ascii: "+") ? UInt8(ascii: " ") : byte)
            index = utf8.index(after: index)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Base64 with the URL alphabet and no padding.
enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 3, bytes.count)])
            let value = chunk.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (16 - 8 * $1.offset) }
            for position in 0...chunk.count { out.append(alphabet[Int(value >> (18 - 6 * position) & 0x3f)]) }
            index += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> [UInt8]? {
        var bits: UInt32 = 0
        var count = 0
        var out: [UInt8] = []
        for byte in text.utf8 where byte != UInt8(ascii: "=") {
            let value: UInt8
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = byte - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = byte - UInt8(ascii: "a") + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = byte - UInt8(ascii: "0") + 52
            case UInt8(ascii: "-"), UInt8(ascii: "+"): value = 62
            case UInt8(ascii: "_"), UInt8(ascii: "/"): value = 63
            default: return nil
            }
            bits = bits << 6 | UInt32(value)
            count += 6
            if count >= 8 {
                count -= 8
                out.append(UInt8(bits >> UInt32(count) & 0xff))
            }
        }
        return out
    }

    /// `byteCount` random bytes, encoded.
    static func random(_ byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return encode((0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

/// The claims of a JSON Web Token, unverified: the token came straight
/// from OpenAI over TLS, and only says who signed in and on what plan.
enum JWT {
    static func claims(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let bytes = Base64URL.decode(String(parts[1])) else { return nil }
        return try? JSONValue(parsing: bytes)
    }
}

/// SHA-256 (FIPS 180-4), for the PKCE challenge: FoundationEssentials has
/// no hashing, and a crypto package would bring in the whole of Foundation.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let length = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(length >> UInt64(shift) & 0xff)) }
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                w[i] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[chunk + i * 4 + $1]) }
            }
            for i in 16..<64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ w[i - 15] >> 3
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ w[i - 2] >> 10
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = e & f ^ ~e & g
                let t1 = hh &+ s1 &+ choice &+ k[i] &+ w[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = a & b ^ a & c ^ b & c
                let t2 = s0 &+ majority
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, value) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ value }
        }
        return h.flatMap { word in (0..<4).map { UInt8(word >> (24 - 8 * UInt32($0)) & 0xff) } }
    }
}

private extension UInt8 {
    var isHexDigit: Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(self)
    }
}
