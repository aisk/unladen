// Chat Completions messages and content parts, shared by the request and
// response directions.

/// The reasoning fields Chat-compatible APIs use on assistant messages and
/// stream deltas: DeepSeek's `reasoning_content`, OpenRouter's `reasoning`.
let chatReasoningKeys = ["reasoning_content", "reasoning"]

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
            return .text(WireText(text, extra: reader.remaining(warnings: &warnings)))

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
        return .toolCall(WireToolCall(
            id: id ?? syntheticID, idSynthesized: id == nil, name: name, arguments: arguments,
            extra: reader.remaining(warnings: &warnings),
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
            for key in chatReasoningKeys {
                if case .string(let text)? = object[key] {
                    _ = reader.raw(key)
                    parts.append(.reasoning(WireReasoning(text: text, sourceKey: key)))
                    break
                }
            }
        }
        let content = try content(reader.raw("content"), path: reader.path("content"), warnings: &warnings)
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
        return WireMessage(role: role, parts: parts, contentForm: content.form, extra: reader.remaining(warnings: &warnings))
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
    static func content(
        _ parts: [WirePart],
        form: WireContentForm?,
        emptyDefault: JSONValue?,
        joinTexts: Bool = false,
        include: Bool,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        var items: [JSONValue] = []
        var texts: [String] = []
        var allPlain = true
        for (i, part) in parts.enumerated() {
            guard let item = self.part(part, include: include, path: WirePath.index(path, i), warnings: &warnings) else {
                continue
            }
            items.append(item)
            // Plain: nothing in the part's bag would be lost by a string.
            if case .text(let text) = part, text.extra.isEmpty || !include {
                texts.append(text.text)
            } else {
                allPlain = false
            }
        }
        if items.isEmpty {
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
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        var object = JSONObject()
        switch part {
        case .text(let text):
            object["type"] = "text"
            object["text"] = .string(text.text)
            if text.signature != nil {
                warnings.append(WireWarning(.droppedContent, "text signature cannot be carried by Chat", path: path))
            }
            appendExtra(text.extra, to: &object, include: include, path: path, warnings: &warnings)

        case .refusal(let refusal):
            object["type"] = "refusal"
            object["refusal"] = .string(refusal.text)
            appendExtra(refusal.extra, to: &object, include: include, path: path, warnings: &warnings)

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

        case .opaque(let opaque):
            guard opaque.protocol == .chatCompletions else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) content cannot be carried by Chat", path: path))
                return nil
            }
            return opaque.value

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
        include: Bool,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue {
        var function = JSONObject()
        function["name"] = .string(call.name)
        function["arguments"] = .string(call.arguments)
        var object = JSONObject()
        object["id"] = .string(call.id)
        object["type"] = "function"
        object["function"] = .object(function)
        if call.signature != nil {
            warnings.append(WireWarning(.droppedContent, "tool call signature cannot be carried by Chat", path: path))
        }
        if let itemType = call.itemType {
            warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a function call", path: path))
        }
        appendExtra(call.extra, to: &object, include: include, path: path, warnings: &warnings)
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
        path: String,
        warnings: inout [WireWarning],
    ) -> [JSONValue] {
        var output: [JSONValue] = []
        var rest: [WirePart] = []
        var reasoning: [WireReasoning] = []
        var refusals: [WireRefusal] = []
        // Function calls and opaque (non-function) calls, in order.
        var calls: [JSONValue] = []
        var results: [WireToolResult] = []
        let isAssistant = message.role == .assistant
        let callsPath = WirePath.key(path, "tool_calls")

        for part in message.parts {
            switch part {
            case .toolResult(let result):
                results.append(result)
            case .reasoning(let value) where isAssistant:
                reasoning.append(value)
            case .toolCall(let call) where isAssistant:
                calls.append(toolCall(call, include: include, path: WirePath.index(callsPath, calls.count), warnings: &warnings))
            case .refusal(let refusal) where isAssistant && !(include && refusal.sourceKey == nil):
                // Same protocol: back where it came from (a content part has
                // no sourceKey). Otherwise the message field, valid everywhere.
                refusals.append(refusal)
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
            let content = content(
                result.content, form: result.contentForm, emptyDefault: "",
                include: include, path: WirePath.key(path, "content"), warnings: &warnings,
            )
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
            include: include, path: WirePath.key(path, "content"), warnings: &warnings,
        ) {
            object["content"] = content
        }
        if !reasoning.isEmpty {
            let sourceKey = include ? reasoning.first?.sourceKey : nil
            let key = sourceKey.flatMap { chatReasoningKeys.contains($0) ? $0 : nil } ?? "reasoning_content"
            let keyPath = WirePath.key(path, key)
            object[key] = .string(reasoning.map(\.text).joined())
            if reasoning.count > 1 {
                warnings.append(WireWarning(.lossyConversion, "reasoning blocks joined into one string", path: keyPath))
            }
            if reasoning.contains(where: \.hasSignedData) {
                warnings.append(WireWarning(.droppedContent, "reasoning signature/encrypted data cannot be carried by Chat", path: keyPath))
            }
            for item in reasoning {
                // Chat reasoning is a plain string: an object's bag has no place.
                var unused = JSONObject()
                appendExtra(item.extra, to: &unused, include: false, path: keyPath, warnings: &warnings)
            }
        }
        if !refusals.isEmpty {
            object["refusal"] = .string(refusals.map(\.text).joined())
        }
        if !calls.isEmpty {
            object["tool_calls"] = .array(calls)
        }
        appendExtra(message.extra, to: &object, include: include, path: path, warnings: &warnings)
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
