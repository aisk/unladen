// Anthropic Messages content blocks, shared by the request and response
// directions, plus finish reasons, usage and the reasoning replay decision.

// MARK: - Reasoning replay

/// Decides whether a reasoning part's fidelity data (thinking `signature`,
/// `redacted_thinking.data`) may be written for an Anthropic peer.
///
/// This is the single swap point for the phase-4 endpoint trust sets:
/// everything Anthropic-bound asks ``accepts(_:sameProtocol:trusted:)``.
enum AnthropicReplay {
    /// The system id Anthropic decoders stamp on fidelity data by default.
    static let system: WireSystemID = "anthropic"

    /// - A part with an ``WireReasoning/origin`` is accepted iff the origin
    ///   is trusted.
    /// - A part without one came from a client request; it is accepted only
    ///   when that request was Anthropic too (the client is replaying what
    ///   an Anthropic reply gave it).
    static func accepts(_ reasoning: WireReasoning, sameProtocol: Bool, trusted: Set<WireSystemID>) -> Bool {
        guard let origin = reasoning.origin else { return sameProtocol }
        return trusted.contains(origin)
    }
}

// MARK: - Tool ids

/// Anthropic accepts only `[A-Za-z0-9_-]+` as a `tool_use` id; other
/// protocols' call ids may contain anything (`functions.get:0`, `call|x`).
///
/// ``outbound(_:)`` maps any id to a valid one, reversibly and statelessly:
/// a valid id that does not start with ``mark`` is itself; any other id is
/// ``mark`` + its unpadded base64url. ``inbound(_:)`` undoes that, so the
/// upstream that made a call gets its own id back whichever request or
/// gateway instance the result comes through. Encoders (requests to an
/// Anthropic upstream, replies to an Anthropic client) apply `outbound`;
/// decoders (client requests, upstream replies) apply `inbound`.
@_spi(Wire) public enum AnthropicToolID {
    public static let mark = "unl_"

    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    public static func outbound(_ id: String) -> String {
        if id.isEmpty || (isValid(id) && !id.hasPrefix(mark)) { return id }
        return mark + Base64.encode(Array(id.utf8), urlSafe: true)
    }

    public static func inbound(_ id: String) -> String {
        guard id.hasPrefix(mark), isValid(id),
              let bytes = Base64.decode(String(id.dropFirst(mark.count)), urlSafe: true), !bytes.isEmpty,
              case let raw = String(decoding: bytes, as: UTF8.self), Array(raw.utf8) == bytes, outbound(raw) == id
        else { return id }
        return raw
    }
}

// MARK: - Decoding

enum AnthropicDecode {
    /// Fields Anthropic defines that the wire model keeps in bags: no
    /// unknown-field warning for them. (`cache_control` is lifted into
    /// ``WireCacheControl`` afterwards when its spelling allows.)
    static let quietBagKeys: Set<String> = ["cache_control", "citations"]

    /// The bag of `reader`'s unconsumed keys, warning only for keys that are
    /// neither in ``quietBagKeys`` nor in `quiet`.
    static func bag(_ reader: FieldReader, quiet: Set<String> = [], warnings: inout [WireWarning]) -> JSONObject {
        var local: [WireWarning] = []
        let bag = reader.remaining(warnings: &local)
        for warning in local {
            let isQuiet = (quietBagKeys.union(quiet)).contains { warning.path == reader.path($0) }
            if !isQuiet { warnings.append(warning) }
        }
        return bag
    }

    /// Anthropic block types the codec keeps opaque on purpose (server tools,
    /// their results, uploads); they produce no warning when decoded.
    static func isKnownOpaque(_ type: String) -> Bool {
        type.hasSuffix("_tool_use") || type.hasSuffix("_tool_result")
            || ["container_upload", "search_result", "compaction"].contains(type)
    }

    /// Decodes a `content` value: absent, a string, or blocks. `null` is not
    /// Anthropic but is tolerated (and written back) as ``WireContentForm/null``.
    static func content(
        _ raw: JSONValue?,
        path: String,
        origin: WireSystemID?,
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
                parts.append(try block(item, path: WirePath.index(path, i), origin: origin, warnings: &warnings))
            }
            return (parts, .parts)
        default:
            throw WireDecodingError(.typeMismatch(expected: "a string or an array"), path: path)
        }
    }

    /// Decodes one content block. Unknown or malformed-but-JSON blocks become
    /// opaque parts so the same protocol can send them on.
    ///
    /// - Parameter origin: stamped on every reasoning part (replies); `nil`
    ///   for client requests, whose origin is unknown.
    static func block(
        _ value: JSONValue,
        path: String,
        origin: WireSystemID?,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WirePart {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        func opaque(_ why: String?) -> WirePart {
            if let why { warnings.append(WireWarning(.opaqueContent, why, path: path)) }
            return .opaque(WireOpaque(protocol: .anthropicMessages, value: value))
        }
        guard case .string(let type)? = object["type"] else {
            return opaque("content block without a `type` kept as opaque")
        }
        var reader = FieldReader(object, path: path)
        _ = reader.raw("type")
        switch type {
        case "text":
            guard case .string(let text)? = object["text"] else { return opaque("malformed text block kept as opaque") }
            _ = reader.raw("text")
            var extra = bag(reader, warnings: &warnings)
            let cache = WireCacheControl.lift(from: &extra)
            return .text(WireText(text, extra: extra, cacheControl: cache))

        case "image", "document":
            guard let source = mediaSource(object["source"]) else {
                return opaque("\(type) block with an unsupported source kept as opaque")
            }
            _ = reader.raw("source")
            var media = WireMedia(source: source.source, mediaType: source.mediaType)
            if type == "document", case .string(let title)? = object["title"] {
                _ = reader.raw("title")
                media.filename = title
            }
            media.extra = bag(reader, quiet: ["context"], warnings: &warnings)
            media.cacheControl = WireCacheControl.lift(from: &media.extra)
            return type == "image" ? .image(media) : .file(media)

        case "thinking":
            guard case .string(let text)? = object["thinking"] else { return opaque("malformed thinking block kept as opaque") }
            _ = reader.raw("thinking")
            // `""` is the placeholder Anthropic replies carry for another
            // system's reasoning (see Context.keepUnsignedReasoning), echoed
            // by clients: it signs nothing.
            let signature = try reader.string("signature").flatMap { $0.isEmpty ? nil : $0 }
            return .reasoning(WireReasoning(
                text: text, signature: signature, origin: origin, extra: bag(reader, warnings: &warnings),
            ))

        case "redacted_thinking":
            guard case .string(let data)? = object["data"] else { return opaque("malformed redacted_thinking block kept as opaque") }
            _ = reader.raw("data")
            return .reasoning(WireReasoning(
                text: "", encrypted: data, origin: origin, extra: bag(reader, warnings: &warnings),
            ))

        case "tool_use":
            guard case .string(let id)? = object["id"], case .string(let name)? = object["name"] else {
                return opaque("tool_use block without `id` and `name` kept as opaque")
            }
            _ = reader.raw("id")
            _ = reader.raw("name")
            let arguments = reader.raw("input").map { String(decoding: $0.encoded(), as: UTF8.self) } ?? ""
            var extra = bag(reader, warnings: &warnings)
            let cache = WireCacheControl.lift(from: &extra)
            return .toolCall(WireToolCall(
                id: AnthropicToolID.inbound(id), name: name, arguments: arguments, extra: extra, cacheControl: cache,
            ))

        case "tool_result":
            guard case .string(let callID)? = object["tool_use_id"] else {
                return opaque("tool_result block without `tool_use_id` kept as opaque")
            }
            _ = reader.raw("tool_use_id")
            let content = try content(reader.raw("content"), path: reader.path("content"), origin: origin, warnings: &warnings)
            let isError = try reader.bool("is_error")
            var extra = bag(reader, warnings: &warnings)
            let cache = WireCacheControl.lift(from: &extra)
            return .toolResult(WireToolResult(
                callID: AnthropicToolID.inbound(callID), content: content.parts, contentForm: content.form, isError: isError,
                extra: extra, cacheControl: cache,
            ))

        default:
            return opaque(isKnownOpaque(type) ? nil : "content block of type `\(type)` kept as opaque")
        }
    }

    /// An image/document `source` the wire model can express, or `nil`
    /// (unknown type, unexpected keys, text/content documents).
    private static func mediaSource(_ value: JSONValue?) -> (source: WireMediaSource, mediaType: String?)? {
        guard case .object(let source)? = value, case .string(let type)? = source["type"] else { return nil }
        switch type {
        case "base64":
            guard source.count == 3, case .string(let mediaType)? = source["media_type"],
                  case .string(let data)? = source["data"] else { return nil }
            return (.base64(data), mediaType)
        case "url":
            guard source.count == 2, case .string(let url)? = source["url"] else { return nil }
            return (.url(url), nil)
        case "file":
            guard source.count == 2, case .string(let id)? = source["file_id"] else { return nil }
            return (.fileID(id), nil)
        default:
            return nil
        }
    }

    /// Unknown in-stream `{"type":"error","error":{…}}` payloads.
    static func streamError(_ value: JSONValue?) -> WireStreamError {
        guard case .object(let object)? = value else {
            return WireStreamError(message: value?.description ?? "unknown error", raw: value)
        }
        return WireStreamError(
            message: object["message"]?.stringValue ?? "",
            type: object["type"]?.stringValue,
            raw: value,
        )
    }
}

// MARK: - Encoding

/// One encoded content block plus what message assembly needs to know.
struct AnthropicBlock {
    var json: JSONValue
    var isToolResult = false
    /// The text when the block is a text block that a bare string can stand
    /// for (no bag would be lost).
    var plainText: String?
}

enum AnthropicEncode {
    /// Settings that every block encoder needs.
    struct Context {
        /// The target is the source protocol: bags and opaque parts go back.
        var include: Bool
        /// Systems whose reasoning fidelity data the peer accepts.
        var trusted: Set<WireSystemID>
        /// Replies to a client keep foreign reasoning *text* (with an empty
        /// signature); requests to an upstream drop the whole block, since
        /// Anthropic rejects unsigned thinking. The decoder reads an empty
        /// signature as none, so a client's echo of such a block is dropped
        /// too (quietly: it is the gateway's own placeholder).
        var keepUnsignedReasoning: Bool
    }

    /// Encodes a content value from blocks, honouring the recorded form.
    /// Returns `nil` to omit the key.
    ///
    /// A bare string is used for a single plain text block when the form is
    /// ``WireContentForm/string`` or unrecorded; several blocks are never
    /// joined (blocks lose nothing).
    static func content(
        _ blocks: [AnthropicBlock],
        form: WireContentForm?,
        emptyDefault: JSONValue?,
    ) -> JSONValue? {
        if blocks.isEmpty {
            switch form {
            case .string: return ""
            case .parts: return .array([])
            case .null: return .null
            case .absent: return nil
            case nil: return emptyDefault
            }
        }
        if form != .parts, blocks.count == 1, let text = blocks[0].plainText {
            return .string(text)
        }
        return .array(blocks.map(\.json))
    }

    /// Encodes parts that may appear inside a `tool_result` or `system`.
    static func blocks(
        _ parts: [WirePart],
        context: Context,
        path: String,
        warnings: inout [WireWarning],
    ) -> [AnthropicBlock] {
        var blocks: [AnthropicBlock] = []
        for (i, part) in parts.enumerated() {
            if let block = block(part, context: context, path: WirePath.index(path, i), warnings: &warnings) {
                blocks.append(block)
            }
        }
        return blocks
    }

    /// Encodes one part as a content block, or `nil` (with a warning) if
    /// Anthropic cannot carry it.
    static func block(
        _ part: WirePart,
        context: Context,
        path: String,
        warnings: inout [WireWarning],
    ) -> AnthropicBlock? {
        let include = context.include
        var object = JSONObject()
        switch part {
        case .text(let text):
            object["type"] = "text"
            object["text"] = .string(text.text)
            if text.signature != nil {
                warnings.append(WireWarning(.droppedContent, "text signature cannot be carried by Anthropic", path: path))
            }
            appendExtra(text.extra, to: &object, include: include, path: path, warnings: &warnings)
            writeCacheControl(text.cacheControl, to: &object, allowed: true, path: path, reason: "", warnings: &warnings)
            applyPatch(text.patch, to: &object, target: .anthropicMessages)
            let plain = (text.extra.isEmpty || !include) && text.cacheControl == nil && !hasPatch(text.patch, for: .anthropicMessages)
            return AnthropicBlock(json: .object(object), plainText: plain ? text.text : nil)

        case .refusal(let refusal):
            warnings.append(WireWarning(.lossyConversion, "refusal sent as a text block", path: path))
            object["type"] = "text"
            object["text"] = .string(refusal.text)
            appendExtra(refusal.extra, to: &object, include: false, path: path, warnings: &warnings)
            applyPatch(refusal.patch, to: &object, target: .anthropicMessages)
            return AnthropicBlock(json: .object(object))

        case .image(let media), .file(let media):
            let isImage = if case .image = part { true } else { false }
            var source = JSONObject()
            switch media.source {
            case .base64(let data):
                source["type"] = "base64"
                source["media_type"] = .string(media.mediaType ?? (isImage ? "image/png" : "application/pdf"))
                source["data"] = .string(data)
            case .url(let url):
                if let data = DataURL.parse(url) {
                    source["type"] = "base64"
                    source["media_type"] = .string(data.mediaType)
                    source["data"] = .string(data.data)
                } else {
                    source["type"] = "url"
                    source["url"] = .string(url)
                }
            case .fileID(let id):
                source["type"] = "file"
                source["file_id"] = .string(id)
            }
            object["type"] = isImage ? "image" : "document"
            object["source"] = .object(source)
            if !isImage, let title = media.filename { object["title"] = .string(title) }
            if media.detail != nil {
                warnings.append(WireWarning(.droppedField, "Anthropic has no image detail setting", path: WirePath.key(path, "detail")))
            }
            if isImage, media.filename != nil {
                warnings.append(WireWarning(.droppedField, "Anthropic images have no file name", path: WirePath.key(path, "filename")))
            }
            appendExtra(media.extra, to: &object, include: include, path: path, warnings: &warnings)
            writeCacheControl(media.cacheControl, to: &object, allowed: true, path: path, reason: "", warnings: &warnings)
            applyPatch(media.patch, to: &object, target: .anthropicMessages)
            return AnthropicBlock(json: .object(object))

        case .reasoning(let reasoning):
            let accepted = AnthropicReplay.accepts(reasoning, sameProtocol: include, trusted: context.trusted)
            if accepted, !context.keepUnsignedReasoning, reasoning.encrypted == nil, reasoning.signature == nil {
                // Unsigned thinking for an upstream, which would reject it:
                // a client's echo of the empty-signature placeholder. It was
                // never signed, so dropping it loses nothing; no warning.
                return nil
            }
            if accepted, let data = reasoning.encrypted {
                object["type"] = "redacted_thinking"
                object["data"] = .string(data)
                if !reasoning.text.isEmpty {
                    warnings.append(WireWarning(.droppedContent, "reasoning text beside redacted data cannot be carried", path: path))
                }
            } else if accepted || (context.keepUnsignedReasoning && !reasoning.text.isEmpty) {
                object["type"] = "thinking"
                object["thinking"] = .string(reasoning.text)
                object["signature"] = .string((accepted ? reasoning.signature : nil) ?? "")
                if !accepted, reasoning.hasSignedData {
                    warnings.append(WireWarning(
                        .droppedContent,
                        "reasoning signature from \(reasoning.origin ?? "another protocol") cannot be carried by Anthropic",
                        path: path,
                    ))
                }
            } else {
                let from = reasoning.origin ?? "another protocol"
                warnings.append(WireWarning(.droppedContent, "reasoning from \(from) cannot be replayed to Anthropic", path: path))
                return nil
            }
            appendExtra(reasoning.extra, to: &object, include: include, path: path, warnings: &warnings)
            applyPatch(reasoning.patch, to: &object, target: .anthropicMessages)
            return AnthropicBlock(json: .object(object))

        case .toolCall(let call):
            object["type"] = "tool_use"
            object["id"] = .string(AnthropicToolID.outbound(call.id))
            object["name"] = .string(call.name)
            object["input"] = toolInput(call.arguments, path: WirePath.key(path, "input"), warnings: &warnings)
            if call.signature != nil {
                warnings.append(WireWarning(.droppedContent, "tool call signature cannot be carried by Anthropic", path: path))
            }
            if let itemType = call.itemType {
                warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a tool_use block", path: path))
            }
            appendExtra(call.extra, to: &object, include: include, path: path, warnings: &warnings)
            writeCacheControl(call.cacheControl, to: &object, allowed: true, path: path, reason: "", warnings: &warnings)
            applyPatch(call.patch, to: &object, target: .anthropicMessages)
            return AnthropicBlock(json: .object(object))

        case .toolResult(var result):
            object["type"] = "tool_result"
            object["tool_use_id"] = .string(AnthropicToolID.outbound(result.callID))
            let contentPath = WirePath.key(path, "content")
            if !include {
                // Another protocol's breakpoint inside the result marks the
                // result (Anthropic's place for it).
                for i in result.hoistCacheControl() {
                    dropCacheControl(
                        WireCacheControl(), path: WirePath.index(contentPath, i),
                        reason: "a tool result carries one breakpoint", warnings: &warnings,
                    )
                }
            }
            let inner = blocks(result.content, context: context, path: contentPath, warnings: &warnings).filter { block in
                let type = block.json["type"]?.stringValue ?? ""
                if ["text", "image", "document", "search_result"].contains(type) { return true }
                warnings.append(WireWarning(.droppedContent, "`\(type)` cannot appear in a tool_result", path: contentPath))
                return false
            }
            // Another protocol's empty result: omitting `content` is always valid.
            let emptyForm: WireContentForm? = include ? result.contentForm : .absent
            if let content = content(inner, form: inner.isEmpty ? emptyForm : result.contentForm, emptyDefault: nil) {
                object["content"] = content
            }
            if let isError = result.isError { object["is_error"] = .bool(isError) }
            if let itemType = result.itemType {
                warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a tool_result block", path: path))
            }
            appendExtra(result.extra, to: &object, include: include, path: path, warnings: &warnings)
            writeCacheControl(result.cacheControl, to: &object, allowed: true, path: path, reason: "", warnings: &warnings)
            applyPatch(result.patch, to: &object, target: .anthropicMessages)
            return AnthropicBlock(json: .object(object), isToolResult: true)

        case .opaque(let opaque):
            guard opaque.protocol == .anthropicMessages else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) content cannot be carried by Anthropic", path: path))
                return nil
            }
            return AnthropicBlock(json: opaque.value, isToolResult: opaque.value["type"] == "tool_result")
        }
    }

    /// The `input` object for tool-call arguments. Empty arguments are `{}`;
    /// text that is not a JSON object becomes `{}` with a warning, since
    /// Anthropic accepts only objects.
    static func toolInput(_ arguments: String, path: String, warnings: inout [WireWarning]) -> JSONValue {
        if arguments.trimmingASCIIWhitespace().isEmpty { return .object([:]) }
        if let value = try? JSONValue(parsing: arguments), case .object = value { return value }
        warnings.append(WireWarning(.lossyConversion, "tool arguments are not a JSON object; sent as {}", path: path))
        return .object([:])
    }
}

// MARK: - Finish reasons and usage

enum AnthropicFinish {
    /// Top-level reply keys that describe the finish. Streams deliver them in
    /// `message_delta.delta`, so both directions keep them in
    /// ``WireResponse/choiceExtra`` / ``WireFinish/extra``.
    static let extraKeys = ["stop_sequence", "stop_details"]

    static func decode(_ raw: String) -> WireFinishReason {
        let unified: WireFinishReason.Unified = switch raw {
        case "end_turn", "stop_sequence": .stop
        case "max_tokens", "model_context_window_exceeded": .length
        case "tool_use": .toolCalls
        case "refusal": .contentFilter
        default: .other // pause_turn, compaction, unknown
        }
        return WireFinishReason(unified, raw: raw)
    }

    /// A missing reason is `end_turn`.
    static func encode(_ reason: WireFinishReason?, sameProtocol: Bool) -> String {
        guard let reason else { return "end_turn" }
        if sameProtocol, let raw = reason.raw { return raw }
        return switch reason.unified {
        case .stop, .error, .other: "end_turn"
        case .length: "max_tokens"
        case .toolCalls: "tool_use"
        case .contentFilter: "refusal"
        }
    }
}

enum AnthropicUsage {
    /// Decodes a `usage` object. ``WireUsage/inputTokens`` becomes the whole
    /// prompt (`input_tokens` + cache reads + cache writes). Bags produce no
    /// warnings: they are counters, not content.
    static func decode(_ object: JSONObject, path: String) throws(WireDecodingError) -> WireUsage {
        var ignored: [WireWarning] = []
        var reader = FieldReader(object, path: path)
        var usage = WireUsage()
        let input = try reader.int("input_tokens")
        usage.cacheWriteTokens = try reader.int("cache_creation_input_tokens")
        usage.cachedInputTokens = try reader.int("cache_read_input_tokens")
        usage.inputTokens = input.map { $0 + (usage.cachedInputTokens ?? 0) + (usage.cacheWriteTokens ?? 0) }
        usage.outputTokens = try reader.int("output_tokens")
        if let details = try reader.object("output_tokens_details") {
            var inner = FieldReader(details, path: reader.path("output_tokens_details"))
            usage.reasoningTokens = try inner.int("thinking_tokens")
            usage.outputDetailsExtra = inner.remaining(warnings: &ignored)
        }
        usage.extra = reader.remaining(warnings: &ignored)
        return usage
    }

    /// Encodes usage. Another protocol's usage always gets `input_tokens`
    /// and `output_tokens` (0 when unknown), which Anthropic clients require.
    static func encode(_ usage: WireUsage?, include: Bool) -> JSONValue {
        let usage = usage ?? WireUsage()
        var object = JSONObject()
        if let total = usage.inputTokens {
            let uncached = total - (usage.cachedInputTokens ?? 0) - (usage.cacheWriteTokens ?? 0)
            object["input_tokens"] = .number(JSONNumber(max(uncached, 0)))
        } else if !include {
            object["input_tokens"] = 0
        }
        if let value = usage.cacheWriteTokens { object["cache_creation_input_tokens"] = .number(JSONNumber(value)) }
        if let value = usage.cachedInputTokens { object["cache_read_input_tokens"] = .number(JSONNumber(value)) }
        if let value = usage.outputTokens {
            object["output_tokens"] = .number(JSONNumber(value))
        } else if !include {
            object["output_tokens"] = 0
        }
        // `thinking_tokens` is written back only to the Anthropic source.
        if include, usage.reasoningTokens != nil || usage.outputDetailsExtra != nil {
            var details = JSONObject()
            if let value = usage.reasoningTokens { details["thinking_tokens"] = .number(JSONNumber(value)) }
            for (key, value) in usage.outputDetailsExtra ?? [:] where !details.contains(key: key) {
                details[key] = value
            }
            object["output_tokens_details"] = .object(details)
        }
        // Vendor counters from another protocol are not worth a warning each.
        var ignored: [WireWarning] = []
        appendExtra(usage.extra, to: &object, include: include, path: "usage", warnings: &ignored)
        return .object(object)
    }
}
