import Testing
import UnladenCore

private func roundTrip(_ text: String) throws -> String {
    String(decoding: try JSONValue(parsing: text).encoded(), as: UTF8.self)
}

private func parseError(_ text: String) -> JSONParseError? {
    do {
        _ = try JSONValue(parsing: text)
        return nil
    } catch {
        return error
    }
}

@Suite struct JSONRoundTripTests {
    @Test(arguments: [
        #"null"#,
        #"true"#,
        #"false"#,
        #"0"#,
        #""""#,
        #"[]"#,
        #"{}"#,
        #"{"model":"gpt-4o","temperature":1.0,"max_tokens":1e3,"stream":true,"stop":null}"#,
        #"{"z":1,"a":2,"m":{"y":[1,2,{"b":null,"a":false}],"x":-0.0}}"#,
        #"[1.0,1e5,1E5,1e+5,1e-5,-0,-0.0,0.5,123456789012345678901234567890,-98765432109876543210.25e-10]"#,
        #"{"html":"<a href=\"/x\">&amp;</a>","path":"a/b/c"}"#,
        #"{"text":"héllo 世界 🎉","esc":"\"\\\n\r\t\b\f\u0000\u001f"}"#,
        #"[[[[[]]]],{"":""}]"#,
    ])
    func compactInputRoundTripsByteForByte(_ text: String) throws {
        #expect(try roundTrip(text) == text)
    }

    @Test func whitespaceIsDropped() throws {
        #expect(try roundTrip(" {\n\t\"a\" : [ 1 , 2 ] ,\r\n \"b\":{ } } ") == #"{"a":[1,2],"b":{}}"#)
    }

    @Test func numberLiteralsArePreserved() throws {
        let value = try JSONValue(parsing: "[1.0,1e5,-0,18446744073709551616,0.1]")
        let numbers = try #require(value.arrayValue).compactMap(\.numberValue)
        #expect(numbers.map(\.literal) == ["1.0", "1e5", "-0", "18446744073709551616", "0.1"])
        #expect(numbers[0].int == 1)
        #expect(numbers[0].isIntegerLiteral == false)
        #expect(numbers[1].int == 100_000)
        #expect(numbers[2].int == 0)
        #expect(numbers[3].int == nil)
        #expect(numbers[3].double == 18446744073709551616.0)
        #expect(numbers[4].double == 0.1)
    }

    @Test func numberInitializers() {
        #expect(JSONNumber(42).literal == "42")
        #expect(JSONNumber(UInt64.max).literal == "18446744073709551615")
        // `JSONNumber(1.0)` with a literal is literal coercion; go through `Double`.
        let one: Double = 1, big: Double = 1e20, tiny: Double = 5e-324
        #expect(JSONNumber(one)?.literal == "1.0")
        #expect(JSONNumber(big)?.literal == "1e+20")
        #expect(JSONNumber(tiny)?.literal == "5e-324")
        #expect(JSONNumber(1.0).literal == "1.0")
        #expect(JSONNumber(Double.nan) == nil)
        #expect(JSONNumber(-Double.infinity) == nil)
        #expect(JSONNumber(literal: "1.50")?.literal == "1.50")
        for bad in ["", "-", "+1", "01", ".5", "1.", "1e", "1e+", "NaN", "0x10", " 1"] {
            #expect(JSONNumber(literal: bad) == nil, "\(bad)")
        }
        let value: JSONValue = ["a": 1, "b": 2.5, "c": [true, nil, "x"]]
        #expect(value.description == #"{"a":1,"b":2.5,"c":[true,null,"x"]}"#)
    }

    @Test func numberEqualityIsLiteral() throws {
        #expect(try JSONValue(parsing: "1.0") != JSONValue(parsing: "1"))
        #expect(try JSONValue(parsing: "1.0") == JSONValue(parsing: "1.0"))
    }
}

@Suite struct JSONObjectTests {
    @Test func keyOrderIsPreserved() throws {
        let value = try JSONValue(parsing: #"{"zeta":1,"alpha":2,"mid":3}"#)
        let object = try #require(value.objectValue)
        #expect(object.keys == ["zeta", "alpha", "mid"])
        #expect(object["alpha"] == 2)
        #expect(value["mid"] == 3)
        #expect(value["missing"] == nil)
    }

    @Test func mutationKeepsOrder() {
        var object: JSONObject = ["a": 1, "b": 2, "c": 3]
        object["b"] = "two"
        object["d"] = 4
        #expect(object.keys == ["a", "b", "c", "d"])
        #expect(object.removeValue(forKey: "a") == 1)
        #expect(object.keys == ["b", "c", "d"])
        #expect(object["c"] == 3)
        #expect(object.index(forKey: "d") == 2)
        object["c"] = nil
        #expect(JSONValue.object(object).description == #"{"b":"two","d":4}"#)
    }

    @Test func equalityIsOrderSensitive() {
        let a: JSONObject = ["x": 1, "y": 2]
        let b: JSONObject = ["y": 2, "x": 1]
        #expect(a != b)
    }

    @Test func duplicateKeysLastValueWinsAtFirstPosition() throws {
        let value = try JSONValue(parsing: #"{"a":1,"b":2,"a":3}"#)
        #expect(value.description == #"{"a":3,"b":2}"#)
    }

    @Test func duplicateKeysCanBeRejected() {
        let options = JSONParser.Options(duplicateKeys: .reject)
        #expect(throws: JSONParseError(.duplicateKey("a"), offset: 15)) {
            try JSONValue(parsing: #"{"a":1,"b":2 , "a":3}"#, options: options)
        }
    }
}

@Suite struct JSONStringTests {
    @Test func escapesAreDecoded() throws {
        let value = try JSONValue(parsing: #""a\"b\\c\/d\b\f\n\r\t\u0041\u00e9\u4e16""#)
        #expect(value.stringValue == "a\"b\\c/d\u{8}\u{c}\n\r\tAé世")
    }

    @Test func surrogatePairsAreDecoded() throws {
        #expect(try JSONValue(parsing: #""\ud83c\udf89""#).stringValue == "🎉")
        #expect(try JSONValue(parsing: #""x\uD834\uDD1Ey""#).stringValue == "x𝄞y")
    }

    @Test func writerEscapesOnlyWhatItMust() {
        let value = JSONValue.string("\"\\/<>&\u{0}\u{1}\u{1f}\u{7f}\n\r\t\u{8}\u{c}é🎉\u{2028}")
        let expected = #""\"\\/<>&\u0000\u0001\u001f"# + "\u{7f}" + #"\n\r\t\b\f"# + "é🎉\u{2028}\""
        #expect(String(decoding: value.encoded(), as: UTF8.self) == expected)
    }

    @Test func rawUTF8IsKept() throws {
        let bytes = Array(#"["日本語","🎉"]"#.utf8)
        #expect(try JSONValue(parsing: bytes).encoded() == bytes)
    }

    @Test func encodingIsDeterministic() throws {
        let value = try JSONValue(parsing: #"{"b":[1.10,{"z":"\u00e9","a":null}],"a":1e-7}"#)
        let first = value.encoded()
        for _ in 0..<5 {
            #expect(value.encoded() == first)
            #expect(try JSONValue(parsing: first).encoded() == first)
        }
    }
}

@Suite struct JSONInvalidInputTests {
    @Test(arguments: [
        ("", JSONParseError.Kind.unexpectedEndOfInput, 0),
        ("   ", .unexpectedEndOfInput, 3),
        ("nul", .unexpectedEndOfInput, 3),
        ("nulx", .unexpectedByte(UInt8(ascii: "x")), 3),
        ("True", .unexpectedByte(UInt8(ascii: "T")), 0),
        ("[1,]", .unexpectedByte(UInt8(ascii: "]")), 3),
        ("[1 2]", .unexpectedByte(UInt8(ascii: "2")), 3),
        (#"{"a":1,}"#, .unexpectedByte(UInt8(ascii: "}")), 7),
        (#"{"a" 1}"#, .unexpectedByte(UInt8(ascii: "1")), 5),
        ("{a:1}", .unexpectedByte(UInt8(ascii: "a")), 1),
        ("[1", .unexpectedEndOfInput, 2),
        ("01", .invalidNumber, 1),
        ("-", .invalidNumber, 1),
        ("1.", .invalidNumber, 2),
        ("1.e5", .invalidNumber, 2),
        ("1e", .invalidNumber, 2),
        ("+1", .unexpectedByte(UInt8(ascii: "+")), 0),
        (".5", .unexpectedByte(UInt8(ascii: ".")), 0),
        ("NaN", .unexpectedByte(UInt8(ascii: "N")), 0),
        ("1 2", .trailingData, 2),
        ("{} x", .trailingData, 3),
        (#""abc"#, .unexpectedEndOfInput, 4),
        (#""a\x""#, .invalidEscape, 2),
        (#""a\'""#, .invalidEscape, 2),
        (#""\u12G4""#, .invalidUnicodeEscape, 5),
        (#""\ud800""#, .invalidUnicodeEscape, 1),
        (#""\ud800\u0041""#, .invalidUnicodeEscape, 1),
        (#""\udc00\ud800""#, .invalidUnicodeEscape, 1),
        ("\"a\tb\"", .unescapedControlCharacter, 2),
        ("\"a\nb\"", .unescapedControlCharacter, 2),
        ("[\"\\n\u{1}\"]", .unescapedControlCharacter, 4),
        ("\u{FEFF}{}", .unexpectedByte(0xEF), 0),
        ("// c\n1", .unexpectedByte(UInt8(ascii: "/")), 0),
    ])
    func rejected(_ text: String, _ kind: JSONParseError.Kind, _ offset: Int) {
        #expect(parseError(text) == JSONParseError(kind, offset: offset))
    }

    @Test func invalidUTF8IsRejected() {
        let cases: [([UInt8], Int)] = [
            ([0x22, 0x61, 0xFF, 0x22], 2), // invalid byte
            ([0x22, 0xC3, 0x22], 1), // truncated sequence
            ([0x22, 0xC0, 0xAF, 0x22], 1), // overlong
            ([0x22, 0xED, 0xA0, 0x80, 0x22], 1), // encoded surrogate
            ([0x22, 0x5C, 0x6E, 0xF4, 0x90, 0x80, 0x80, 0x22], 3), // > U+10FFFF after an escape
        ]
        for (bytes, offset) in cases {
            #expect(throws: JSONParseError(.invalidUTF8, offset: offset)) {
                try JSONValue(parsing: bytes)
            }
        }
    }

    @Test func nestingDepthIsLimited() throws {
        let ok = String(repeating: "[", count: 256) + String(repeating: "]", count: 256)
        #expect(try JSONValue(parsing: ok).encoded().count == 512)
        let tooDeep = String(repeating: "[", count: 257) + String(repeating: "]", count: 257)
        #expect(parseError(tooDeep) == JSONParseError(.nestingTooDeep(limit: 256), offset: 256))
        let options = JSONParser.Options(maxDepth: 2)
        #expect(throws: JSONParseError(.nestingTooDeep(limit: 2), offset: 6)) {
            try JSONValue(parsing: #"{"a":[{}]}"#, options: options)
        }
        // A large depth must fail cleanly, not overflow the stack.
        #expect(parseError(String(repeating: "[", count: 100_000))?.kind == .nestingTooDeep(limit: 256))
    }

    @Test func parsesNonContiguousCollections() throws {
        let bytes = Array(#"{"a":[1,2]}"#.utf8)
        #expect(try JSONValue(parsing: bytes.reversed().reversed()).description == #"{"a":[1,2]}"#)
    }
}
