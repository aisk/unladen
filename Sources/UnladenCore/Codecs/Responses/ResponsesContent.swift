// OpenAI Responses items and content parts, shared by the request and
// response directions, plus finish reasons and usage.

// MARK: - Decoding

enum ResponsesDecode {
    /// Item types Responses defines that the codec keeps opaque on purpose;
    /// they produce no warning when decoded.
    static let knownOpaqueItems: Set<String> = [
        "item_reference", "web_search_call", "file_search_call", "computer_call", "computer_call_output",
        "image_generation_call", "code_interpreter_call", "local_shell_call", "local_shell_call_output",
        "shell_call", "shell_call_output", "apply_patch_call", "apply_patch_call_output", "mcp_list_tools",
        "mcp_approval_request", "mcp_approval_response", "mcp_call", "compaction",
    ]

    /// Consumes `annotations: []` and `logprobs: []`: defaults that replies
    /// always carry, and the encoder writes back (replies) or leaves out
    /// (requests). Non-empty values stay for the bag.
    static func consumeEmptyDefaults(_ reader: inout FieldReader) {
        for key in ["annotations", "logprobs"] where reader.object[key] == .array([]) {
            _ = reader.raw(key)
        }
    }

    /// Decodes a message `content`: a string, or an array of parts.
    static func content(
        _ raw: JSONValue?,
        path: String,
        itemID: String?,
        origin: WireSystemID?,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> (parts: [WirePart], form: WireContentForm) {
        guard let raw else { return ([], .absent) }
        switch raw {
        case .null:
            return ([], .null)
        case .string(let text):
            return (text.isEmpty ? [] : [.text(WireText(text, itemID: itemID, origin: origin))], .string)
        case .array(let items):
            var parts: [WirePart] = []
            parts.reserveCapacity(items.count)
            for (i, item) in items.enumerated() {
                parts.append(try part(item, path: WirePath.index(path, i), itemID: itemID, origin: origin, warnings: &warnings))
            }
            return (parts, .parts)
        default:
            throw WireDecodingError(.typeMismatch(expected: "a string or an array"), path: path)
        }
    }

    /// Decodes one content part (`input_text`, `output_text`, `refusal`,
    /// `input_image`, `input_file`). Others, and malformed parts, become
    /// opaque parts.
    static func part(
        _ value: JSONValue,
        path: String,
        itemID: String?,
        origin: WireSystemID?,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WirePart {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        func opaque(_ why: String) -> WirePart {
            warnings.append(WireWarning(.opaqueContent, why, path: path))
            return .opaque(WireOpaque(protocol: .responses, value: value))
        }
        guard case .string(let type)? = object["type"] else {
            return opaque("content part without a `type` kept as opaque")
        }
        var reader = FieldReader(object, path: path)
        _ = reader.raw("type")
        switch type {
        case "input_text", "output_text":
            guard case .string(let text)? = object["text"] else { return opaque("malformed \(type) part kept as opaque") }
            _ = reader.raw("text")
            consumeEmptyDefaults(&reader)
            let extra = reader.remaining(quiet: ["annotations", "logprobs"], warnings: &warnings)
            return .text(WireText(text, itemID: itemID, origin: itemID == nil ? nil : origin, extra: extra))

        case "refusal":
            guard case .string(let text)? = object["refusal"] else { return opaque("malformed refusal part kept as opaque") }
            _ = reader.raw("refusal")
            let extra = reader.remaining(warnings: &warnings)
            return .refusal(WireRefusal(text, itemID: itemID, origin: itemID == nil ? nil : origin, extra: extra))

        case "input_image":
            let url = object["image_url"]?.stringValue
            let fileID = object["file_id"]?.stringValue
            guard (url == nil) != (fileID == nil) else { return opaque("input_image without one source kept as opaque") }
            _ = reader.raw(url == nil ? "file_id" : "image_url")
            var media = WireMedia(source: url.map { .url($0) } ?? .fileID(fileID ?? ""))
            media.detail = try reader.string("detail")
            media.extra = reader.remaining(warnings: &warnings)
            return .image(media)

        case "input_file":
            let sources = ["file_id", "file_data", "file_url"].filter { object[$0]?.stringValue != nil }
            guard sources.count == 1, let key = sources.first, case .string(let text)? = reader.raw(key) else {
                return opaque("input_file without one source kept as opaque")
            }
            var media: WireMedia
            switch key {
            case "file_id":
                media = WireMedia(source: .fileID(text))
            case "file_url":
                media = WireMedia(source: .url(text))
            default:
                if let data = DataURL.parse(text) {
                    media = WireMedia(source: .base64(data.data), mediaType: data.mediaType)
                } else {
                    media = WireMedia(source: .base64(text))
                }
            }
            media.filename = try reader.string("filename")
            media.extra = reader.remaining(warnings: &warnings)
            return .file(media)

        default:
            return opaque("content part of type `\(type)` kept as opaque")
        }
    }

    /// Where an item is decoded: client requests keep everything they can
    /// (statuses in bags) and recognize sealed reasoning; replies stamp
    /// `origin` and drop statuses, which the encoder derives.
    struct Context {
        var origin: WireSystemID?
        var isRequest: Bool
    }

    /// Decodes a `reasoning` item, or `nil` if it is malformed (the caller
    /// keeps it opaque). See ``WireReasoning`` for the layout.
    static func reasoning(
        _ object: JSONObject,
        path: String,
        context: Context,
        warnings: inout [WireWarning],
    ) -> [WireReasoning]? {
        var reader = FieldReader(object, path: path)
        _ = reader.raw("type")
        func texts(_ key: String, type: String) -> [String]? {
            guard case .array(let entries)? = object[key] else { return [] }
            var texts: [String] = []
            for entry in entries {
                guard case .object(let part) = entry, part.count == 2, part["type"]?.stringValue == type,
                      case .string(let text)? = part["text"] else { return nil }
                texts.append(text)
            }
            return texts
        }
        guard let summary = texts("summary", type: "summary_text"), let content = texts("content", type: "reasoning_text") else {
            return nil
        }
        if object["summary"]?.arrayValue != nil { _ = reader.raw("summary") }
        // An empty `content` array stays in the bag, so it is written back.
        if !content.isEmpty { _ = reader.raw("content") }
        var itemID = object["id"]?.stringValue
        if itemID != nil { _ = reader.raw("id") }
        if context.isRequest { itemID = ResponsesItemID.upstream(itemID) }
        var origin = context.origin
        var signature: String?
        var encrypted: String?
        if case .string(let value)? = object["encrypted_content"] {
            _ = reader.raw("encrypted_content")
            if context.isRequest {
                switch ResponsesSeal.open(value) {
                case .notSealed:
                    encrypted = value
                    origin = ResponsesReplay.system
                case .sealed(let contents):
                    origin = contents.origin
                    signature = contents.signature
                    encrypted = contents.encrypted
                    itemID = nil
                case .unreadable:
                    warnings.append(WireWarning(.droppedContent, "unreadable sealed reasoning dropped", path: reader.path("encrypted_content")))
                }
            } else {
                encrypted = value
            }
        }
        let extra = reader.remaining(quiet: ["status", "content", "encrypted_content"], warnings: &warnings)

        var parts: [WireReasoning] = []
        for (i, text) in summary.enumerated() {
            parts.append(WireReasoning(text: text, itemID: itemID, summaryIndex: i, origin: origin))
        }
        for (i, text) in content.enumerated() {
            parts.append(WireReasoning(text: text, itemID: itemID, summaryIndex: i, origin: origin, sourceKey: "content"))
        }
        if parts.isEmpty {
            parts.append(WireReasoning(text: "", itemID: itemID, origin: origin))
        }
        parts[parts.count - 1].signature = signature
        parts[parts.count - 1].encrypted = encrypted
        parts[parts.count - 1].extra = extra
        return parts
    }

    /// The contents of a reasoning item that only carries a sealed function
    /// call signature (``ResponsesSeal/callTarget``), or `nil`.
    static func sealedCallSignature(_ value: JSONValue) -> ResponsesSeal.Contents? {
        guard case .object(let object) = value, object["type"] == "reasoning",
              case .string(let encrypted)? = object["encrypted_content"],
              case .sealed(let contents) = ResponsesSeal.open(encrypted), contents.target == ResponsesSeal.callTarget,
              contents.signature != nil
        else { return nil }
        return contents
    }

    /// Decodes a `function_call` or `custom_tool_call` item, or `nil` if it
    /// is malformed.
    static func toolCall(
        _ object: JSONObject,
        path: String,
        context: Context,
        warnings: inout [WireWarning],
    ) -> WireToolCall? {
        let custom = object["type"] == "custom_tool_call"
        let argumentsKey = custom ? "input" : "arguments"
        guard case .string(let callID)? = object["call_id"], case .string(let name)? = object["name"],
              case .string(let arguments)? = object[argumentsKey] else { return nil }
        var reader = FieldReader(object, path: path)
        for key in ["type", "call_id", "name", argumentsKey] { _ = reader.raw(key) }
        var itemID = object["id"]?.stringValue
        if itemID != nil { _ = reader.raw("id") }
        if context.isRequest { itemID = ResponsesItemID.upstream(itemID) }
        if !context.isRequest, object["status"]?.stringValue != nil { _ = reader.raw("status") }
        return WireToolCall(
            id: callID, name: name, arguments: arguments, itemType: custom ? "custom_tool_call" : nil,
            itemID: itemID, origin: itemID == nil ? nil : context.origin,
            extra: reader.remaining(quiet: ["status"], warnings: &warnings),
        )
    }

    /// Decodes a `function_call_output` or `custom_tool_call_output` item,
    /// or `nil` if it is malformed.
    static func toolResult(
        _ object: JSONObject,
        path: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WireToolResult? {
        let type = object["type"]?.stringValue
        guard case .string(let callID)? = object["call_id"] else { return nil }
        switch object["output"] {
        case .string?, .array?: break
        default: return nil
        }
        var reader = FieldReader(object, path: path)
        _ = reader.raw("type")
        _ = reader.raw("call_id")
        let output = try content(reader.raw("output"), path: reader.path("output"), itemID: nil, origin: nil, warnings: &warnings)
        let itemID = ResponsesItemID.upstream(try reader.string("id"))
        return WireToolResult(
            callID: callID, content: output.parts, contentForm: output.form,
            itemType: type == "custom_tool_call_output" ? type : nil, itemID: itemID,
            extra: reader.remaining(quiet: ["status"], warnings: &warnings),
        )
    }

    /// Decodes one `input` item of a client request as one wire message:
    /// message items keep their role; reasoning and calls are assistant
    /// messages; call outputs and every other item are role-less
    /// ``WireRole/item`` messages (other items as one opaque part with slot
    /// `"item"`).
    static func inputItem(_ value: JSONValue, path: String, warnings: inout [WireWarning]) throws(WireDecodingError) -> WireMessage {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        let context = Context(origin: nil, isRequest: true)
        func opaque(_ why: String?) -> WireMessage {
            if let why { warnings.append(WireWarning(.opaqueContent, why, path: path)) }
            return WireMessage(role: .item, parts: [.opaque(WireOpaque(protocol: .responses, value: value, slot: "item"))])
        }
        let type = object["type"]?.stringValue
        switch type {
        case "message":
            return try message(object, path: path, warnings: &warnings)
        case nil:
            guard object["role"] != nil else { return opaque("input item without `type` or `role` kept as opaque") }
            return try message(object, path: path, warnings: &warnings)
        case "reasoning":
            guard let parts = reasoning(object, path: path, context: context, warnings: &warnings) else {
                return opaque("malformed reasoning item kept as opaque")
            }
            return WireMessage(role: .assistant, parts: parts.map { .reasoning($0) })
        case "function_call", "custom_tool_call":
            guard let call = toolCall(object, path: path, context: context, warnings: &warnings) else {
                return opaque("malformed \(type ?? "") item kept as opaque")
            }
            return WireMessage(role: .assistant, parts: [.toolCall(call)])
        case "function_call_output", "custom_tool_call_output":
            guard let result = try toolResult(object, path: path, warnings: &warnings) else {
                return opaque("malformed \(type ?? "") item kept as opaque")
            }
            return WireMessage(role: .item, parts: [.toolResult(result)])
        case let type?:
            return opaque(knownOpaqueItems.contains(type) ? nil : "input item of type `\(type)` kept as opaque")
        }
    }

    /// A request message item. Its `id` goes to the text and refusal parts'
    /// ``WireText/itemID`` (the bag keeps it when there are none); `type` is
    /// always written back, so it is not kept.
    private static func message(_ object: JSONObject, path: String, warnings: inout [WireWarning]) throws(WireDecodingError) -> WireMessage {
        var reader = FieldReader(object, path: path)
        _ = reader.raw("type")
        let role = WireRole(rawValue: try reader.requiredString("role"))
        let rawID = object["id"]?.stringValue
        let id = ResponsesItemID.upstream(rawID)
        let content = try content(reader.raw("content"), path: reader.path("content"), itemID: id, origin: nil, warnings: &warnings)
        let hasTextParts = content.parts.contains { part in
            switch part {
            case .text, .refusal: true
            default: false
            }
        }
        // A gateway-minted id is dropped, not kept in the bag.
        if rawID != nil, hasTextParts || id == nil { _ = reader.raw("id") }
        return WireMessage(
            role: role, parts: content.parts, contentForm: content.form,
            extra: reader.remaining(quiet: ["status", "id"], warnings: &warnings),
        )
    }

    /// Decodes one `output` item of a reply into assistant parts.
    static func outputItem(
        _ value: JSONValue,
        path: String,
        origin: WireSystemID?,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> [WirePart] {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        let context = Context(origin: origin, isRequest: false)
        func opaque(_ why: String?) -> [WirePart] {
            if let why { warnings.append(WireWarning(.opaqueContent, why, path: path)) }
            return [.opaque(WireOpaque(protocol: .responses, value: value, slot: "item"))]
        }
        let type = object["type"]?.stringValue ?? ""
        switch type {
        case "message":
            guard case .array? = object["content"] else { return opaque("message item without content kept as opaque") }
            var reader = FieldReader(object, path: path)
            for key in ["type", "role", "status"] { _ = reader.raw(key) }
            let id = try reader.string("id")
            let content = try content(reader.raw("content"), path: reader.path("content"), itemID: id, origin: origin, warnings: &warnings)
            reader.dropRemaining(warnings: &warnings)
            return content.parts
        case "reasoning":
            guard let parts = reasoning(object, path: path, context: context, warnings: &warnings) else {
                return opaque("malformed reasoning item kept as opaque")
            }
            return parts.map { .reasoning($0) }
        case "function_call", "custom_tool_call":
            guard let call = toolCall(object, path: path, context: context, warnings: &warnings) else {
                return opaque("malformed \(type) item kept as opaque")
            }
            return [.toolCall(call)]
        default:
            return opaque(knownOpaqueItems.contains(type) ? nil : "output item of type `\(type)` kept as opaque")
        }
    }

    /// Unknown in-stream `error` payloads and `response.error` objects.
    static func streamError(_ value: JSONValue?) -> WireStreamError {
        WireStreamError(json: value)
    }
}

// MARK: - Encoding

enum ResponsesEncode {
    /// Why a cache breakpoint is dropped.
    static let noCache = "Responses has no per-block breakpoint (prompt caching is automatic)"

    /// Settings that every item encoder needs.
    struct Context {
        /// The target is the source protocol: bags and opaque parts go back.
        var include: Bool
        /// Systems whose reasoning data and item ids the peer accepts.
        var trusted: Set<WireSystemID>

        func acceptsID(_ id: String?, origin: WireSystemID?) -> String? {
            guard let id, ResponsesReplay.acceptsID(origin: origin, sameProtocol: include, trusted: trusted) else { return nil }
            return id
        }
    }

    /// Encodes one content part of a request message, or `nil` (with a
    /// warning) if it cannot appear there. Assistant text is `output_text`,
    /// other roles' `input_text`.
    static func part(
        _ part: WirePart,
        assistant: Bool,
        context: Context,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        let include = context.include
        var object = JSONObject()
        defer { dropCacheControl(part.cacheControl, path: path, reason: ResponsesEncode.noCache, warnings: &warnings) }
        switch part {
        case .text(let text):
            object["type"] = assistant ? "output_text" : "input_text"
            object["text"] = .string(text.text)
            if text.signature != nil {
                warnings.append(WireWarning(.droppedContent, "text signature cannot be carried by Responses", path: path))
            }
            appendExtra(text.extra, to: &object, include: include, path: path, warnings: &warnings)
            applyPatch(text.patch, to: &object, target: .responses)

        case .refusal(let refusal):
            if assistant {
                object["type"] = "refusal"
                object["refusal"] = .string(refusal.text)
            } else {
                warnings.append(WireWarning(.lossyConversion, "refusal outside an assistant message sent as text", path: path))
                object["type"] = "input_text"
                object["text"] = .string(refusal.text)
            }
            appendExtra(refusal.extra, to: &object, include: include, path: path, warnings: &warnings)
            applyPatch(refusal.patch, to: &object, target: .responses)

        case .image(let media):
            guard !assistant else {
                warnings.append(WireWarning(.droppedContent, "images cannot appear in an assistant message", path: path))
                return nil
            }
            object["type"] = "input_image"
            switch media.source {
            case .url(let url): object["image_url"] = .string(url)
            case .base64(let data): object["image_url"] = .string(DataURL.make(mediaType: media.mediaType ?? "image/png", data: data))
            case .fileID(let id): object["file_id"] = .string(id)
            }
            if let detail = media.detail { object["detail"] = .string(detail) }
            if media.filename != nil {
                warnings.append(WireWarning(.droppedField, "Responses images have no file name", path: WirePath.key(path, "filename")))
            }
            appendExtra(media.extra, to: &object, include: include, path: path, warnings: &warnings)
            applyPatch(media.patch, to: &object, target: .responses)

        case .file(let media):
            guard !assistant else {
                warnings.append(WireWarning(.droppedContent, "files cannot appear in an assistant message", path: path))
                return nil
            }
            object["type"] = "input_file"
            switch media.source {
            case .fileID(let id): object["file_id"] = .string(id)
            case .url(let url):
                if DataURL.parse(url) != nil {
                    object["file_data"] = .string(url)
                } else {
                    object["file_url"] = .string(url)
                }
            case .base64(let data):
                object["file_data"] = .string(media.mediaType.map { DataURL.make(mediaType: $0, data: data) } ?? data)
            }
            if let filename = media.filename { object["filename"] = .string(filename) }
            if media.detail != nil {
                warnings.append(WireWarning(.droppedField, "Responses files have no detail setting", path: WirePath.key(path, "detail")))
            }
            appendExtra(media.extra, to: &object, include: include, path: path, warnings: &warnings)
            applyPatch(media.patch, to: &object, target: .responses)

        case .opaque(let opaque):
            guard opaque.protocol == .responses, opaque.slot == nil else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) content cannot be carried by Responses", path: path))
                return nil
            }
            return opaque.value

        case .reasoning, .toolCall, .toolResult:
            warnings.append(WireWarning(.droppedContent, "part cannot appear in Responses message content", path: path))
            return nil
        }
        return .object(object)
    }

    /// A message `content` value: a bare string for one plain text part
    /// unless the recorded form says otherwise, else an array.
    static func content(
        _ parts: [WirePart],
        form: WireContentForm?,
        assistant: Bool,
        context: Context,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue {
        var items: [JSONValue] = []
        var plain: [String] = []
        for (i, part) in parts.enumerated() {
            guard let item = self.part(part, assistant: assistant, context: context, path: WirePath.index(path, i), warnings: &warnings) else {
                continue
            }
            items.append(item)
            if case .text(let text) = part, text.extra.isEmpty || !context.include, !hasPatch(text.patch, for: .responses) {
                plain.append(text.text)
            }
        }
        if items.isEmpty {
            // Another protocol's empty array becomes the always-valid "".
            return form == .parts && context.include ? .array([]) : ""
        }
        if form != .parts, items.count == 1, plain.count == 1 {
            return .string(plain[0])
        }
        return .array(items)
    }

    /// Encodes reasoning parts that share an item for a request, or `nil`
    /// (with a warning) if the upstream would not accept them: reasoning
    /// from an untrusted system, or with neither an item id nor encrypted
    /// content to replay.
    static func reasoningItem(
        _ parts: [WireReasoning],
        context: Context,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        guard let first = parts.first else { return nil }
        let accepted = parts.allSatisfy { ResponsesReplay.accepts($0, sameProtocol: context.include, trusted: context.trusted) }
        let encrypted = parts.last { $0.encrypted != nil }?.encrypted
        guard accepted, first.itemID != nil || encrypted != nil else {
            let from = first.origin ?? "another protocol"
            warnings.append(WireWarning(.droppedContent, "reasoning from \(from) cannot be replayed to Responses", path: path))
            return nil
        }
        var object = JSONObject()
        object["type"] = "reasoning"
        if let id = first.itemID { object["id"] = .string(id) }
        object["summary"] = .array(parts.filter { $0.sourceKey != "content" && !($0.summaryIndex == nil && $0.text.isEmpty) }.map {
            ["type": "summary_text", "text": .string($0.text)]
        })
        let content = parts.filter { $0.sourceKey == "content" }
        if !content.isEmpty {
            object["content"] = .array(content.map { ["type": "reasoning_text", "text": .string($0.text)] })
        }
        if let encrypted { object["encrypted_content"] = .string(encrypted) }
        if parts.contains(where: { $0.signature != nil }) {
            warnings.append(WireWarning(.droppedContent, "reasoning signature cannot be carried by Responses", path: path))
        }
        for part in parts {
            appendExtra(part.extra, to: &object, include: context.include, path: path, warnings: &warnings)
        }
        for part in parts { applyPatch(part.patch, to: &object, target: .responses) }
        return .object(object)
    }

    static func toolCallItem(_ call: WireToolCall, context: Context, path: String, warnings: inout [WireWarning]) -> JSONValue {
        let custom = call.itemType == "custom_tool_call"
        var object = JSONObject()
        object["type"] = custom ? "custom_tool_call" : "function_call"
        if let id = context.acceptsID(call.itemID, origin: call.origin) { object["id"] = .string(id) }
        object["call_id"] = .string(call.id)
        object["name"] = .string(call.name)
        // A custom tool's input is free text; a function's arguments are a
        // JSON object, `{}` when there are none.
        let empty = !custom && call.arguments.trimmingASCIIWhitespace().isEmpty
        object[custom ? "input" : "arguments"] = .string(empty ? "{}" : call.arguments)
        if call.signature != nil {
            warnings.append(WireWarning(.droppedContent, "tool call signature cannot be carried by Responses", path: path))
        }
        if let itemType = call.itemType, !custom {
            warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a function_call item", path: path))
        }
        appendExtra(call.extra, to: &object, include: context.include, path: path, warnings: &warnings)
        dropCacheControl(call.cacheControl, path: path, reason: noCache, warnings: &warnings)
        applyPatch(call.patch, to: &object, target: .responses)
        return .object(object)
    }

    static func toolResultItem(_ result: WireToolResult, context: Context, path: String, warnings: inout [WireWarning]) -> JSONValue {
        let custom = result.itemType == "custom_tool_call_output"
        var object = JSONObject()
        object["type"] = custom ? "custom_tool_call_output" : "function_call_output"
        if let id = context.acceptsID(result.itemID, origin: result.origin) { object["id"] = .string(id) }
        object["call_id"] = .string(result.callID)
        var output = content(
            result.content, form: result.contentForm, assistant: false, context: context,
            path: WirePath.key(path, "output"), warnings: &warnings,
        )
        // Another protocol's text-only blocks (Anthropic's block-form
        // tool_result): Responses clients and upstreams expect a string.
        let texts = result.content.compactMap { part -> String? in if case .text(let text) = part { text.text } else { nil } }
        if !context.include, case .array(let items) = output, !items.isEmpty, texts.count == result.content.count {
            if texts.count > 1 {
                warnings.append(WireWarning(.lossyConversion, "text parts joined into one string", path: WirePath.key(path, "output")))
            }
            output = .string(texts.joined(separator: "\n"))
        }
        object["output"] = output
        if result.isError == true {
            warnings.append(WireWarning(.lossyConversion, "Responses tool outputs cannot mark an error", path: path))
        }
        if let itemType = result.itemType, !custom {
            warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a function_call_output item", path: path))
        }
        appendExtra(result.extra, to: &object, include: context.include, path: path, warnings: &warnings)
        dropCacheControl(result.cacheControl, path: path, reason: noCache, warnings: &warnings)
        applyPatch(result.patch, to: &object, target: .responses)
        return .object(object)
    }

    /// Encodes one wire message as request `input` items, in part order:
    /// consecutive content parts with the same (accepted) item id form one
    /// message item; consecutive reasoning parts with the same item id one
    /// reasoning item; each tool call, tool result and opaque item its own
    /// item. The message's form and bag go to its first message item.
    /// Whether `part` begins a reasoning item of its own rather than
    /// continuing `last`'s: another item id; or, without ids (a sealed
    /// item's is cleared), `last` closed its item with the item's data, or
    /// the summary (or content) numbering starts again.
    static func startsAnotherItem(_ part: WireReasoning, after last: WireReasoning) -> Bool {
        if last.itemID != nil || part.itemID != nil { return last.itemID != part.itemID }
        if last.encrypted != nil || last.signature != nil { return true }
        guard let index = part.summaryIndex, let previous = last.summaryIndex, part.sourceKey == last.sourceKey else {
            return part.sourceKey == last.sourceKey || part.sourceKey == nil
        }
        return index <= previous
    }

    static func items(_ message: WireMessage, context: Context, path: String, warnings: inout [WireWarning]) -> [JSONValue] {
        let role = message.role
        let isMessageRole = [WireRole.user, .assistant, .system, .developer].contains(role)
        let contentPath = WirePath.key(path, "content")
        var output: [JSONValue] = []
        var pendingContent: [WirePart] = []
        var pendingID: String?
        var pendingReasoning: [WireReasoning] = []
        var wroteMessage = false
        var extraPlaced = false

        func flushContent() {
            guard !pendingContent.isEmpty else { return }
            output.append(messageItem(pendingContent, id: pendingID, first: !wroteMessage))
            wroteMessage = true
            pendingContent = []
            pendingID = nil
        }
        func flushReasoning() {
            guard !pendingReasoning.isEmpty else { return }
            if let item = reasoningItem(pendingReasoning, context: context, path: contentPath, warnings: &warnings) {
                output.append(item)
            }
            pendingReasoning = []
        }
        func messageItem(_ parts: [WirePart], id: String?, first: Bool) -> JSONValue {
            var object = JSONObject()
            object["type"] = "message"
            if let id { object["id"] = .string(id) }
            object["role"] = .string(role.rawValue)
            object["content"] = content(
                parts, form: first ? message.contentForm : nil, assistant: role == .assistant,
                context: context, path: contentPath, warnings: &warnings,
            )
            if first {
                appendExtra(message.extra, to: &object, include: context.include, path: path, warnings: &warnings)
                extraPlaced = true
            }
            return .object(object)
        }

        for (i, part) in message.parts.enumerated() {
            let partPath = WirePath.index(contentPath, i)
            switch part {
            case .reasoning(let reasoning):
                flushContent()
                if let last = pendingReasoning.last, Self.startsAnotherItem(reasoning, after: last) {
                    flushReasoning()
                }
                pendingReasoning.append(reasoning)
            case .toolCall(let call):
                flushContent()
                flushReasoning()
                output.append(toolCallItem(call, context: context, path: partPath, warnings: &warnings))
            case .toolResult(let result):
                flushContent()
                flushReasoning()
                output.append(toolResultItem(result, context: context, path: partPath, warnings: &warnings))
            case .opaque(let opaque) where opaque.slot == "item":
                flushContent()
                flushReasoning()
                if opaque.protocol == .responses {
                    output.append(opaque.value)
                } else {
                    warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) item cannot be carried by Responses", path: partPath))
                }
            default:
                flushReasoning()
                guard isMessageRole else {
                    warnings.append(WireWarning(.droppedContent, "content of a `\(role)` message cannot be carried", path: partPath))
                    continue
                }
                let id: String? = switch part {
                case .text(let text): context.acceptsID(text.itemID, origin: text.origin)
                case .refusal(let refusal): context.acceptsID(refusal.itemID, origin: refusal.origin)
                default: nil
                }
                if let id, let current = pendingID, current != id { flushContent() }
                if let id { pendingID = id }
                pendingContent.append(part)
            }
        }
        flushContent()
        flushReasoning()
        // An empty message (`"content": ""`) is still a message.
        if output.isEmpty, isMessageRole, message.contentForm == .string || message.contentForm == .parts {
            output.append(messageItem([], id: nil, first: true))
        }
        if !extraPlaced {
            discardExtra(message.extra, path: path, warnings: &warnings)
        }
        if hasPatch(message.patch, for: .responses) {
            if output.isEmpty { dropPatch(message.patch, target: .responses, path: path, warnings: &warnings) }
            output = output.map { item in
                guard case .object(var object) = item else { return item }
                applyPatch(message.patch, to: &object, target: .responses)
                return .object(object)
            }
        }
        return output
    }
}

// MARK: - Finish reasons and usage

enum ResponsesFinish {
    /// The finish reason of a reply with `status` (and, when incomplete,
    /// `incomplete_details.reason`). The raw value is the incomplete reason,
    /// or the status otherwise.
    static func decode(status: String, incompleteReason: String?, hasToolCalls: Bool) -> WireFinishReason {
        switch status {
        case "completed":
            return WireFinishReason(hasToolCalls ? .toolCalls : .stop, raw: status)
        case "incomplete":
            switch incompleteReason {
            case "max_output_tokens"?: return WireFinishReason(.length, raw: "max_output_tokens")
            case "content_filter"?: return WireFinishReason(.contentFilter, raw: "content_filter")
            case let reason?: return WireFinishReason(.other, raw: reason)
            case nil: return WireFinishReason(.other, raw: status)
            }
        case "failed":
            return WireFinishReason(.error, raw: status)
        default: // cancelled, in_progress, queued
            return WireFinishReason(.other, raw: status)
        }
    }

    static let statuses: Set<String> = ["completed", "incomplete", "failed", "cancelled", "in_progress", "queued"]

    /// The `status` and `incomplete_details.reason` for a finish reason.
    static func encode(_ reason: WireFinishReason?, sameProtocol: Bool) -> (status: String, incompleteReason: String?) {
        guard let reason else { return ("completed", nil) }
        if sameProtocol, let raw = reason.raw {
            if statuses.contains(raw) { return (raw, nil) }
            return ("incomplete", raw)
        }
        return switch reason.unified {
        case .stop, .toolCalls, .other: ("completed", nil)
        case .length: ("incomplete", "max_output_tokens")
        case .contentFilter: ("incomplete", "content_filter")
        case .error: ("failed", nil)
        }
    }
}

enum ResponsesUsage {
    /// Decodes a `usage` object. Bags produce no warnings: they are
    /// counters, not content.
    static func decode(_ object: JSONObject, path: String) throws(WireDecodingError) -> WireUsage {
        var ignored: [WireWarning] = []
        var reader = FieldReader(object, path: path)
        var usage = WireUsage()
        usage.inputTokens = try reader.int("input_tokens")
        if let details = try reader.object("input_tokens_details") {
            var inner = FieldReader(details, path: reader.path("input_tokens_details"))
            usage.cachedInputTokens = try inner.int("cached_tokens")
            usage.inputDetailsExtra = inner.remaining(warnings: &ignored)
        }
        usage.outputTokens = try reader.int("output_tokens")
        if let details = try reader.object("output_tokens_details") {
            var inner = FieldReader(details, path: reader.path("output_tokens_details"))
            usage.reasoningTokens = try inner.int("reasoning_tokens")
            usage.outputDetailsExtra = inner.remaining(warnings: &ignored)
        }
        usage.totalTokens = try reader.int("total_tokens")
        usage.extra = reader.remaining(warnings: &ignored)
        return usage
    }

    /// Encodes usage. Another protocol's usage gets every field Responses
    /// clients read (0 when unknown; the total is computed).
    static func encode(_ usage: WireUsage, include: Bool) -> JSONValue {
        var object = JSONObject()
        func number(_ value: Int?) -> JSONValue { .number(JSONNumber(value ?? 0)) }
        if usage.inputTokens != nil || !include { object["input_tokens"] = number(usage.inputTokens) }
        if usage.cachedInputTokens != nil || usage.inputDetailsExtra != nil || !include {
            var details = JSONObject()
            if usage.cachedInputTokens != nil || !include { details["cached_tokens"] = number(usage.cachedInputTokens) }
            if include {
                for (key, value) in usage.inputDetailsExtra ?? [:] where !details.contains(key: key) { details[key] = value }
            }
            object["input_tokens_details"] = .object(details)
        }
        if usage.outputTokens != nil || !include { object["output_tokens"] = number(usage.outputTokens) }
        if usage.reasoningTokens != nil || usage.outputDetailsExtra != nil || !include {
            var details = JSONObject()
            if usage.reasoningTokens != nil || !include { details["reasoning_tokens"] = number(usage.reasoningTokens) }
            if include {
                for (key, value) in usage.outputDetailsExtra ?? [:] where !details.contains(key: key) { details[key] = value }
            }
            object["output_tokens_details"] = .object(details)
        }
        if let total = usage.totalTokens {
            object["total_tokens"] = .number(JSONNumber(total))
        } else if !include {
            object["total_tokens"] = number((usage.inputTokens ?? 0) + (usage.outputTokens ?? 0))
        }
        var ignored: [WireWarning] = []
        appendExtra(usage.extra, to: &object, include: include, path: "usage", warnings: &ignored)
        return .object(object)
    }
}
