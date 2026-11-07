// Chat Completions messages and content parts, shared by the request and
// response directions.

/// The reasoning fields Chat-compatible APIs use on assistant messages and
/// stream deltas: DeepSeek's `reasoning_content`, OpenRouter's `reasoning`,
/// GitHub Copilot's `reasoning_text`.
let chatReasoningKeys = ["reasoning_content", "reasoning", "reasoning_text"]

/// Whether a Chat encoding may write a part's dialect replay data (a Gemini
/// `extra_content` signature, an OpenRouter `reasoning_details` entry).
///
/// - Replies to a Chat client (`trusted` is `nil`): only what came from a
///   Chat upstream (same protocol).
/// - Requests: data without an origin came from the client and goes on
///   only to the same protocol; data with one goes to an endpoint that
///   trusts its origin, or the relay that qualified it
///   (`openrouter:<format>` back to `openrouter`'s Chat API, which routes
///   each format to its vendor; see ``ChatReasoningDetails/origin(_:meta:)``).
struct ChatReplay {
    var include: Bool
    var trusted: Set<WireSystemID>?

    func accepts(_ origin: WireSystemID?) -> Bool {
        guard let trusted, let origin else { return include }
        if trusted.contains(origin) { return true }
        guard let colon = origin.firstIndex(of: ":") else { return false }
        return trusted.contains(String(origin[..<colon]))
    }
}

/// Mistral's typed content parts (Magistral, and GLM on api.mistral.ai):
/// `{"type": "thinking", "thinking": [{"type": "text", "text": …}]}`.
///
/// Decoded as ``WireReasoning`` with ``thinkingSourceKey``, which the Chat
/// encoders write back as such a part for the same protocol.
enum ChatMistral {
    static let thinkingSourceKey = "thinking"

    /// The text of a `thinking` list, `nil` unless it holds only plain text parts.
    static func thinkingText(_ value: JSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        var texts: [String] = []
        for item in items {
            guard case .object(let object) = item, object.count == 2, object["type"] == "text",
                  case .string(let text)? = object["text"]
            else { return nil }
            texts.append(text)
        }
        return texts
    }

    static func thinking(_ text: String) -> JSONValue {
        ["type": "thinking", "thinking": [textPart(text)]]
    }

    static func textPart(_ text: String) -> JSONValue {
        ["type": "text", "text": .string(text)]
    }

    /// A `thinking` part with several text parts decodes to one reasoning
    /// part each, with their position in ``WireReasoning/summaryIndex`` (as
    /// Responses summary parts); the first comes from
    /// ``ChatDecode/part(_:path:warnings:)``, these are the rest.
    static func followingThinking(_ item: JSONValue) -> [WirePart] {
        guard item["type"] == "thinking", let texts = thinkingText(item["thinking"]), texts.count > 1 else { return [] }
        return texts.enumerated().dropFirst().map { i, text in
            .reasoning(WireReasoning(text: text, summaryIndex: i, sourceKey: thinkingSourceKey))
        }
    }

    /// Whether `part` continues the `thinking` part encoded before it.
    static func continues(_ part: WirePart) -> Bool {
        guard case .reasoning(let reasoning) = part, reasoning.sourceKey == thinkingSourceKey else { return false }
        return (reasoning.summaryIndex ?? 0) > 0
    }
}

/// Gemini's OpenAI-compatible dialect: `extra_content.google` carries a
/// thought signature (`thought_signature`) on tool calls, on assistant
/// messages and on stream deltas, and marks a delta's `content` as thought
/// text (`thought: true`).
///
/// Decoders type the signature (``WireText/signature``,
/// ``WireToolCall/signature``, ``WireReasoning/signature``) and keep the
/// rest of `extra_content` in the part's bag under ``key``; the Chat
/// encoders put the signature back for the same protocol.
enum ChatGemini {
    static let key = "extra_content"
    /// ``WireReasoning/sourceKey`` of thought text that came in a stream
    /// delta's `content`, marked as a thought.
    static let thoughtSourceKey = "extra_content.google.thought"

    struct Split: Equatable {
        var signature: String?
        var thought = false
        /// What is left of `extra_content`, `nil` if nothing.
        var rest: JSONValue?
    }

    /// Takes the signature and the thought marker out of `extra_content`.
    static func split(_ value: JSONValue?) -> Split {
        guard case .object(var object)? = value else { return Split(rest: value) }
        var split = Split()
        if case .object(var google)? = object["google"] {
            if case .string(let signature)? = google["thought_signature"] {
                split.signature = signature
                google["thought_signature"] = nil
            }
            if google["thought"] == true {
                split.thought = true
                google["thought"] = nil
            }
            object["google"] = google.isEmpty ? nil : .object(google)
        }
        split.rest = object.isEmpty ? nil : .object(object)
        return split
    }

    /// Keeps the rest of `extra_content` in a part's bag (a lossless
    /// unknown field, as ``FieldReader/remaining(warnings:)`` notes them).
    static func keep(_ rest: JSONValue?, in bag: inout JSONObject, path: String, warnings: inout [WireWarning]) {
        guard let rest else { return }
        bag[key] = rest
        if !rest.isNull { warnings.append(WireWarning(.unknownField, "kept unknown field `\(key)`", path: path)) }
    }

    /// Writes a part's bag; when `write`, with `extra_content` rebuilt
    /// around `signature` (from another protocol, the rest of the bag is
    /// dropped with warnings).
    static func appendBag(
        _ extra: JSONObject,
        signature: String?,
        write: Bool,
        to object: inout JSONObject,
        include: Bool,
        path: String,
        warnings: inout [WireWarning],
    ) {
        var extra = extra
        if write, signature != nil {
            object[key] = join(rest: extra.removeValue(forKey: key), signature: signature)
        }
        appendExtra(extra, to: &object, include: include, path: path, warnings: &warnings)
    }

    /// `extra_content` with the signature (and marker) put back into `rest`.
    static func join(rest: JSONValue?, signature: String?, thought: Bool = false) -> JSONValue? {
        guard signature != nil || thought else { return rest }
        var object = rest?.objectValue ?? [:]
        var google = object["google"]?.objectValue ?? [:]
        if thought { google["thought"] = true }
        if let signature { google["thought_signature"] = .string(signature) }
        object["google"] = .object(google)
        return .object(object)
    }
}

/// OpenRouter's `reasoning_details` (also used by other Chat relays): a
/// list of `reasoning.text` (`text`, `signature`), `reasoning.summary`
/// (`summary`) and `reasoning.encrypted` (`data`) entries, each with a
/// `format` naming the upstream's representation and an `index`.
///
/// Each entry is one ``WireReasoning``: its text, signature or encrypted
/// data typed (the decoder's origin stamped on them), its other keys
/// (`type`, `format`, `index`, `id`…) in the part's bag under ``key``, from
/// which the Chat encoders rebuild the entry for the same protocol.
enum ChatReasoningDetails {
    static let key = "reasoning_details"

    struct Entry: Equatable {
        /// The entry without its text, signature or data.
        var meta: JSONObject
        var type: String
        var text: String
        var signature: String?
        var data: String?
    }

    /// The key holding an entry type's text.
    static func textKey(_ type: String) -> String? {
        switch type {
        case "reasoning.text": "text"
        case "reasoning.summary": "summary"
        default: nil
        }
    }

    /// Reads one entry; `nil` for an unknown type or a malformed entry.
    static func entry(_ value: JSONValue) -> Entry? {
        guard case .object(var object) = value, case .string(let type)? = object["type"] else { return nil }
        var malformed = false
        func take(_ key: String) -> String? {
            switch object[key] {
            case .string(let text)?:
                object[key] = nil
                return text
            case nil, .null?:
                return nil
            default:
                malformed = true
                return nil
            }
        }
        var entry = Entry(meta: [:], type: type, text: "")
        switch type {
        case "reasoning.text":
            entry.text = take("text") ?? ""
            entry.signature = take("signature")
        case "reasoning.summary":
            entry.text = take("summary") ?? ""
        case "reasoning.encrypted":
            entry.data = take("data")
        default:
            return nil
        }
        guard !malformed else { return nil }
        entry.meta = object
        return entry
    }

    /// Reads a whole list; `nil` unless every entry reads.
    static func entries(_ value: JSONValue?) -> [Entry]? {
        guard case .array(let items)? = value else { return nil }
        var entries: [Entry] = []
        for item in items {
            guard let entry = entry(item) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    static func reasoning(_ entry: Entry, origin: WireSystemID?, sourceKey: String? = nil) -> WireReasoning {
        let signed = entry.signature != nil || entry.data != nil
        return WireReasoning(
            text: entry.text, signature: entry.signature, encrypted: entry.data,
            origin: signed ? self.origin(origin, meta: entry.meta) : nil, sourceKey: sourceKey, extra: [key: .object(entry.meta)],
        )
    }

    /// The origin of an entry's signature or data: the relay's system
    /// qualified by the entry's `format` (`openrouter:anthropic-claude-v1`),
    /// since a relay passes on several vendors' reasoning and a signature
    /// is only good for the vendor that made it. An endpoint that should
    /// take it must trust the qualified id; a Chat request back to the relay
    /// itself takes any of its formats (see ``ChatReplay``). Without a
    /// string `format`, the relay's own id.
    static func origin(_ base: WireSystemID?, meta: JSONObject) -> WireSystemID? {
        guard let base, case .string(let format)? = meta["format"], !format.isEmpty else { return base }
        return "\(base):\(format)"
    }

    /// The text the entries carry, `nil` if none does (encrypted data only).
    static func text(_ entries: [Entry]) -> String? {
        let text = entries.map(\.text).joined()
        return entries.contains { textKey($0.type) != nil && !$0.text.isEmpty } ? text : nil
    }

    /// An entry from its bag `meta` and the given fields (`nil` ones left out).
    static func encode(meta: JSONObject, text: String?, signature: String?, data: String?) -> JSONValue {
        var object = meta
        let type = meta["type"]?.stringValue ?? ""
        if let text, let key = textKey(type), !object.contains(key: key) { object[key] = .string(text) }
        if let signature { object["signature"] = .string(signature) }
        if let data { object["data"] = .string(data) }
        return .object(object)
    }

    /// The entry a reasoning part decoded from one would be, if it was
    /// (its bag holds the entry's meta) and its data fits the entry type.
    static func encode(_ reasoning: WireReasoning) -> JSONValue? {
        guard case .object(let meta)? = reasoning.extra[key], let type = meta["type"]?.stringValue else { return nil }
        if reasoning.signature != nil, type != "reasoning.text" { return nil }
        if reasoning.encrypted != nil, type != "reasoning.encrypted" { return nil }
        return encode(meta: meta, text: reasoning.text, signature: reasoning.signature, data: reasoning.encrypted)
    }
}

// MARK: - Decoding

enum ChatDecode {
    /// Decodes a message's `content`: absent, `null`, a string, or parts.
    static func content(
        _ raw: JSONValue?,
        path: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> (parts: [WirePart], form: WireContentForm) {
        guard let raw else { return ([], .absent) }
        switch raw {
        case .null:
            return ([], .null)
        case .string(let text):
            return (text.isEmpty ? [] : [.text(WireText(text))], .string)
        case .array(let items):
            var parts: [WirePart] = []
            parts.reserveCapacity(items.count)
            for (i, item) in items.enumerated() {
                parts.append(try part(item, path: WirePath.index(path, i), warnings: &warnings))
                parts += ChatMistral.followingThinking(item)
            }
            return (parts, .parts)
        default:
            throw WireDecodingError(.typeMismatch(expected: "a string, an array or null"), path: path)
        }
    }

    /// Decodes one content part. Unknown or malformed-but-JSON parts become
    /// opaque parts so the same protocol can send them on.
    static func part(
        _ value: JSONValue,
        path: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WirePart {
        func opaque(_ why: String) -> WirePart {
            warnings.append(WireWarning(.opaqueContent, why, path: path))
            return .opaque(WireOpaque(protocol: .chatCompletions, value: value))
        }
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        guard case .string(let type)? = object["type"] else {
            return opaque("content part without a `type` kept as opaque")
        }
        var reader = FieldReader(object, path: path)
        _ = reader.raw("type")
        switch type {
        case "text":
            guard case .string(let text)? = object["text"] else { return opaque("malformed text part kept as opaque") }
            _ = reader.raw("text")
            var extra = reader.remaining(warnings: &warnings)
            let cache = WireCacheControl.lift(from: &extra)
            return .text(WireText(text, extra: extra, cacheControl: cache))

        case "thinking":
            guard let texts = ChatMistral.thinkingText(object["thinking"]), let first = texts.first else {
                return opaque("thinking part with content other than text kept as opaque")
            }
            _ = reader.raw("thinking")
            // Several text parts: the first here, the rest after it (see
            // ``thinkingParts(_:)``).
            return .reasoning(WireReasoning(
                text: first, summaryIndex: texts.count > 1 ? 0 : nil,
                sourceKey: ChatMistral.thinkingSourceKey, extra: reader.remaining(warnings: &warnings),
            ))

        case "refusal":
            guard case .string(let text)? = object["refusal"] else { return opaque("malformed refusal part kept as opaque") }
            _ = reader.raw("refusal")
            return .refusal(WireRefusal(text, extra: reader.remaining(warnings: &warnings)))

        case "image_url":
            guard case .object(let image)? = object["image_url"],
                  case .string(let url)? = image["url"]
            else { return opaque("image part without `image_url.url` kept as opaque") }
            _ = reader.raw("image_url")
            var inner = FieldReader(image, path: reader.path("image_url"))
            _ = inner.raw("url")
            let detail = try inner.string("detail")
            inner.dropRemaining(warnings: &warnings)
            var media = WireMedia(source: .url(url), detail: detail)
            if let data = DataURL.parse(url) {
                media.source = .base64(data.data)
                media.mediaType = data.mediaType
            }
            media.extra = reader.remaining(warnings: &warnings)
            media.cacheControl = WireCacheControl.lift(from: &media.extra)
            return .image(media)

        case "file":
            guard case .object(let file)? = object["file"] else { return opaque("file part without `file` kept as opaque") }
            var inner = FieldReader(file, path: reader.path("file"))
            let fileData = try inner.string("file_data")
            let fileID = try inner.string("file_id")
            let filename = try inner.string("filename")
            var media: WireMedia
            if let fileData {
                if let data = DataURL.parse(fileData) {
                    media = WireMedia(source: .base64(data.data), mediaType: data.mediaType)
                } else {
                    // Some clients send bare base64; no media type remembers that.
                    media = WireMedia(source: .base64(fileData))
                }
                if fileID != nil {
                    warnings.append(WireWarning(.droppedField, "`file_id` ignored beside `file_data`", path: inner.path("file_id")))
                }
            } else if let fileID {
                media = WireMedia(source: .fileID(fileID))
            } else {
                return opaque("file part without data or id kept as opaque")
            }
            _ = reader.raw("file")
            inner.dropRemaining(warnings: &warnings)
            media.filename = filename
            media.extra = reader.remaining(warnings: &warnings)
            media.cacheControl = WireCacheControl.lift(from: &media.extra)
            return .file(media)

        default:
            return opaque("content part of type `\(type)` kept as opaque")
        }
    }

    /// Decodes an assistant `tool_calls` entry. Chat requires call ids; a
    /// non-conforming call without one gets `syntheticID` (marked
    /// synthesized) and a warning.
    static func toolCall(
        _ value: JSONValue,
        path: String,
        syntheticID: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WirePart {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        if let type = object["type"]?.stringValue, type != "function" {
            warnings.append(WireWarning(.opaqueContent, "tool call of type `\(type)` kept as opaque", path: path))
            return .opaque(WireOpaque(protocol: .chatCompletions, value: value, slot: "tool_calls"))
        }
        var reader = FieldReader(object, path: path)
        let id = try reader.string("id")
        _ = try reader.string("type")
        guard let function = try reader.object("function") else {
            throw WireDecodingError(.missingField, path: reader.path("function"))
        }
        var inner = FieldReader(function, path: reader.path("function"))
        let name = try inner.requiredString("name")
        let arguments: String
        switch inner.raw("arguments") {
        case .string(let text)?:
            arguments = text
        case nil, .null?:
            arguments = ""
        case let other?:
            // Non-conforming clients send an object; keep its JSON text.
            arguments = String(decoding: other.encoded(), as: UTF8.self)
            warnings.append(WireWarning(.lossyConversion, "non-string arguments encoded as a JSON string", path: inner.path("arguments")))
        }
        inner.dropRemaining(warnings: &warnings)
        if id == nil {
            warnings.append(WireWarning(.lossyConversion, "tool call without an id given `\(syntheticID)`", path: path))
        }
        let gemini = ChatGemini.split(reader.raw(ChatGemini.key))
        var extra = reader.remaining(warnings: &warnings)
        ChatGemini.keep(gemini.rest, in: &extra, path: reader.path(ChatGemini.key), warnings: &warnings)
        return .toolCall(WireToolCall(
            id: id ?? syntheticID, idSynthesized: id == nil, name: name, arguments: arguments,
            signature: gemini.signature, extra: extra,
        ))
    }

    /// Decodes a message (request `messages[i]` or response `choices[0].message`).
    ///
    /// - Parameter idPrefix: prefix of position-based ids synthesized for
    ///   tool calls that lack one (`<prefix>_<call index>`), unique per message.
    static func message(
        _ value: JSONValue,
        path: String,
        idPrefix: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WireMessage {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        var reader = FieldReader(object, path: path)
        let role = WireRole(rawValue: try reader.requiredString("role"))

        if role == .tool {
            let callID = try reader.requiredString("tool_call_id")
            let content = try content(reader.raw("content"), path: reader.path("content"), warnings: &warnings)
            let result = WireToolResult(callID: callID, content: content.parts, contentForm: content.form)
            return WireMessage(role: role, parts: [.toolResult(result)], extra: reader.remaining(warnings: &warnings))
        }

        var parts: [WirePart] = []
        if role == .assistant {
            // Either spelling; a second one present too stays in the bag.
            let plain = chatReasoningKeys.lazy.compactMap { key in object[key]?.stringValue.map { (key: key, text: $0) } }.first
            // Readable `reasoning_details` are typed, and their text is the
            // reasoning; the plain field (OpenRouter sends both) is then
            // only its spelling. Details without text (encrypted data
            // only) leave the plain field its own reasoning part.
            if let details = ChatReasoningDetails.entries(object[ChatReasoningDetails.key]), !details.isEmpty {
                _ = reader.raw(ChatReasoningDetails.key)
                var spelling: String?
                if let plain {
                    if ChatReasoningDetails.text(details) == nil {
                        _ = reader.raw(plain.key)
                        parts.append(.reasoning(WireReasoning(text: plain.text, sourceKey: plain.key)))
                    } else if !plain.text.isEmpty {
                        _ = reader.raw(plain.key)
                        spelling = plain.key
                    }
                }
                for (i, entry) in details.enumerated() {
                    parts.append(.reasoning(ChatReasoningDetails.reasoning(entry, origin: nil, sourceKey: i == 0 ? spelling : nil)))
                }
            } else if let plain {
                _ = reader.raw(plain.key)
                parts.append(.reasoning(WireReasoning(text: plain.text, sourceKey: plain.key)))
            }
        }
        var content = try content(reader.raw("content"), path: reader.path("content"), warnings: &warnings)
        // Gemini signs the message's text (non-streaming replies): the
        // signature goes on the last text part, the rest of
        // `extra_content` stays in the message's bag.
        var gemini = role == .assistant ? ChatGemini.split(object[ChatGemini.key]) : ChatGemini.Split()
        // A message-level thought marker has no typed home (the content is
        // the message's text): it stays in the bag.
        if gemini.thought {
            gemini.rest = ChatGemini.join(rest: gemini.rest, signature: nil, thought: true)
            gemini.thought = false
        }
        if let signature = gemini.signature,
           let last = content.parts.lastIndex(where: { if case .text = $0 { true } else { false } }),
           case .text(var text) = content.parts[last]
        {
            _ = reader.raw(ChatGemini.key)
            text.signature = signature
            content.parts[last] = .text(text)
        }
        parts += content.parts
        if role == .assistant {
            if let refusal = try reader.string("refusal") {
                parts.append(.refusal(WireRefusal(refusal, sourceKey: "refusal")))
            }
            // An empty array has no part to live in; it stays in the bag.
            if case .array(let calls)? = object["tool_calls"], !calls.isEmpty {
                _ = reader.raw("tool_calls")
                for (i, call) in calls.enumerated() {
                    parts.append(try toolCall(
                        call, path: WirePath.index(reader.path("tool_calls"), i),
                        syntheticID: "\(idPrefix)_\(i)", warnings: &warnings,
                    ))
                }
            }
        }
        var extra = reader.remaining(warnings: &warnings)
        if reader.consumed.contains(ChatGemini.key) {
            ChatGemini.keep(gemini.rest, in: &extra, path: reader.path(ChatGemini.key), warnings: &warnings)
        }
        return WireMessage(role: role, parts: parts, contentForm: content.form, extra: extra)
    }
}

// MARK: - Encoding

enum ChatEncode {
    /// Encodes content parts as a message `content` value, honouring the
    /// recorded form. Returns `nil` to omit the key.
    ///
    /// Parts Chat cannot carry are dropped first (with warnings). Plain text
    /// is written as a string when the form says so, or, with no recorded
    /// form, when there is a single text part or `joinTexts` is set (Chat
    /// replies carry one string, so an assistant's text blocks are joined).
    /// Empty content honours the form only for the same protocol; otherwise
    /// it is `emptyDefault`.
    static func content(
        _ parts: [WirePart],
        form: WireContentForm?,
        emptyDefault: JSONValue?,
        joinTexts: Bool = false,
        include: Bool,
        cache: Bool = false,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        var items: [JSONValue] = []
        var texts: [String] = []
        var allPlain = true
        for (i, part) in parts.enumerated() {
            guard let item = self.part(part, include: include, cache: cache, path: WirePath.index(path, i), warnings: &warnings) else {
                continue
            }
            // Mistral: a later text part of the `thinking` part before.
            if ChatMistral.continues(part), case .object(var previous)? = items.last, previous["type"] == "thinking",
               case .array(var list)? = previous["thinking"], case .array(let more)? = item["thinking"]
            {
                list += more
                previous["thinking"] = .array(list)
                items[items.count - 1] = .object(previous)
                allPlain = false
                continue
            }
            items.append(item)
            // Plain: nothing in the part's bag, breakpoint or options would
            // be lost by a string.
            if case .text(let text) = part, text.extra.isEmpty || !include,
               !(cache && text.cacheControl != nil), !hasPatch(text.patch, for: .chatCompletions)
            {
                texts.append(text.text)
            } else {
                allPlain = false
            }
        }
        if items.isEmpty {
            // Another protocol's form says nothing about Chat: its empty
            // array (an Anthropic tool-only turn) is rejected by OpenAI.
            guard include else { return emptyDefault }
            switch form {
            case .string: return ""
            case .parts: return .array([])
            case .null: return .null
            case .absent: return nil
            case nil: return emptyDefault
            }
        }
        let useString = switch form {
        case .string, .null, .absent: allPlain
        case .parts: false
        case nil: allPlain && (texts.count == 1 || joinTexts)
        }
        guard useString else { return .array(items) }
        if texts.count > 1 {
            warnings.append(WireWarning(.lossyConversion, "text parts joined into one string", path: path))
        }
        return .string(texts.joined())
    }

    /// Encodes one content part, or `nil` (with a warning) if Chat cannot
    /// carry it in a content array.
    static func part(
        _ part: WirePart,
        include: Bool,
        cache: Bool = false,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        var object = JSONObject()
        let noCache = "this Chat upstream takes no cache_control"
        switch part {
        case .text(let text):
            object["type"] = "text"
            object["text"] = .string(text.text)
            if text.signature != nil {
                warnings.append(WireWarning(.droppedContent, "text signature cannot be carried by Chat", path: path))
            }
            appendExtra(text.extra, to: &object, include: include, path: path, warnings: &warnings)
            writeCacheControl(text.cacheControl, to: &object, allowed: cache, path: path, reason: noCache, warnings: &warnings)
            applyPatch(text.patch, to: &object, target: .chatCompletions)

        case .refusal(let refusal):
            object["type"] = "refusal"
            object["refusal"] = .string(refusal.text)
            appendExtra(refusal.extra, to: &object, include: include, path: path, warnings: &warnings)
            applyPatch(refusal.patch, to: &object, target: .chatCompletions)

        case .image(let media):
            let url: String
            switch media.source {
            case .url(let value): url = value
            case .base64(let data): url = DataURL.make(mediaType: media.mediaType ?? "image/png", data: data)
            case .fileID:
                warnings.append(WireWarning(.droppedContent, "Chat images cannot reference a file id", path: path))
                return nil
            }
            var image = JSONObject()
            image["url"] = .string(url)
            if let detail = media.detail { image["detail"] = .string(detail) }
            object["type"] = "image_url"
            object["image_url"] = .object(image)
            appendExtra(media.extra, to: &object, include: include, path: path, warnings: &warnings)
            writeCacheControl(media.cacheControl, to: &object, allowed: cache, path: path, reason: noCache, warnings: &warnings)
            applyPatch(media.patch, to: &object, target: .chatCompletions)

        case .file(let media):
            var file = JSONObject()
            switch media.source {
            case .base64(let data):
                file["file_data"] = .string(media.mediaType.map { DataURL.make(mediaType: $0, data: data) } ?? data)
            case .fileID(let id):
                file["file_id"] = .string(id)
            case .url:
                warnings.append(WireWarning(.droppedContent, "Chat file parts cannot reference a URL", path: path))
                return nil
            }
            if let filename = media.filename { file["filename"] = .string(filename) }
            object["type"] = "file"
            object["file"] = .object(file)
            appendExtra(media.extra, to: &object, include: include, path: path, warnings: &warnings)
            writeCacheControl(media.cacheControl, to: &object, allowed: cache, path: path, reason: noCache, warnings: &warnings)
            applyPatch(media.patch, to: &object, target: .chatCompletions)

        case .opaque(let opaque):
            guard opaque.protocol == .chatCompletions else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) content cannot be carried by Chat", path: path))
                return nil
            }
            return opaque.value

        case .reasoning(let reasoning) where include && reasoning.sourceKey == ChatMistral.thinkingSourceKey:
            guard case .object(var thinking) = ChatMistral.thinking(reasoning.text) else { return nil }
            if reasoning.hasSignedData {
                warnings.append(WireWarning(.droppedContent, "reasoning signature/encrypted data cannot be carried by Chat", path: path))
            }
            appendExtra(reasoning.extra, to: &thinking, include: include, path: path, warnings: &warnings)
            applyPatch(reasoning.patch, to: &thinking, target: .chatCompletions)
            return .object(thinking)

        case .reasoning, .toolCall, .toolResult:
            warnings.append(WireWarning(.droppedContent, "part cannot appear in Chat content", path: path))
            return nil
        }
        return .object(object)
    }

    /// Item ids (Responses `fc_…`, `msg_…`) are dropped silently: they are
    /// bookkeeping, not content. Signatures are content and warn.
    static func toolCall(
        _ call: WireToolCall,
        replay: ChatReplay,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue {
        let include = replay.include
        var function = JSONObject()
        function["name"] = .string(call.name)
        function["arguments"] = .string(call.arguments)
        var object = JSONObject()
        object["id"] = .string(call.id)
        object["type"] = "function"
        object["function"] = .object(function)
        // A signature goes in Gemini's dialect (`extra_content`).
        let writes = call.signature != nil && replay.accepts(call.origin)
        if call.signature != nil, !writes {
            warnings.append(WireWarning(.droppedContent, "tool call signature cannot be carried by Chat", path: path))
        }
        if let itemType = call.itemType {
            warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a function call", path: path))
        }
        ChatGemini.appendBag(call.extra, signature: call.signature, write: writes, to: &object, include: include, path: path, warnings: &warnings)
        dropCacheControl(call.cacheControl, path: path, reason: "Chat tool calls cannot carry one", warnings: &warnings)
        applyPatch(call.patch, to: &object, target: .chatCompletions)
        return .object(object)
    }

    /// Encodes one wire message as one or more Chat messages: tool results
    /// become `tool` messages (first, so they follow the assistant turn that
    /// called them), the remaining parts one message of the original role.
    /// A role-less ``WireRole/item`` keeps only its tool results.
    ///
    /// `include` (target == source protocol) also gates the source-spelling
    /// hints (`sourceKey`) of reasoning and refusals.
    static func messages(
        _ message: WireMessage,
        include: Bool,
        cache: Bool = false,
        trusted: Set<WireSystemID>? = nil,
        path: String,
        warnings: inout [WireWarning],
    ) -> [JSONValue] {
        let replay = ChatReplay(include: include, trusted: trusted)
        var output: [JSONValue] = []
        var rest: [WirePart] = []
        var reasoning: [WireReasoning] = []
        var refusals: [WireRefusal] = []
        // Where each reasoning and refusal part was in the message.
        var reasoningIndices: [Int] = []
        var refusalIndices: [Int] = []
        // Function calls and opaque (non-function) calls, in order.
        var calls: [JSONValue] = []
        var results: [WireToolResult] = []
        let isAssistant = message.role == .assistant
        let callsPath = WirePath.key(path, "tool_calls")
        var textSignature: String?
        var textExtraContent: JSONValue?

        for (index, part) in message.parts.enumerated() {
            switch part {
            case .toolResult(let result):
                results.append(result)
            case .reasoning(let value) where isAssistant && !(include && value.sourceKey == ChatMistral.thinkingSourceKey):
                // Same protocol, Mistral's `thinking` content parts stay in
                // the content (``part(_:include:path:warnings:)``).
                reasoning.append(value)
                reasoningIndices.append(index)
            case .text(var text) where isAssistant
                && (text.signature != nil && replay.accepts(text.origin) || include && text.extra[ChatGemini.key] != nil):
                // Gemini's text signature (and the rest of its
                // `extra_content`) belongs to the message.
                if let signature = text.signature, replay.accepts(text.origin) {
                    if textSignature != nil {
                        warnings.append(WireWarning(.droppedContent, "only one text signature fits a Chat message", path: path))
                    }
                    textSignature = signature
                    text.signature = nil
                }
                if let value = text.extra.removeValue(forKey: ChatGemini.key), textExtraContent == nil { textExtraContent = value }
                rest.append(.text(text))
            case .toolCall(let call) where isAssistant:
                calls.append(toolCall(call, replay: replay, path: WirePath.index(callsPath, calls.count), warnings: &warnings))
            case .refusal(let refusal) where isAssistant && !(include && refusal.sourceKey == nil):
                // Same protocol: back where it came from (a content part has
                // no sourceKey). Otherwise the message field, valid everywhere.
                refusals.append(refusal)
                refusalIndices.append(index)
            case .opaque(let opaque) where opaque.slot == "tool_calls":
                if opaque.protocol == .chatCompletions, isAssistant {
                    calls.append(opaque.value)
                } else {
                    warnings.append(WireWarning(.droppedContent, "opaque tool call cannot be carried by Chat", path: callsPath))
                }
            default:
                rest.append(part)
            }
        }

        for result in results {
            var object = JSONObject()
            object["role"] = "tool"
            // A result's breakpoint goes on the last part of its message.
            let carries = cache && result.cacheControl != nil
            var content = content(
                result.content, form: carries ? .parts : result.contentForm, emptyDefault: "",
                include: include, cache: cache, path: WirePath.key(path, "content"), warnings: &warnings,
            )
            if let cacheControl = result.cacheControl {
                if carries, case .array(var items)? = content, case .object(var last)? = items.last {
                    if !last.contains(key: WireCacheControl.key) { last[WireCacheControl.key] = cacheControl.json }
                    items[items.count - 1] = .object(last)
                    content = .array(items)
                } else if carries, content == nil || content == "" || content == .array([]) {
                    // An empty result: an empty text part carries it.
                    content = [["type": "text", "text": "", WireCacheControl.key: cacheControl.json]]
                } else {
                    let reason = carries ? "the tool message has no content part to carry it" : "this Chat upstream takes no cache_control"
                    dropCacheControl(cacheControl, path: path, reason: reason, warnings: &warnings)
                }
            }
            if let content { object["content"] = content }
            object["tool_call_id"] = .string(result.callID)
            if result.isError == true {
                warnings.append(WireWarning(.lossyConversion, "Chat tool messages cannot mark an error", path: path))
            }
            if let itemType = result.itemType {
                warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a tool message", path: path))
            }
            appendExtra(result.extra, to: &object, include: include, path: path, warnings: &warnings)
            if message.role == .tool {
                appendExtra(message.extra, to: &object, include: include, path: path, warnings: &warnings)
            }
            applyPatch(result.patch, to: &object, target: .chatCompletions)
            applyPatch(message.patch, to: &object, target: .chatCompletions)
            output.append(.object(object))
        }
        if message.role == .tool { return output }
        if message.role == .item {
            if !rest.isEmpty || !reasoning.isEmpty || !refusals.isEmpty || !calls.isEmpty {
                warnings.append(WireWarning(.droppedContent, "role-less item cannot be carried by Chat", path: path))
            }
            return output
        }
        let hasMain = !rest.isEmpty || !reasoning.isEmpty || !refusals.isEmpty || !calls.isEmpty
        if !results.isEmpty, !hasMain { return output }

        var object = JSONObject()
        object["role"] = .string(message.role.rawValue)
        let emptyDefault: JSONValue? = isAssistant ? .null : ""
        if let content = content(
            rest, form: message.contentForm, emptyDefault: emptyDefault, joinTexts: isAssistant,
            include: include, cache: cache, path: WirePath.key(path, "content"), warnings: &warnings,
        ) {
            object["content"] = content
        }
        // Another protocol's reasoning without text (signature only) has
        // nothing to say in Chat; an empty `reasoning_content` is noise.
        let reasoningText = reasoning.map(\.text).joined()
        if !reasoning.isEmpty, !include, reasoningText.isEmpty {
            if reasoning.contains(where: \.hasSignedData) {
                warnings.append(WireWarning(.droppedContent, "reasoning signature/encrypted data cannot be carried by Chat", path: path))
            }
            var unused = JSONObject()
            for item in reasoning {
                appendExtra(item.extra, to: &unused, include: false, path: path, warnings: &warnings)
            }
        } else if !reasoning.isEmpty {
            // Same protocol: parts decoded from `reasoning_details` go back
            // there, with their signatures and encrypted data.
            var entries: [JSONValue] = []
            var plain: [WireReasoning] = []
            for item in reasoning {
                // An entry without signed data is only text: no trust needed.
                let accepted = item.hasSignedData ? replay.accepts(item.origin) : include || trusted != nil
                if accepted, let entry = ChatReasoningDetails.encode(item) { entries.append(entry) } else { plain.append(item) }
            }
            let sourceKey = include ? reasoning.first?.sourceKey : nil
            let spelling = sourceKey.flatMap { chatReasoningKeys.contains($0) ? $0 : nil }
            let key = spelling ?? "reasoning_content"
            let keyPath = WirePath.key(path, key)
            // Details alone (no plain field in the source) need no string.
            if spelling != nil || !plain.isEmpty || entries.isEmpty {
                object[key] = .string(reasoningText)
            }
            if plain.count > 1 {
                warnings.append(WireWarning(.lossyConversion, "reasoning blocks joined into one string", path: keyPath))
            }
            if plain.contains(where: \.hasSignedData) {
                warnings.append(WireWarning(.droppedContent, "reasoning signature/encrypted data cannot be carried by Chat", path: keyPath))
            }
            for item in plain {
                // Chat reasoning is a plain string: an object's bag has no place.
                var unused = JSONObject()
                appendExtra(item.extra, to: &unused, include: false, path: keyPath, warnings: &warnings)
            }
            if !entries.isEmpty { object[ChatReasoningDetails.key] = .array(entries) }
        }
        if !refusals.isEmpty {
            object["refusal"] = .string(refusals.map(\.text).joined())
        }
        if !calls.isEmpty {
            object["tool_calls"] = .array(calls)
        }
        var extra = message.extra
        if extra[ChatGemini.key] == nil, let textExtraContent { extra[ChatGemini.key] = textExtraContent }
        ChatGemini.appendBag(extra, signature: textSignature, write: textSignature != nil, to: &object, include: include, path: path, warnings: &warnings)
        // Reasoning and refusals are message fields here: no object of their own.
        for (item, p) in zip(reasoning, reasoningIndices) {
            dropPatch(item.patch, target: .chatCompletions, path: WirePath.index(WirePath.key(path, "content"), p), warnings: &warnings)
        }
        for (item, p) in zip(refusals, refusalIndices) {
            dropPatch(item.patch, target: .chatCompletions, path: WirePath.index(WirePath.key(path, "content"), p), warnings: &warnings)
        }
        applyPatch(message.patch, to: &object, target: .chatCompletions)
        output.append(.object(object))
        return output
    }
}

// MARK: - Finish reasons and usage

enum ChatFinish {
    static func decode(_ raw: String) -> WireFinishReason {
        let unified: WireFinishReason.Unified = switch raw {
        case "stop": .stop
        case "length": .length
        case "tool_calls", "function_call": .toolCalls
        case "content_filter": .contentFilter
        default: .other
        }
        return WireFinishReason(unified, raw: raw)
    }

    /// A missing reason is written as `"stop"`, the same in replies and streams.
    static func encode(_ reason: WireFinishReason?, sameProtocol: Bool) -> JSONValue {
        guard let reason else { return "stop" }
        if sameProtocol, let raw = reason.raw { return .string(raw) }
        return switch reason.unified {
        case .stop, .error, .other: "stop"
        case .length: "length"
        case .toolCalls: "tool_calls"
        case .contentFilter: "content_filter"
        }
    }
}

enum ChatUsage {
    /// Decodes a `usage` object. Bags are kept but produce no warnings:
    /// vendors add many counters and they are not request content.
    static func decode(_ object: JSONObject, path: String) throws(WireDecodingError) -> WireUsage {
        var ignored: [WireWarning] = []
        var reader = FieldReader(object, path: path)
        var usage = WireUsage()
        usage.inputTokens = try reader.int("prompt_tokens")
        usage.outputTokens = try reader.int("completion_tokens")
        usage.totalTokens = try reader.int("total_tokens")
        if let details = try reader.object("prompt_tokens_details") {
            var inner = FieldReader(details, path: reader.path("prompt_tokens_details"))
            usage.cachedInputTokens = try inner.int("cached_tokens")
            usage.cacheWriteTokens = try inner.int("cache_write_tokens")
            usage.inputDetailsExtra = inner.remaining(warnings: &ignored)
        }
        if let details = try reader.object("completion_tokens_details") {
            var inner = FieldReader(details, path: reader.path("completion_tokens_details"))
            usage.reasoningTokens = try inner.int("reasoning_tokens")
            usage.outputDetailsExtra = inner.remaining(warnings: &ignored)
        }
        usage.extra = reader.remaining(warnings: &ignored)
        return usage
    }

    static func encode(_ usage: WireUsage, include: Bool, path: String, warnings: inout [WireWarning]) -> JSONValue {
        var object = JSONObject()
        if let value = usage.inputTokens { object["prompt_tokens"] = .number(JSONNumber(value)) }
        if let value = usage.outputTokens { object["completion_tokens"] = .number(JSONNumber(value)) }
        if let value = usage.totalTokens {
            object["total_tokens"] = .number(JSONNumber(value))
        } else if !include, let input = usage.inputTokens, let output = usage.outputTokens {
            object["total_tokens"] = .number(JSONNumber(input + output))
        }
        let inputExtra = include ? usage.inputDetailsExtra : nil
        // `cache_write_tokens` is OpenRouter's, not OpenAI's: written back
        // only to the Chat dialect it came from.
        let cacheWrite = include ? usage.cacheWriteTokens : nil
        if usage.cachedInputTokens != nil || cacheWrite != nil || inputExtra != nil {
            var details = JSONObject()
            if let value = usage.cachedInputTokens { details["cached_tokens"] = .number(JSONNumber(value)) }
            if let value = cacheWrite { details["cache_write_tokens"] = .number(JSONNumber(value)) }
            appendExtra(inputExtra ?? [:], to: &details, include: true, path: path, warnings: &warnings)
            object["prompt_tokens_details"] = .object(details)
        }
        let outputExtra = include ? usage.outputDetailsExtra : nil
        if usage.reasoningTokens != nil || outputExtra != nil {
            var details = JSONObject()
            if let value = usage.reasoningTokens { details["reasoning_tokens"] = .number(JSONNumber(value)) }
            appendExtra(outputExtra ?? [:], to: &details, include: true, path: path, warnings: &warnings)
            object["completion_tokens_details"] = .object(details)
        }
        // Vendor counters from another protocol are not worth a warning each.
        var ignored: [WireWarning] = []
        appendExtra(usage.extra, to: &object, include: include, path: path, warnings: &ignored)
        return .object(object)
    }
}
