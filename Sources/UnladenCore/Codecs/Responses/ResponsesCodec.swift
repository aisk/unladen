/// OpenAI Responses codec (`/v1/responses`).
///
/// Directions:
/// - ``parseRequest(_:)`` client JSON → ``WireRequest`` (gateway only, `package`)
/// - ``buildRequest(_:options:)`` ``WireRequest`` → upstream JSON
/// - ``parseResponse(_:origin:)`` upstream JSON → ``WireResponse``;
///   streaming: ``ResponsesStreamDecoder``
/// - ``encodeResponse(_:defaults:)`` ``WireResponse`` → client JSON (gateway
///   only); streaming: ``ResponsesStreamEncoder``
///
/// Mapping notes:
/// - `input`: a string is one user message (spelling recorded in
///   ``WireRequest/spellings``); each list item is one wire message (see
///   ``ResponsesDecode/inputItem(_:path:warnings:)``): message items keep
///   their role, `reasoning`/`function_call`/`custom_tool_call` items are
///   assistant messages, call outputs and every other item (`item_reference`,
///   `web_search_call`, `mcp_*`, …) role-less ``WireRole/item`` messages, the
///   latter as one opaque part with slot `"item"`. Message items always get
///   `type: "message"` back; `status` keys stay in bags.
/// - Item ids go to ``WireText/itemID``, ``WireReasoning/itemID``,
///   ``WireToolCall/itemID`` and ``WireToolResult/itemID``; call ids to
///   ``WireToolCall/id``. `custom_tool_call(_output)` sets `itemType`.
/// - Reasoning items: see ``WireReasoning`` for the layout. A client's
///   `encrypted_content` is either an Unladen envelope (``ResponsesSeal``),
///   restored to the original origin and signature, or OpenAI's own
///   (origin `"openai"`). What may be replayed is decided by
///   ``ResponsesReplay``.
/// - `instructions` ↔ ``WireRequest/instructions``; `reasoning.effort`/
///   `summary` ↔ ``WireReasoningConfig``; `text.format` ↔
///   ``WireRequest/responseFormat`` (flat, unlike Chat's `json_schema`
///   wrapper) and `text.verbosity` ↔ ``WireRequest/verbosity`` (a `text`
///   object with other keys stays in the bag whole).
/// - `previous_response_id`, `include`, `truncation`, `metadata`,
///   `background`, `conversation`, `prompt`, `max_tool_calls`,
///   `top_logprobs`, `stream_options` stay in the top-level bag without a
///   warning: the same protocol writes them back; another protocol drops
///   them with a warning (a conversation continued by id cannot be
///   translated).
/// - Empty `annotations`/`logprobs` arrays on text parts are defaults:
///   dropped on decode, written by reply encoders, not by the request
///   builder.
///
/// Encoders write keys in a fixed order: `model`, `input`, then the
/// remaining known fields in alphabetical order, then unknown fields in
/// their decode order (responses: `id`, `object`, `created_at`, `status`,
/// `error`, `incomplete_details`, `model`, `output`, `usage`).
@_spi(Wire) public enum ResponsesCodec {}

/// Settings for building a Responses request that the wire model does not
/// (and should not) carry. Profiles supply them per endpoint and model.
@_spi(Wire) public struct ResponsesRequestOptions: Hashable, Sendable {
    /// Systems whose reasoning (`encrypted_content`, item ids) the upstream
    /// accepts (the endpoint trust set). Reasoning from other systems is
    /// dropped with a warning; sealed reasoning is never sent.
    public var trustedReasoningOrigins: Set<WireSystemID>

    public init(trustedReasoningOrigins: Set<WireSystemID> = ["openai"]) {
        self.trustedReasoningOrigins = trustedReasoningOrigins
    }
}

// MARK: - Requests

extension ResponsesCodec {
    /// Top-level request fields kept in the bag without a warning.
    static let quietRequestKeys: Set<String> = [
        "previous_response_id", "include", "truncation", "metadata", "background", "conversation", "prompt",
        "max_tool_calls", "top_logprobs", "stream_options", "prompt_cache_retention",
    ]

    /// Built-in tool types kept opaque without a warning.
    static let knownOpaqueTools: Set<String> = [
        "web_search", "web_search_preview", "file_search", "computer_use_preview", "computer_use", "code_interpreter",
        "image_generation", "mcp", "local_shell", "shell", "custom", "apply_patch",
    ]

    /// Decodes a client's Responses request.
    ///
    /// Throws for invalid JSON, a missing `model`, an `input` that is neither
    /// a string nor an array, or a known field of the wrong type. Unknown
    /// fields and content go into bags and opaque parts, with warnings.
    package static func parseRequest(_ body: some Collection<UInt8>) throws(WireDecodingError) -> WireDecoded<WireRequest> {
        try parseRequest(JSONValue.parseWire(body))
    }

    package static func parseRequest(_ json: JSONValue) throws(WireDecodingError) -> WireDecoded<WireRequest> {
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var warnings: [WireWarning] = []
        var reader = FieldReader(object, path: "")
        let model = try reader.requiredString("model")
        var messages: [WireMessage] = []
        var inputSpelling: String?
        switch object["input"] {
        case .string(let text)?:
            _ = reader.raw("input")
            messages = [WireMessage(role: .user, parts: text.isEmpty ? [] : [.text(WireText(text))], contentForm: .string)]
            inputSpelling = "string"
        case .array(let items)?:
            _ = reader.raw("input")
            messages.reserveCapacity(items.count)
            // A sealed call signature waiting for its call (see ResponsesSeal).
            var pending: (contents: ResponsesSeal.Contents, path: String)?
            func dropPending(_ warnings: inout [WireWarning]) {
                if let pending {
                    warnings.append(WireWarning(.droppedContent, "sealed tool call signature without its call dropped", path: pending.path))
                }
                pending = nil
            }
            for (i, item) in items.enumerated() {
                let path = WirePath.index("input", i)
                if let sealed = ResponsesDecode.sealedCallSignature(item) {
                    dropPending(&warnings)
                    pending = (sealed, path)
                    continue
                }
                var message = try ResponsesDecode.inputItem(item, path: path, warnings: &warnings)
                if let carried = pending?.contents, message.role == .assistant, message.parts.count == 1,
                   case .toolCall(var call) = message.parts[0], call.itemType == nil
                {
                    call.signature = carried.signature
                    call.origin = carried.origin
                    call.itemID = nil
                    message.parts[0] = .toolCall(call)
                    pending = nil
                }
                dropPending(&warnings)
                messages.append(message)
            }
            dropPending(&warnings)
        case nil:
            inputSpelling = "absent"
        case .null?:
            break
        default:
            throw reader.mismatch("input", "a string or an array")
        }
        var request = WireRequest(model: model, messages: messages, source: .responses)
        if let inputSpelling { request.spellings[.input] = inputSpelling }

        if let instructions = try reader.string("instructions") {
            request.instructions = instructions.isEmpty ? [] : [.text(WireText(instructions))]
            request.instructionsForm = .string
        }
        request.maxOutputTokens = try reader.int("max_output_tokens")
        request.parallelToolCalls = try reader.bool("parallel_tool_calls")
        request.promptCacheKey = try reader.string("prompt_cache_key")
        if let reasoning = try reader.object("reasoning") {
            var inner = FieldReader(reasoning, path: "reasoning")
            var config = WireReasoningConfig()
            config.effort = try inner.string("effort")
            config.summary = try inner.string("summary")
            config.extra = ResponsesDecode.bag(inner, quiet: ["generate_summary"], warnings: &warnings)
            request.reasoning = config
        }
        request.safetyIdentifier = try reader.string("safety_identifier")
        request.serviceTier = try reader.string("service_tier")
        request.store = try reader.bool("store")
        request.stream = try reader.bool("stream")
        request.temperature = try reader.number("temperature")
        if case .object(let text)? = object["text"] {
            try decodeText(text, into: &request, reader: &reader, warnings: &warnings)
        }
        if let choice = object["tool_choice"], !choice.isNull {
            _ = reader.raw("tool_choice")
            request.toolChoice = decodeToolChoice(choice, warnings: &warnings)
        }
        if let tools = try reader.array("tools") {
            var decoded: [WireTool] = []
            for (i, tool) in tools.enumerated() {
                decoded.append(try decodeTool(tool, path: WirePath.index("tools", i), warnings: &warnings))
            }
            request.tools = decoded
        }
        request.topP = try reader.number("top_p")
        request.user = try reader.string("user")

        request.extra = ResponsesDecode.bag(reader, quiet: quietRequestKeys, warnings: &warnings)
        return WireDecoded(value: request, warnings: warnings)
    }

    /// `text`: decoded only when it has nothing but a well-formed `format`
    /// and a `verbosity`; otherwise it stays in the bag whole.
    private static func decodeText(
        _ text: JSONObject,
        into request: inout WireRequest,
        reader: inout FieldReader,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) {
        guard Set(text.keys).isSubset(of: ["format", "verbosity"]) else { return }
        let verbosity = text["verbosity"]
        guard verbosity == nil || verbosity?.stringValue != nil || verbosity == .null else { return }
        var format: WireResponseFormat?
        switch text["format"] {
        case .object(let object)?:
            guard case .string(let type)? = object["type"] else { return }
            var inner = FieldReader(object, path: "text.format")
            _ = inner.raw("type")
            var decoded = WireResponseFormat(kind: .init(rawValue: type))
            decoded.name = try inner.string("name")
            decoded.description = try inner.string("description")
            if let schema = inner.raw("schema") { decoded.schema = schema }
            decoded.strict = try inner.bool("strict")
            decoded.extra = inner.remaining(warnings: &warnings)
            format = decoded
        case nil:
            break
        default:
            return
        }
        _ = reader.raw("text")
        request.responseFormat = format
        request.verbosity = verbosity?.stringValue
    }

    private static func decodeToolChoice(_ value: JSONValue, warnings: inout [WireWarning]) -> WireToolChoice {
        switch value {
        case "auto": return .auto
        case "none": return .none
        case "required": return .required
        case .object(let object):
            if object.count == 2, object["type"] == "function", case .string(let name)? = object["name"] {
                return .function(name)
            }
        default:
            break
        }
        warnings.append(WireWarning(.opaqueContent, "tool_choice kept as opaque", path: "tool_choice"))
        return .opaque(WireOpaque(protocol: .responses, value: value))
    }

    private static func decodeTool(_ value: JSONValue, path: String, warnings: inout [WireWarning]) throws(WireDecodingError) -> WireTool {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        guard object["type"] == "function", case .string(let name)? = object["name"] else {
            let type = object["type"]?.stringValue ?? ""
            if !knownOpaqueTools.contains(type) {
                warnings.append(WireWarning(.opaqueContent, "tool of type `\(type)` kept as opaque", path: path))
            }
            return .opaque(WireOpaque(protocol: .responses, value: value))
        }
        var reader = FieldReader(object, path: path)
        _ = reader.raw("type")
        _ = reader.raw("name")
        var tool = WireFunctionTool(name: name)
        tool.description = try reader.string("description")
        if let parameters = reader.raw("parameters") { tool.parameters = parameters }
        tool.strict = try reader.bool("strict")
        tool.extra = ResponsesDecode.bag(reader, quiet: ["defer_loading"], warnings: &warnings)
        return .function(tool)
    }

    /// Encodes a request for a Responses upstream.
    ///
    /// Bags, opaque content and spellings are written only if
    /// `request.source` is Responses. Each wire message becomes one or more
    /// items (see ``ResponsesEncode/items(_:context:path:warnings:)``).
    /// For another source:
    /// - instructions with one text part become `instructions`; several
    ///   parts become a leading `system` message item;
    /// - reasoning is written only if ``ResponsesReplay`` accepts its origin
    ///   and it has an item id or encrypted content (sealed reasoning from
    ///   other systems never is); item ids of untrusted origins are dropped;
    /// - function tools get `strict: false` and an empty object schema when
    ///   unset (Responses defaults `strict` to true);
    /// - fields Responses lacks (`stop`, `seed`, penalties, `top_k`, `n`,
    ///   thinking budgets) are dropped with a warning.
    public static func buildRequest(_ request: WireRequest, options: ResponsesRequestOptions = .init()) -> WireEncoded {
        var warnings: [WireWarning] = []
        let include = request.source == .responses
        let context = ResponsesEncode.Context(include: include, trusted: options.trustedReasoningOrigins)
        var object = JSONObject()
        object["model"] = .string(request.model)

        var input: [JSONValue] = []
        var instructions: String?
        if let parts = request.instructions {
            if parts.count <= 1, parts.allSatisfy({ if case .text = $0 { true } else { false } }) {
                if case .text(let text)? = parts.first {
                    instructions = text.text
                    appendExtra(text.extra, to: &object, include: false, path: "instructions", warnings: &warnings)
                    if text.signature != nil {
                        warnings.append(WireWarning(.droppedContent, "text signature cannot be carried by Responses", path: "instructions"))
                    }
                } else {
                    instructions = ""
                }
                if !request.instructionsExtra.isEmpty {
                    var unused = JSONObject()
                    appendExtra(request.instructionsExtra, to: &unused, include: false, path: "instructions", warnings: &warnings)
                }
            } else {
                let system = WireMessage(role: .system, parts: parts, contentForm: .parts, extra: request.instructionsExtra)
                input += ResponsesEncode.items(system, context: context, path: "instructions", warnings: &warnings)
            }
        }
        for (i, message) in request.messages.enumerated() {
            input += ResponsesEncode.items(message, context: context, path: WirePath.index("input", i), warnings: &warnings)
        }
        let spelling = include ? request.spellings[.input] : nil
        if spelling == "string", request.messages.count == 1, let message = request.messages.first,
           message.role == .user, message.contentForm == .string, message.extra.isEmpty,
           message.parts.allSatisfy({ if case .text(let text) = $0 { text.extra.isEmpty && text.itemID == nil } else { false } }),
           message.parts.count <= 1
        {
            object["input"] = .string(message.parts.first.flatMap { if case .text(let text) = $0 { text.text } else { nil } } ?? "")
        } else if !(spelling == "absent" && input.isEmpty) {
            object["input"] = .array(input)
        }

        if let instructions { object["instructions"] = .string(instructions) }
        if let value = request.maxOutputTokens { object["max_output_tokens"] = .number(JSONNumber(value)) }
        if let value = request.parallelToolCalls { object["parallel_tool_calls"] = .bool(value) }
        if let value = request.promptCacheKey { object["prompt_cache_key"] = .string(value) }
        if let reasoning = request.reasoning, let value = encodeReasoning(reasoning, include: include, warnings: &warnings) {
            object["reasoning"] = value
        }
        if let value = request.safetyIdentifier { object["safety_identifier"] = .string(value) }
        if let value = request.serviceTier { object["service_tier"] = .string(value) }
        if let value = request.store { object["store"] = .bool(value) }
        if let value = request.stream { object["stream"] = .bool(value) }
        if let value = request.temperature { object["temperature"] = .number(value) }
        if request.responseFormat != nil || request.verbosity != nil {
            var text = JSONObject()
            if let format = request.responseFormat {
                text["format"] = encodeFormat(format, include: include, warnings: &warnings)
            }
            if let value = request.verbosity { text["verbosity"] = .string(value) }
            object["text"] = .object(text)
        }
        if let choice = request.toolChoice, let value = encodeToolChoice(choice, warnings: &warnings) {
            object["tool_choice"] = value
        }
        if let tools = request.tools {
            var items: [JSONValue] = []
            for (i, tool) in tools.enumerated() {
                if let item = encodeTool(tool, include: include, path: WirePath.index("tools", i), warnings: &warnings) {
                    items.append(item)
                }
            }
            object["tools"] = .array(items)
        }
        if let value = request.topP { object["top_p"] = .number(value) }
        if let value = request.user { object["user"] = .string(value) }

        dropUnsupported(request, warnings: &warnings)
        appendExtra(request.extra, to: &object, include: include, path: "", warnings: &warnings)
        return WireEncoded(json: .object(object), warnings: warnings)
    }

    private static func dropUnsupported(_ request: WireRequest, warnings: inout [WireWarning]) {
        func drop(_ present: Bool, _ field: String) {
            if present { warnings.append(WireWarning(.droppedField, "Responses has no `\(field)`", path: field)) }
        }
        drop(request.frequencyPenalty != nil, "frequency_penalty")
        drop(request.presencePenalty != nil, "presence_penalty")
        drop(request.seed != nil, "seed")
        drop(request.stop != nil, "stop")
        drop(request.topK != nil, "top_k")
        drop((request.candidateCount ?? 1) != 1, "n")
        // Responses streams always report usage; only unknown options matter.
        drop(!(request.streamOptions?.extra.isEmpty ?? true), "stream_options")
    }

    private static func encodeReasoning(_ reasoning: WireReasoningConfig, include: Bool, warnings: inout [WireWarning]) -> JSONValue? {
        var object = JSONObject()
        if let value = reasoning.effort { object["effort"] = .string(value) }
        if let value = reasoning.summary { object["summary"] = .string(value) }
        if reasoning.budgetTokens != nil {
            warnings.append(WireWarning(.droppedField, "Responses reasoning has no token budget", path: "reasoning"))
        }
        if reasoning.enabled == false {
            warnings.append(WireWarning(.droppedField, "Responses reasoning cannot be switched off without an effort", path: "reasoning"))
        }
        if reasoning.visible != nil {
            warnings.append(WireWarning(.droppedField, "Responses reasoning has no visibility setting", path: "reasoning"))
        }
        appendExtra(reasoning.extra, to: &object, include: include, path: "reasoning", warnings: &warnings)
        return object.isEmpty ? nil : .object(object)
    }

    private static func encodeFormat(_ format: WireResponseFormat, include: Bool, warnings: inout [WireWarning]) -> JSONValue {
        var object = JSONObject()
        object["type"] = .string(format.kind.rawValue)
        if let value = format.name {
            object["name"] = .string(value)
        } else if !include, format.kind == .jsonSchema {
            object["name"] = "response"
        }
        if let value = format.description { object["description"] = .string(value) }
        if let value = format.schema { object["schema"] = value }
        if let value = format.strict { object["strict"] = .bool(value) }
        appendExtra(format.extra, to: &object, include: include, path: "text.format", warnings: &warnings)
        return .object(object)
    }

    private static func encodeToolChoice(_ choice: WireToolChoice, warnings: inout [WireWarning]) -> JSONValue? {
        switch choice {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .function(let name): return ["type": "function", "name": .string(name)]
        case .opaque(let opaque):
            guard opaque.protocol == .responses else {
                warnings.append(WireWarning(.droppedField, "tool_choice from \(opaque.protocol.rawValue) cannot be carried", path: "tool_choice"))
                return nil
            }
            return opaque.value
        }
    }

    private static func encodeTool(_ tool: WireTool, include: Bool, path: String, warnings: inout [WireWarning]) -> JSONValue? {
        switch tool {
        case .function(let function):
            var object = JSONObject()
            object["type"] = "function"
            object["name"] = .string(function.name)
            if let value = function.description { object["description"] = .string(value) }
            if let value = function.parameters {
                object["parameters"] = value
            } else if !include {
                object["parameters"] = ["type": "object", "properties": [:]]
            }
            if let value = function.strict {
                object["strict"] = .bool(value)
            } else if !include {
                object["strict"] = false
            }
            appendExtra(function.extra, to: &object, include: include, path: path, warnings: &warnings)
            appendExtra(function.envelopeExtra, to: &object, include: include, path: path, warnings: &warnings)
            return .object(object)
        case .opaque(let opaque):
            guard opaque.protocol == .responses else {
                warnings.append(WireWarning(.droppedContent, "tool from \(opaque.protocol.rawValue) cannot be carried", path: path))
                return nil
            }
            return opaque.value
        }
    }
}

// MARK: - Non-streaming responses

/// Values a response encoder needs when the wire response lacks them.
package struct ResponsesResponseDefaults: Hashable, Sendable {
    package var id: String
    package var model: String
    package var created: Int
    /// Systems whose reasoning data the client may be given raw (it will
    /// return in its next request, to the same kind of upstream). Other
    /// systems' signatures and encrypted data are sealed (``ResponsesSeal``).
    package var trustedReasoningOrigins: Set<WireSystemID>

    package init(id: String, model: String, created: Int, trustedReasoningOrigins: Set<WireSystemID> = ["openai"]) {
        self.id = id
        self.model = model
        self.created = created
        self.trustedReasoningOrigins = trustedReasoningOrigins
    }
}

/// The parts of a `response` object outside `output`, shared by
/// ``ResponsesCodec/parseResponse(_:origin:)`` and the stream decoder.
struct ResponsesEnvelope {
    var id: String?
    var model: String?
    var created: Int?
    var status: String?
    var usage: WireUsage?
    var error: JSONValue?
    var incompleteReason: String?
    var output: [JSONValue]?
    var extra: JSONObject

    /// Request parameters a reply echoes: kept in the bag quietly.
    static let quietKeys: Set<String> = [
        "background", "instructions", "max_output_tokens", "max_tool_calls", "parallel_tool_calls",
        "previous_response_id", "prompt", "prompt_cache_key", "prompt_cache_retention", "reasoning",
        "safety_identifier", "service_tier", "store", "temperature", "text", "tool_choice", "tools",
        "top_logprobs", "top_p", "truncation", "user", "metadata", "billing", "conversation",
    ]

    init(_ object: JSONObject, path: String, warnings: inout [WireWarning]) throws(WireDecodingError) {
        var reader = FieldReader(object, path: path)
        id = try reader.string("id")
        _ = try reader.string("object")
        created = try reader.int("created_at")
        status = try reader.string("status")
        model = try reader.string("model")
        switch reader.raw("output") {
        case .array(let items)?: output = items
        case .null?, nil: break
        default: throw reader.mismatch("output", "an array")
        }
        switch reader.raw("usage") {
        case .object(let usage)?: self.usage = try ResponsesUsage.decode(usage, path: reader.path("usage"))
        case .null?, nil: break
        default: throw reader.mismatch("usage", "an object")
        }
        if let error = reader.raw("error"), !error.isNull { self.error = error }
        if case .object(let details)? = reader.raw("incomplete_details") {
            incompleteReason = details["reason"]?.stringValue
        }
        extra = ResponsesDecode.bag(reader, quiet: Self.quietKeys, warnings: &warnings)
    }
}

extension ResponsesCodec {
    /// Decodes a non-streaming upstream reply.
    ///
    /// `status` and `incomplete_details` give the finish reason (a completed
    /// reply with calls is ``WireFinishReason/Unified/toolCalls``); a
    /// non-null `error` goes to ``WireResponse/choiceExtra``. Item statuses
    /// are dropped (the encoder derives them), except a reasoning item's,
    /// which stays in its bag.
    ///
    /// - Parameter origin: the system id stamped on reasoning and item ids.
    public static func parseResponse(
        _ body: some Collection<UInt8>,
        origin: WireSystemID? = "openai",
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        try parseResponse(JSONValue.parseWire(body), origin: origin)
    }

    public static func parseResponse(
        _ json: JSONValue,
        origin: WireSystemID? = "openai",
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var warnings: [WireWarning] = []
        let envelope = try ResponsesEnvelope(object, path: "", warnings: &warnings)
        guard let output = envelope.output else { throw WireDecodingError(.missingField, path: "output") }
        var parts: [WirePart] = []
        for (i, item) in output.enumerated() {
            parts += try ResponsesDecode.outputItem(item, path: WirePath.index("output", i), origin: origin, warnings: &warnings)
        }
        var response = WireResponse(
            message: WireMessage(role: .assistant, parts: parts),
            id: envelope.id, model: envelope.model, created: envelope.created, usage: envelope.usage, source: .responses,
        )
        if let status = envelope.status {
            let hasCalls = parts.contains { if case .toolCall = $0 { true } else { false } }
            response.finishReason = ResponsesFinish.decode(status: status, incompleteReason: envelope.incompleteReason, hasToolCalls: hasCalls)
        }
        if let error = envelope.error { response.choiceExtra["error"] = error }
        response.extra = envelope.extra
        return WireDecoded(value: response, warnings: warnings)
    }

    /// Encodes a non-streaming reply for a Responses client.
    ///
    /// The reply is the final `response` object of
    /// ``ResponsesStreamEncoder`` fed the reply as events, so streaming and
    /// non-streaming replies agree on items, ids, statuses and sealing.
    package static func encodeResponse(_ response: WireResponse, defaults: ResponsesResponseDefaults) -> WireEncoded {
        var warnings: [WireWarning] = []
        var encoder = ResponsesStreamEncoder(defaults: defaults)
        for event in WireEvents.of(response, protocolName: "Responses", warnings: &warnings) {
            _ = encoder.encode(event)
        }
        _ = encoder.finish()
        warnings += encoder.warnings
        return WireEncoded(json: encoder.finalResponse ?? .object([:]), warnings: warnings)
    }
}

/// Turns a complete reply into the events a stream of it would carry.
enum WireEvents {
    /// One block per part (`p<i>`); tool calls whole. Tool results, images
    /// and files cannot appear in a reply and are dropped with a warning,
    /// as is the message bag.
    static func of(_ response: WireResponse, protocolName: String, warnings: inout [WireWarning]) -> [WireEvent] {
        var events: [WireEvent] = [.responseMetadata(WireResponseMetadata(
            id: response.id, model: response.model, created: response.created, extra: response.extra, source: response.source,
        ))]
        for (i, part) in response.message.parts.enumerated() {
            let block = "p\(i)"
            let path = WirePath.index("output", i)
            switch part {
            case .text(var text):
                let content = text.text
                text.text = ""
                events.append(.textStart(id: block, text: text))
                if !content.isEmpty { events.append(.textDelta(id: block, delta: content)) }
                events.append(.textEnd(id: block, text: nil))
            case .refusal(var refusal):
                let content = refusal.text
                refusal.text = ""
                events.append(.refusalStart(id: block, refusal: refusal))
                if !content.isEmpty { events.append(.refusalDelta(id: block, delta: content)) }
                events.append(.refusalEnd(id: block, refusal: nil))
            case .reasoning(var reasoning):
                let content = reasoning.text
                reasoning.text = ""
                events.append(.reasoningStart(id: block, reasoning: reasoning))
                if !content.isEmpty { events.append(.reasoningDelta(id: block, delta: content)) }
                events.append(.reasoningEnd(id: block, reasoning: nil))
            case .toolCall(let call):
                events.append(.toolCall(id: block, call: call))
            case .opaque(let opaque):
                events.append(.opaque(opaque))
            case .toolResult, .image, .file:
                warnings.append(WireWarning(.droppedContent, "part cannot appear in a \(protocolName) reply", path: path))
            }
        }
        if !response.message.extra.isEmpty {
            var unused = JSONObject()
            appendExtra(response.message.extra, to: &unused, include: false, path: "", warnings: &warnings)
        }
        events.append(.finish(WireFinish(reason: response.finishReason, usage: response.usage, extra: response.choiceExtra)))
        return events
    }
}
