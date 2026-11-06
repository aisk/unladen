/// OpenAI Chat Completions codec (and the OpenAI-compatible dialects:
/// DeepSeek `reasoning_content`, OpenRouter `reasoning`, …).
///
/// Directions:
/// - ``parseRequest(_:)`` client JSON → ``WireRequest`` (gateway only, `package`)
/// - ``buildRequest(_:)`` ``WireRequest`` → upstream JSON
/// - ``parseResponse(_:origin:)`` upstream JSON → ``WireResponse``;
///   streaming: ``ChatCompletionsStreamDecoder``
/// - ``encodeResponse(_:defaults:)`` ``WireResponse`` → client JSON (gateway
///   only); streaming: ``ChatCompletionsStreamEncoder``
///
/// Encoders write keys in a fixed order: `model`, `messages` (or the
/// response's `id`, `object`, `created`, `model`, `choices`, `usage`), then
/// the remaining known fields in API-reference (alphabetical) order, then
/// unknown fields in their decode order.
@_spi(Wire) public enum ChatCompletionsCodec {}

// MARK: - Requests

extension ChatCompletionsCodec {
    /// Decodes a client's Chat Completions request.
    ///
    /// Throws for invalid JSON, a missing `model`/`messages`/`role`, or a
    /// known field of the wrong type. Unknown fields and content go into
    /// bags and opaque parts, with warnings.
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
        let rawMessages = try reader.requiredArray("messages")
        var messages: [WireMessage] = []
        messages.reserveCapacity(rawMessages.count)
        for (i, message) in rawMessages.enumerated() {
            messages.append(try ChatDecode.message(
                message, path: WirePath.index("messages", i), idPrefix: "call_m\(i)", warnings: &warnings,
            ))
        }
        var request = WireRequest(model: model, messages: messages, source: .chatCompletions)

        // Synonyms: the official spelling wins if both are present; the
        // other stays in the bag.
        if let value = try reader.int("max_completion_tokens") {
            request.maxOutputTokens = value
            request.spellings[.maxOutputTokens] = "max_completion_tokens"
        } else if let value = try reader.int("max_tokens") {
            request.maxOutputTokens = value
            request.spellings[.maxOutputTokens] = "max_tokens"
        }
        if let effort = try reader.string("reasoning_effort") {
            request.reasoning = WireReasoningConfig(effort: effort)
            request.spellings[.reasoning] = "reasoning_effort"
        } else if case .object(let config)? = object["reasoning"] {
            _ = reader.raw("reasoning")
            var inner = FieldReader(config, path: "reasoning")
            var reasoning = WireReasoningConfig()
            reasoning.effort = try inner.string("effort")
            reasoning.budgetTokens = try inner.int("max_tokens")
            reasoning.enabled = try inner.bool("enabled")
            reasoning.visible = try inner.bool("exclude").map { !$0 }
            reasoning.extra = inner.remaining(warnings: &warnings)
            request.reasoning = reasoning
            request.spellings[.reasoning] = "reasoning"
        }

        request.frequencyPenalty = try reader.number("frequency_penalty")
        request.candidateCount = try reader.int("n")
        request.parallelToolCalls = try reader.bool("parallel_tool_calls")
        request.presencePenalty = try reader.number("presence_penalty")
        request.promptCacheKey = try reader.string("prompt_cache_key")
        if let format = try reader.object("response_format") {
            request.responseFormat = try decodeResponseFormat(format, warnings: &warnings)
        }
        request.safetyIdentifier = try reader.string("safety_identifier")
        request.seed = try reader.int("seed")
        request.serviceTier = try reader.string("service_tier")
        switch object["stop"] {
        case .string(let value)?:
            _ = reader.raw("stop")
            request.stop = .single(value)
        case .array(let values)?:
            var sequences: [String] = []
            for (i, value) in values.enumerated() {
                guard case .string(let text) = value else {
                    throw WireDecodingError(.typeMismatch(expected: "a string"), path: WirePath.index("stop", i))
                }
                sequences.append(text)
            }
            _ = reader.raw("stop")
            request.stop = .multiple(sequences)
        case .null?, nil:
            break
        default:
            throw reader.mismatch("stop", "a string or an array")
        }
        request.store = try reader.bool("store")
        request.stream = try reader.bool("stream")
        if let options = try reader.object("stream_options") {
            var inner = FieldReader(options, path: "stream_options")
            let includeUsage = try inner.bool("include_usage")
            request.streamOptions = WireStreamOptions(includeUsage: includeUsage, extra: inner.remaining(warnings: &warnings))
        }
        request.temperature = try reader.number("temperature")
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
        request.verbosity = try reader.string("verbosity")

        request.extra = reader.remaining(warnings: &warnings)
        return WireDecoded(value: request, warnings: warnings)
    }

    private static func decodeResponseFormat(
        _ object: JSONObject,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WireResponseFormat {
        var reader = FieldReader(object, path: "response_format")
        var format = WireResponseFormat(kind: .init(rawValue: try reader.requiredString("type")))
        if let schema = try reader.object("json_schema") {
            var inner = FieldReader(schema, path: "response_format.json_schema")
            format.name = try inner.string("name")
            format.description = try inner.string("description")
            if let value = inner.raw("schema") { format.schema = value }
            format.strict = try inner.bool("strict")
            format.extra = inner.remaining(warnings: &warnings)
        }
        reader.dropRemaining(warnings: &warnings)
        return format
    }

    private static func decodeToolChoice(_ value: JSONValue, warnings: inout [WireWarning]) -> WireToolChoice {
        switch value {
        case "auto": return .auto
        case "none": return .none
        case "required": return .required
        case .object(let object):
            if object.count == 2, object["type"] == "function",
               case .object(let function)? = object["function"], function.count == 1,
               case .string(let name)? = function["name"]
            {
                return .function(name)
            }
        default:
            break
        }
        warnings.append(WireWarning(.opaqueContent, "tool_choice kept as opaque", path: "tool_choice"))
        return .opaque(WireOpaque(protocol: .chatCompletions, value: value))
    }

    private static func decodeTool(
        _ value: JSONValue,
        path: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WireTool {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        guard object["type"] == "function", case .object(let function)? = object["function"] else {
            warnings.append(WireWarning(.opaqueContent, "non-function tool kept as opaque", path: path))
            return .opaque(WireOpaque(protocol: .chatCompletions, value: value))
        }
        var outer = FieldReader(object, path: path)
        _ = outer.raw("type")
        _ = outer.raw("function")
        var inner = FieldReader(function, path: outer.path("function"))
        var tool = WireFunctionTool(name: try inner.requiredString("name"))
        tool.description = try inner.string("description")
        if let parameters = inner.raw("parameters") { tool.parameters = parameters }
        tool.strict = try inner.bool("strict")
        tool.extra = inner.remaining(warnings: &warnings)
        tool.envelopeExtra = outer.remaining(warnings: &warnings)
        return .function(tool)
    }

    /// Encodes a request for a Chat Completions upstream.
    ///
    /// Bags and the client's spellings (``WireRequest/spellings``, part
    /// `sourceKey`s) are honoured only if `request.source` is Chat: another
    /// protocol's spelling may be invalid here. Consecutive assistant messages
    /// of another protocol are merged into one. Content Chat cannot carry
    /// (signatures, top-k, other protocols' opaque parts) is dropped with a
    /// warning. No default values are added.
    public static func buildRequest(_ request: WireRequest) -> WireEncoded {
        var warnings: [WireWarning] = []
        let include = request.source == .chatCompletions
        let spellings = include ? request.spellings : [:]
        var object = JSONObject()
        object["model"] = .string(request.model)

        var messages: [JSONValue] = []
        if let instructions = request.instructions {
            let system = WireMessage(
                role: .system, parts: instructions, contentForm: request.instructionsForm, extra: request.instructionsExtra,
            )
            messages += ChatEncode.messages(system, include: include, path: "instructions", warnings: &warnings)
        }
        // Another protocol may split one model turn into several messages
        // (Responses: one item each); Chat needs it whole, so tool calls
        // sit in one message before their results.
        var merged: [(message: WireMessage, index: Int)] = []
        for (i, message) in request.messages.enumerated() {
            if !include, message.role == .assistant, let last = merged.last, last.message.role == .assistant {
                var combined = last.message
                combined.parts += message.parts
                combined.contentForm = nil
                for (key, value) in message.extra where combined.extra[key] == nil { combined.extra[key] = value }
                merged[merged.count - 1].message = combined
            } else {
                merged.append((message, i))
            }
        }
        for (message, i) in merged {
            messages += ChatEncode.messages(message, include: include, path: WirePath.index("messages", i), warnings: &warnings)
        }
        object["messages"] = .array(messages)

        if let value = request.frequencyPenalty { object["frequency_penalty"] = .number(value) }
        if let value = request.maxOutputTokens {
            let spelling = spellings[.maxOutputTokens].flatMap { ["max_tokens", "max_completion_tokens"].contains($0) ? $0 : nil }
            object[spelling ?? "max_completion_tokens"] = .number(JSONNumber(value))
        }
        if let value = request.candidateCount { object["n"] = .number(JSONNumber(value)) }
        if let value = request.parallelToolCalls { object["parallel_tool_calls"] = .bool(value) }
        if let value = request.presencePenalty { object["presence_penalty"] = .number(value) }
        if let value = request.promptCacheKey { object["prompt_cache_key"] = .string(value) }
        if let reasoning = request.reasoning {
            encodeReasoning(reasoning, spelling: spellings[.reasoning], include: include, into: &object, warnings: &warnings)
        }
        if let format = request.responseFormat {
            object["response_format"] = encodeResponseFormat(format, include: include, warnings: &warnings)
        }
        if let value = request.safetyIdentifier { object["safety_identifier"] = .string(value) }
        if let value = request.seed { object["seed"] = .number(JSONNumber(value)) }
        if let value = request.serviceTier { object["service_tier"] = .string(value) }
        switch request.stop {
        case .single(let value)?: object["stop"] = .string(value)
        case .multiple(let values)?: object["stop"] = .array(values.map { .string($0) })
        case nil: break
        }
        if let value = request.store { object["store"] = .bool(value) }
        if let value = request.stream { object["stream"] = .bool(value) }
        if let options = request.streamOptions {
            var inner = JSONObject()
            if let value = options.includeUsage { inner["include_usage"] = .bool(value) }
            appendExtra(options.extra, to: &inner, include: include, path: "stream_options", warnings: &warnings)
            object["stream_options"] = .object(inner)
        }
        if let value = request.temperature { object["temperature"] = .number(value) }
        if let choice = request.toolChoice {
            if let value = encodeToolChoice(choice, warnings: &warnings) { object["tool_choice"] = value }
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
        if let value = request.verbosity { object["verbosity"] = .string(value) }
        if request.topK != nil {
            warnings.append(WireWarning(.droppedField, "Chat Completions has no top_k", path: "top_k"))
        }

        appendExtra(request.extra, to: &object, include: include, path: "", warnings: &warnings)
        return WireEncoded(json: .object(object), warnings: warnings)
    }

    private static func encodeReasoning(
        _ reasoning: WireReasoningConfig,
        spelling: String?,
        include: Bool,
        into object: inout JSONObject,
        warnings: inout [WireWarning],
    ) {
        if spelling == "reasoning" {
            var inner = JSONObject()
            if let value = reasoning.effort { inner["effort"] = .string(value) }
            if let value = reasoning.budgetTokens { inner["max_tokens"] = .number(JSONNumber(value)) }
            if let value = reasoning.enabled { inner["enabled"] = .bool(value) }
            if let value = reasoning.visible { inner["exclude"] = .bool(!value) }
            if reasoning.summary != nil {
                warnings.append(WireWarning(.droppedField, "Chat has no reasoning summary setting", path: "reasoning.summary"))
            }
            appendExtra(reasoning.extra, to: &inner, include: include, path: "reasoning", warnings: &warnings)
            object["reasoning"] = .object(inner)
            return
        }
        if let effort = reasoning.effort {
            object["reasoning_effort"] = .string(effort)
        }
        if reasoning.budgetTokens != nil || reasoning.enabled != nil || reasoning.visible != nil
            || reasoning.summary != nil || !reasoning.extra.isEmpty
        {
            warnings.append(WireWarning(.droppedField, "Chat `reasoning_effort` carries only an effort level", path: "reasoning_effort"))
        }
    }

    private static func encodeResponseFormat(
        _ format: WireResponseFormat,
        include: Bool,
        warnings: inout [WireWarning],
    ) -> JSONValue {
        var object = JSONObject()
        object["type"] = .string(format.kind.rawValue)
        let hasSchemaObject = format.name != nil || format.description != nil || format.schema != nil
            || format.strict != nil || !format.extra.isEmpty
        if hasSchemaObject {
            var schema = JSONObject()
            if let value = format.name { schema["name"] = .string(value) }
            if let value = format.description { schema["description"] = .string(value) }
            if let value = format.schema { schema["schema"] = value }
            if let value = format.strict { schema["strict"] = .bool(value) }
            appendExtra(format.extra, to: &schema, include: include, path: "response_format.json_schema", warnings: &warnings)
            object["json_schema"] = .object(schema)
        }
        return .object(object)
    }

    private static func encodeToolChoice(_ choice: WireToolChoice, warnings: inout [WireWarning]) -> JSONValue? {
        switch choice {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        case .function(let name): return ["type": "function", "function": ["name": .string(name)]]
        case .opaque(let opaque):
            guard opaque.protocol == .chatCompletions else {
                warnings.append(WireWarning(.droppedField, "tool_choice from \(opaque.protocol.rawValue) cannot be carried", path: "tool_choice"))
                return nil
            }
            return opaque.value
        }
    }

    private static func encodeTool(
        _ tool: WireTool,
        include: Bool,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        switch tool {
        case .function(let function):
            var inner = JSONObject()
            inner["name"] = .string(function.name)
            if let value = function.description { inner["description"] = .string(value) }
            if let value = function.parameters { inner["parameters"] = value }
            if let value = function.strict { inner["strict"] = .bool(value) }
            appendExtra(function.extra, to: &inner, include: include, path: WirePath.key(path, "function"), warnings: &warnings)
            var outer = JSONObject()
            outer["type"] = "function"
            outer["function"] = .object(inner)
            appendExtra(function.envelopeExtra, to: &outer, include: include, path: path, warnings: &warnings)
            return .object(outer)
        case .opaque(let opaque):
            guard opaque.protocol == .chatCompletions else {
                warnings.append(WireWarning(.droppedContent, "tool from \(opaque.protocol.rawValue) cannot be carried", path: path))
                return nil
            }
            return opaque.value
        }
    }
}

// MARK: - Non-streaming responses

/// Values a response encoder needs when the wire response lacks them.
package struct ChatResponseDefaults: Hashable, Sendable {
    package var id: String
    package var model: String
    package var created: Int

    package init(id: String, model: String, created: Int) {
        self.id = id
        self.model = model
        self.created = created
    }
}

extension ChatCompletionsCodec {
    /// Decodes a non-streaming upstream reply.
    ///
    /// - Parameter origin: the system id to stamp on fidelity data (none in
    ///   plain Chat; reserved for dialects that carry signatures).
    public static func parseResponse(
        _ body: some Collection<UInt8>,
        origin: WireSystemID? = nil,
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        try parseResponse(JSONValue.parseWire(body), origin: origin)
    }

    public static func parseResponse(
        _ json: JSONValue,
        origin: WireSystemID? = nil,
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var warnings: [WireWarning] = []
        var reader = FieldReader(object, path: "")
        let id = try reader.string("id")
        _ = try reader.string("object")
        let created = try reader.int("created")
        let model = try reader.string("model")
        let choices = try reader.requiredArray("choices")

        var response = WireResponse(
            message: WireMessage(role: .assistant, parts: []),
            id: id, model: model, created: created, source: .chatCompletions,
        )
        if let first = choices.first {
            guard case .object(let choice) = first else {
                throw WireDecodingError(.typeMismatch(expected: "an object"), path: "choices[0]")
            }
            var choiceReader = FieldReader(choice, path: "choices[0]")
            _ = try choiceReader.int("index")
            guard let message = choiceReader.raw("message") else {
                throw WireDecodingError(.missingField, path: "choices[0].message")
            }
            response.message = try ChatDecode.message(
                message, path: "choices[0].message", idPrefix: "call", warnings: &warnings,
            )
            if let reason = try choiceReader.string("finish_reason") {
                response.finishReason = ChatFinish.decode(reason)
            }
            response.choiceExtra = choiceReader.remaining(warnings: &warnings)
        }
        if choices.count > 1 {
            warnings.append(WireWarning(.droppedContent, "only the first of \(choices.count) choices is kept", path: "choices"))
        }
        if let usage = try reader.object("usage") {
            response.usage = try ChatUsage.decode(usage, path: "usage")
        }
        response.extra = reader.remaining(warnings: &warnings)
        stamp(&response.message, origin: origin)
        return WireDecoded(value: response, warnings: warnings)
    }

    static func stamp(_ message: inout WireMessage, origin: WireSystemID?) {
        guard let origin else { return }
        for i in message.parts.indices {
            switch message.parts[i] {
            case .reasoning(var reasoning) where reasoning.hasFidelityData:
                reasoning.origin = origin
                message.parts[i] = .reasoning(reasoning)
            case .toolCall(var call) where call.signature != nil || call.itemID != nil:
                call.origin = origin
                message.parts[i] = .toolCall(call)
            default:
                break
            }
        }
    }

    /// Encodes a non-streaming reply for a Chat Completions client.
    package static func encodeResponse(_ response: WireResponse, defaults: ChatResponseDefaults) -> WireEncoded {
        var warnings: [WireWarning] = []
        let include = response.source == .chatCompletions
        var object = JSONObject()
        object["id"] = .string(response.id ?? defaults.id)
        object["object"] = "chat.completion"
        object["created"] = .number(JSONNumber(response.created ?? defaults.created))
        object["model"] = .string(response.model ?? defaults.model)

        var message = response.message
        message.role = .assistant
        let encoded = ChatEncode.messages(message, include: include, path: "choices[0].message", warnings: &warnings)
        if encoded.count != 1 {
            warnings.append(WireWarning(.droppedContent, "tool results cannot appear in a Chat reply", path: "choices[0].message"))
        }
        var choice = JSONObject()
        choice["index"] = 0
        choice["message"] = encoded.last ?? ["role": "assistant", "content": nil]
        // Same protocol without a reason: whatever the source had (`null`)
        // comes back from the choice bag; otherwise a reason is required.
        if !(include && response.finishReason == nil) {
            choice["finish_reason"] = ChatFinish.encode(response.finishReason, sameProtocol: include)
        }
        appendExtra(response.choiceExtra, to: &choice, include: include, path: "choices[0]", warnings: &warnings)
        object["choices"] = [.object(choice)]
        if let usage = response.usage {
            object["usage"] = ChatUsage.encode(usage, include: include, path: "usage", warnings: &warnings)
        }
        appendExtra(response.extra, to: &object, include: include, path: "", warnings: &warnings)
        return WireEncoded(json: .object(object), warnings: warnings)
    }
}
