// `Codable` for conversation history, so it can be saved and loaded.
//
// Message, Role, ToolCall and ToolResult use the synthesized form. Content
// parts are tagged objects (`{"type": "text", "text": …}`); media name its
// source by key (`url`, `base64` or `fileID`); a replay token is one opaque
// string (see `ReplayToken`'s conformance). Foundation is not needed: any
// encoder (`JSONEncoder`, a property list…) works.

@_spi(Wire) import UnladenCore

// MARK: - ContentPart

extension ContentPart: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, replay, media, toolCall, toolResult
    }

    private enum Kind: String, Codable {
        case text, image, file, reasoning, refusal, toolCall, toolResult
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text), replay: try container.decodeIfPresent(ReplayToken.self, forKey: .replay))
        case .reasoning:
            self = .reasoning(try container.decode(String.self, forKey: .text), replay: try container.decodeIfPresent(ReplayToken.self, forKey: .replay))
        case .refusal:
            self = .refusal(try container.decode(String.self, forKey: .text), replay: try container.decodeIfPresent(ReplayToken.self, forKey: .replay))
        case .image:
            self = .image(try container.decode(Media.self, forKey: .media))
        case .file:
            self = .file(try container.decode(Media.self, forKey: .media))
        case .toolCall:
            self = .toolCall(try container.decode(ToolCall.self, forKey: .toolCall))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .toolResult))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let replay):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(replay, forKey: .replay)
        case .reasoning(let text, let replay):
            try container.encode(Kind.reasoning, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(replay, forKey: .replay)
        case .refusal(let text, let replay):
            try container.encode(Kind.refusal, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(replay, forKey: .replay)
        case .image(let media):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(media, forKey: .media)
        case .file(let media):
            try container.encode(Kind.file, forKey: .type)
            try container.encode(media, forKey: .media)
        case .toolCall(let call):
            try container.encode(Kind.toolCall, forKey: .type)
            try container.encode(call, forKey: .toolCall)
        case .toolResult(let result):
            try container.encode(Kind.toolResult, forKey: .type)
            try container.encode(result, forKey: .toolResult)
        }
    }
}

// MARK: - Media

extension Media: Codable {
    private enum CodingKeys: String, CodingKey {
        case url, base64, fileID, mediaType, filename, detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sources: [Source] = [
            try container.decodeIfPresent(String.self, forKey: .url).map(Source.url),
            try container.decodeIfPresent(String.self, forKey: .base64).map(Source.base64),
            try container.decodeIfPresent(String.self, forKey: .fileID).map(Source.fileID),
        ].compactMap { $0 }
        guard sources.count == 1 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "media needs exactly one of `url`, `base64`, `fileID`",
            ))
        }
        self.init(
            sources[0],
            mediaType: try container.decodeIfPresent(String.self, forKey: .mediaType),
            filename: try container.decodeIfPresent(String.self, forKey: .filename),
            detail: try container.decodeIfPresent(String.self, forKey: .detail),
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .url(let value): try container.encode(value, forKey: .url)
        case .base64(let value): try container.encode(value, forKey: .base64)
        case .fileID(let value): try container.encode(value, forKey: .fileID)
        }
        try container.encodeIfPresent(mediaType, forKey: .mediaType)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}

// MARK: - ReplayToken

/// A token is one string: the base64 of a compact JSON object holding a
/// format version (`v`) and the token's fields. Only this library reads
/// it; decoding is strict (an unknown version or field, or anything
/// malformed, is a `DecodingError`), so a token is never half-restored.
extension ReplayToken: Codable {
    /// The format written by this version of the library.
    static let codingVersion = 1

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        func corrupted(_ why: String) -> DecodingError {
            DecodingError.dataCorruptedError(in: container, debugDescription: "invalid replay token: \(why)")
        }
        guard let bytes = Base64.decode(encoded), let json = try? JSONValue(parsing: bytes), let object = json.objectValue else {
            throw corrupted("not an encoded token")
        }
        guard let version = object["v"]?.numberValue?.int else { throw corrupted("no version") }
        guard version == Self.codingVersion else { throw corrupted("unsupported version \(version)") }
        let known: Set<String> = ["v", "system", "signature", "encrypted", "itemID", "origin", "summaryIndex", "sourceKey", "idSynthesized", "itemType", "dialect"]
        if let unknown = object.keys.first(where: { !known.contains($0) }) { throw corrupted("unknown field `\(unknown)`") }

        func field(_ key: String) throws -> String? {
            guard let value = object[key] else { return nil }
            guard let string = value.stringValue else { throw corrupted("`\(key)` is not a string") }
            return string
        }
        guard let system = try field("system") else { throw corrupted("no system") }
        // Optional, so tokens written before it was added still read.
        func dialect() throws -> JSONObject? {
            guard let value = object["dialect"] else { return nil }
            guard let dialect = value.objectValue else { throw corrupted("`dialect` is not an object") }
            return dialect
        }
        var summaryIndex: Int?
        if let value = object["summaryIndex"] {
            guard let index = value.numberValue?.int else { throw corrupted("`summaryIndex` is not an integer") }
            summaryIndex = index
        }
        var idSynthesized = false
        if let value = object["idSynthesized"] {
            guard let flag = value.boolValue else { throw corrupted("`idSynthesized` is not a boolean") }
            idSynthesized = flag
        }
        self.init(
            system: system,
            signature: try field("signature"),
            encrypted: try field("encrypted"),
            itemID: try field("itemID"),
            origin: try field("origin"),
            summaryIndex: summaryIndex,
            sourceKey: try field("sourceKey"),
            idSynthesized: idSynthesized,
            itemType: try field("itemType"),
            dialect: try dialect(),
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var object: JSONObject = ["v": .number(JSONNumber(Self.codingVersion)), "system": .string(system)]
        if let signature { object["signature"] = .string(signature) }
        if let encrypted { object["encrypted"] = .string(encrypted) }
        if let itemID { object["itemID"] = .string(itemID) }
        if let origin { object["origin"] = .string(origin) }
        if let summaryIndex { object["summaryIndex"] = .number(JSONNumber(summaryIndex)) }
        if let sourceKey { object["sourceKey"] = .string(sourceKey) }
        if idSynthesized { object["idSynthesized"] = .bool(true) }
        if let itemType { object["itemType"] = .string(itemType) }
        if let dialect { object["dialect"] = .object(dialect) }
        var container = encoder.singleValueContainer()
        try container.encode(Base64.encode(JSONValue.object(object).encoded()))
    }
}
