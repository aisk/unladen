/// Anthropic Messages codec (`/v1/messages`).
///
/// Directions:
/// - ``parseRequest(_:)`` client JSON → ``WireRequest`` (gateway only, `package`)
/// - ``buildRequest(_:options:)`` ``WireRequest`` → upstream JSON
/// - ``parseResponse(_:origin:)`` upstream JSON → ``WireResponse``;
///   streaming: ``AnthropicMessagesStreamDecoder``
/// - ``encodeResponse(_:defaults:)`` ``WireResponse`` → client JSON (gateway
///   only); streaming: ``AnthropicMessagesStreamEncoder``
///
/// Mapping notes:
/// - `system` → ``WireRequest/instructions`` (string or blocks, see
///   ``WireRequest/instructionsForm``); `metadata.user_id` →
///   ``WireRequest/user`` (a `metadata` object with other keys stays in the
///   bag whole); `stop_sequences` → ``WireStop/multiple(_:)``;
///   `output_config.effort` → ``WireReasoningConfig/effort`` (likewise only
///   when it is the object's sole key); another protocol's effort is
///   mapped onto Anthropic's levels (see `encodeEffort`).
/// - `thinking`: `enabled` + `budget_tokens` ↔ `enabled: true` + budget;
///   `adaptive` ↔ `enabled: true` without a budget; `disabled` ↔
///   `enabled: false`. Other keys of the object go to the reasoning bag.
/// - `tool_choice` `auto`/`any`/`tool`/`none` ↔ `auto`/`required`/
///   `function`/`none`; `disable_parallel_tool_use` ↔ `!parallelToolCalls`.
/// - Tools without a `type` (or `custom`) are function tools; server tools
///   (`web_search_…`, `bash_…`) are opaque.
/// - Content blocks: see ``AnthropicDecode/block(_:path:origin:warnings:)``.
///   `cache_control` and `citations` live in part bags (same protocol only;
///   dropped with a warning elsewhere, like any bag).
/// - Reasoning: `thinking.signature` → ``WireReasoning/signature``,
///   `redacted_thinking.data` → ``WireReasoning/encrypted``. Replies stamp
///   their origin (default `"anthropic"`); client requests leave it `nil`.
///   What may be replayed is decided by ``AnthropicReplay``.
/// - Tool-call ids (`tool_use.id`, `tool_result.tool_use_id`) pass through
///   ``AnthropicToolID``: decoders apply `inbound`, encoders `outbound`, so
///   other protocols' ids that Anthropic would reject travel reversibly.
///
/// Encoders write keys in a fixed order: `model`, `messages`, `max_tokens`,
/// then the remaining known fields in API-reference (alphabetical) order,
/// then unknown fields in their decode order (responses: `id`, `type`,
/// `role`, `model`, `content`, `stop_reason`, `stop_sequence`, `usage`).
@_spi(Wire) public enum AnthropicMessagesCodec {}

/// Settings for building an Anthropic request that the wire model does not
/// (and should not) carry. Profiles supply them per endpoint and model.
@_spi(Wire) public struct AnthropicRequestOptions: Hashable, Sendable {
    /// `max_tokens` to send when ``WireRequest/maxOutputTokens`` is `nil`
    /// (Anthropic requires the field). When a thinking budget is set and is
    /// not below this value, the budget is added to it, since Anthropic
    /// requires `max_tokens` > `budget_tokens`.
    public var defaultMaxTokens: Int
    /// Systems whose thinking signatures and redacted data the upstream
    /// accepts (the endpoint trust set). Reasoning from other systems is
    /// dropped with a warning.
    public var trustedReasoningOrigins: Set<WireSystemID>

    /// Whether the upstream takes thinking blocks without a signature it can
    /// verify (DeepSeek's Anthropic endpoint does; Anthropic does not). When
    /// set, reasoning text whose data is not trusted, or that has none, is
    /// written as `thinking` with an empty signature instead of being
    /// dropped.
    public var acceptsUnsignedThinking: Bool

    public init(
        defaultMaxTokens: Int = 4096,
        trustedReasoningOrigins: Set<WireSystemID> = ["anthropic"],
        acceptsUnsignedThinking: Bool = false,
    ) {
        self.defaultMaxTokens = defaultMaxTokens
        self.trustedReasoningOrigins = trustedReasoningOrigins
        self.acceptsUnsignedThinking = acceptsUnsignedThinking
    }
}

// MARK: - Requests

extension AnthropicMessagesCodec {
    /// Decodes a client's Messages request.
    ///
    /// Throws for invalid JSON, a missing `model`/`messages`/`max_tokens`/
    /// `role`, or a known field of the wrong type. Unknown fields and
    /// content go into bags and opaque parts, with warnings.
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
        guard object["max_tokens"] != nil else { throw WireDecodingError(.missingField, path: "max_tokens") }
        guard let maxTokens = try reader.int("max_tokens") else { throw reader.mismatch("max_tokens", "an integer") }

        var messages: [WireMessage] = []
        messages.reserveCapacity(rawMessages.count)
        for (i, value) in rawMessages.enumerated() {
            messages.append(try decodeMessage(value, path: WirePath.index("messages", i), warnings: &warnings))
        }
        var request = WireRequest(model: model, messages: messages, source: .anthropicMessages)
        request.maxOutputTokens = maxTokens

        if case .object(let metadata)? = object["metadata"], metadata.count == 1, case .string(let user)? = metadata["user_id"] {
            _ = reader.raw("metadata")
            request.user = user
        }
        if case .object(let config)? = object["output_config"], config.count == 1, case .string(let effort)? = config["effort"] {
            _ = reader.raw("output_config")
            request.reasoning = WireReasoningConfig(effort: effort)
        }
        request.serviceTier = try reader.string("service_tier")
        if let sequences = try reader.array("stop_sequences") {
            var values: [String] = []
            for (i, value) in sequences.enumerated() {
                guard case .string(let text) = value else {
                    throw WireDecodingError(.typeMismatch(expected: "a string"), path: WirePath.index("stop_sequences", i))
                }
                values.append(text)
            }
            request.stop = .multiple(values)
        }
        request.stream = try reader.bool("stream")
        switch object["system"] {
        case .string?, .array?:
            let system = try AnthropicDecode.content(reader.raw("system"), path: "system", origin: nil, warnings: &warnings)
            request.instructions = system.parts
            request.instructionsForm = system.form
        case .null?, nil:
            break
        default:
            throw reader.mismatch("system", "a string or an array")
        }
        request.temperature = try reader.number("temperature")
        if case .object(let thinking)? = object["thinking"],
           let type = thinking["type"]?.stringValue, ["enabled", "adaptive", "disabled"].contains(type)
        {
            // An unknown or missing type leaves the whole object in the bag.
            _ = reader.raw("thinking")
            request.reasoning = decodeThinking(thinking, type: type, base: request.reasoning, warnings: &warnings)
        }
        if let choice = try reader.object("tool_choice") {
            decodeToolChoice(choice, into: &request, warnings: &warnings)
        }
        if let tools = try reader.array("tools") {
            var decoded: [WireTool] = []
            for (i, tool) in tools.enumerated() {
                decoded.append(try decodeTool(tool, path: WirePath.index("tools", i), warnings: &warnings))
            }
            request.tools = decoded
        }
        request.topK = try reader.number("top_k")
        request.topP = try reader.number("top_p")

        request.extra = reader.remaining(warnings: &warnings)
        return WireDecoded(value: request, warnings: warnings)
    }

    private static func decodeMessage(
        _ value: JSONValue,
        path: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WireMessage {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        var reader = FieldReader(object, path: path)
        let role = WireRole(rawValue: try reader.requiredString("role"))
        let content = try AnthropicDecode.content(reader.raw("content"), path: reader.path("content"), origin: nil, warnings: &warnings)
        return WireMessage(role: role, parts: content.parts, contentForm: content.form, extra: reader.remaining(warnings: &warnings))
    }

    private static func decodeThinking(
        _ object: JSONObject,
        type: String,
        base: WireReasoningConfig?,
        warnings: inout [WireWarning],
    ) -> WireReasoningConfig {
        var inner = FieldReader(object, path: "thinking")
        var config = base ?? WireReasoningConfig()
        _ = inner.raw("type")
        switch type {
        case "enabled":
            config.enabled = true
            switch inner.raw("budget_tokens") {
            case .number(let number)? where number.int != nil:
                config.budgetTokens = number.int
            case let other?:
                // Keep a malformed budget verbatim for the upstream to judge.
                config.extra["budget_tokens"] = other
            case nil:
                break
            }
        case "adaptive":
            config.enabled = true
        default:
            config.enabled = false
        }
        for (key, value) in inner.remaining(warnings: &warnings) where config.extra[key] == nil {
            config.extra[key] = value
        }
        return config
    }

    private static func decodeToolChoice(_ object: JSONObject, into request: inout WireRequest, warnings: inout [WireWarning]) {
        let keys = Set(object.keys)
        let parallelOK = object["disable_parallel_tool_use"].map { $0.boolValue != nil } ?? true
        var choice: WireToolChoice?
        switch object["type"]?.stringValue {
        case "auto"? where keys.isSubset(of: ["type", "disable_parallel_tool_use"]) && parallelOK: choice = .auto
        case "any"? where keys.isSubset(of: ["type", "disable_parallel_tool_use"]) && parallelOK: choice = .required
        case "none"? where keys == ["type"]: choice = WireToolChoice.none
        case "tool"? where keys.isSubset(of: ["type", "name", "disable_parallel_tool_use"]) && parallelOK:
            if case .string(let name)? = object["name"] { choice = .function(name) }
        default: break
        }
        guard let choice else {
            warnings.append(WireWarning(.opaqueContent, "tool_choice kept as opaque", path: "tool_choice"))
            request.toolChoice = .opaque(WireOpaque(protocol: .anthropicMessages, value: .object(object)))
            return
        }
        request.toolChoice = choice
        if let disable = object["disable_parallel_tool_use"]?.boolValue {
            request.parallelToolCalls = !disable
        }
    }

    private static func decodeTool(
        _ value: JSONValue,
        path: String,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WireTool {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        let type = object["type"]
        guard type == nil || type == "custom", case .string(let name)? = object["name"] else {
            return .opaque(WireOpaque(protocol: .anthropicMessages, value: value))
        }
        var reader = FieldReader(object, path: path)
        _ = reader.raw("name")
        var tool = WireFunctionTool(name: name)
        tool.description = try reader.string("description")
        if let schema = reader.raw("input_schema") { tool.parameters = schema }
        tool.strict = try reader.bool("strict")
        // `type: "custom"` stays in the bag, quietly: it is how it was spelled.
        tool.extra = AnthropicDecode.bag(reader, quiet: ["type", "defer_loading", "input_examples"], warnings: &warnings)
        return .function(tool)
    }

    /// Encodes a request for an Anthropic upstream.
    ///
    /// Bags and opaque content are written only if `request.source` is
    /// Anthropic. For another source the builder also restructures the
    /// conversation the way Anthropic requires:
    /// - leading `system`/`developer` messages join ``WireRequest/instructions``
    ///   in `system`; later ones become user text (with a warning);
    /// - tool results (Chat `tool` messages, Responses items) go into user
    ///   turns, first in their turn (a reorder produces a warning);
    /// - consecutive turns of the same role are merged (Anthropic merges them
    ///   itself, so nothing is lost) and empty turns and empty or
///   whitespace-only text blocks dropped;
    /// - reasoning without an acceptable signature is dropped (see
    ///   ``AnthropicRequestOptions/trustedReasoningOrigins``).
    /// An Anthropic-sourced request is written as it came: no reordering.
    ///
    /// `max_tokens` falls back to ``AnthropicRequestOptions/defaultMaxTokens``.
    public static func buildRequest(_ request: WireRequest, options: AnthropicRequestOptions = .init()) -> WireEncoded {
        var warnings: [WireWarning] = []
        let include = request.source == .anthropicMessages
        let context = AnthropicEncode.Context(
            include: include, trusted: options.trustedReasoningOrigins, keepUnsignedReasoning: options.acceptsUnsignedThinking,
        )
        var object = JSONObject()
        object["model"] = .string(request.model)

        var assembler = AnthropicTurns(context: context)
        var systemParts = request.instructions
        var systemForm = request.instructionsForm
        var leading = true
        for (i, message) in request.messages.enumerated() {
            let path = WirePath.index("messages", i)
            if leading, message.role == .system || message.role == .developer {
                // One source keeps its form; several are blocks.
                systemForm = systemParts == nil ? message.contentForm : .parts
                systemParts = (systemParts ?? []) + message.parts
                var unused = JSONObject()
                appendExtra(message.extra, to: &unused, include: false, path: path, warnings: &warnings)
                continue
            }
            leading = false
            assembler.add(message, path: path, warnings: &warnings)
        }
        object["messages"] = .array(assembler.finish(warnings: &warnings))

        var maxTokens = request.maxOutputTokens ?? options.defaultMaxTokens
        if request.maxOutputTokens == nil, let budget = request.reasoning?.budgetTokens, budget >= maxTokens {
            maxTokens += budget
        }
        object["max_tokens"] = .number(JSONNumber(maxTokens))

        if let user = request.user { object["metadata"] = ["user_id": .string(user)] }
        if let effort = request.reasoning?.effort, let value = encodeEffort(effort, include: include, warnings: &warnings) {
            object["output_config"] = ["effort": .string(value)]
        }
        if let value = request.serviceTier { object["service_tier"] = .string(value) }
        if let stop = request.stop { object["stop_sequences"] = .array(stop.sequences.map { .string($0) }) }
        if let value = request.stream { object["stream"] = .bool(value) }
        if let parts = systemParts {
            let blocks = AnthropicEncode.blocks(parts, context: context, path: "system", warnings: &warnings).filter { block in
                if block.json["type"] == "text" || include { return true }
                warnings.append(WireWarning(.droppedContent, "only text can appear in system", path: "system"))
                return false
            }
            if let system = AnthropicEncode.content(blocks, form: systemForm, emptyDefault: nil) {
                object["system"] = system
            }
            if !request.instructionsExtra.isEmpty {
                var unused = JSONObject()
                appendExtra(request.instructionsExtra, to: &unused, include: false, path: "instructions", warnings: &warnings)
            }
        }
        if let value = request.temperature { object["temperature"] = .number(value) }
        if let reasoning = request.reasoning, let thinking = encodeThinking(reasoning, include: include, warnings: &warnings) {
            object["thinking"] = thinking
        }
        if let choice = encodeToolChoice(request.toolChoice, parallel: request.parallelToolCalls, warnings: &warnings) {
            object["tool_choice"] = choice
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
        if let value = request.topK { object["top_k"] = .number(value) }
        if let value = request.topP { object["top_p"] = .number(value) }

        dropUnsupported(request, warnings: &warnings)
        appendExtra(request.extra, to: &object, include: include, path: "", warnings: &warnings)
        return WireEncoded(json: .object(object), warnings: warnings)
    }

    private static func dropUnsupported(_ request: WireRequest, warnings: inout [WireWarning]) {
        func drop(_ present: Bool, _ field: String) {
            if present { warnings.append(WireWarning(.droppedField, "Anthropic has no `\(field)`", path: field)) }
        }
        drop(request.frequencyPenalty != nil, "frequency_penalty")
        drop(request.presencePenalty != nil, "presence_penalty")
        drop(request.seed != nil, "seed")
        drop((request.candidateCount ?? 1) != 1, "n")
        drop(request.responseFormat != nil, "response_format")
        drop(request.store != nil, "store")
        drop(request.promptCacheKey != nil, "prompt_cache_key")
        drop(request.safetyIdentifier != nil, "safety_identifier")
        drop(request.verbosity != nil, "verbosity")
        // Anthropic streams always report usage; only unknown options matter.
        drop(!(request.streamOptions?.extra.isEmpty ?? true), "stream_options")
    }

    /// Anthropic's `output_config.effort` levels.
    static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// `output_config.effort`. Another protocol's level is mapped onto
    /// Anthropic's: `minimal` is `low`; `none` (no reasoning) has no level
    /// and is left out; unknown levels are left out with a warning.
    private static func encodeEffort(_ effort: String, include: Bool, warnings: inout [WireWarning]) -> String? {
        if include || effortLevels.contains(effort) { return effort }
        let path = "output_config.effort"
        switch effort {
        case "minimal":
            warnings.append(WireWarning(.lossyConversion, "effort `minimal` sent as `low`", path: path))
            return "low"
        case "none":
            warnings.append(WireWarning(.lossyConversion, "effort `none` has no Anthropic level; left out", path: path))
            return nil
        default:
            warnings.append(WireWarning(.unsupportedValue, "effort `\(effort)` is not an Anthropic level; left out", path: path))
            return nil
        }
    }

    private static func encodeThinking(_ reasoning: WireReasoningConfig, include: Bool, warnings: inout [WireWarning]) -> JSONValue? {
        var object = JSONObject()
        switch (reasoning.enabled, reasoning.budgetTokens) {
        case (false?, _):
            object["type"] = "disabled"
        case (_, let budget?):
            object["type"] = "enabled"
            object["budget_tokens"] = .number(JSONNumber(budget))
        case (true?, nil):
            object["type"] = include && reasoning.extra["budget_tokens"] != nil ? "enabled" : "adaptive"
        case (nil, nil):
            if reasoning.visible != nil || reasoning.summary != nil || !reasoning.extra.isEmpty {
                warnings.append(WireWarning(.droppedField, "reasoning settings without thinking cannot be carried", path: "thinking"))
            }
            return nil
        }
        if reasoning.visible != nil {
            warnings.append(WireWarning(.droppedField, "Anthropic thinking has no visibility setting", path: "thinking"))
        }
        if reasoning.summary != nil {
            warnings.append(WireWarning(.droppedField, "Anthropic thinking has no summary setting", path: "thinking"))
        }
        appendExtra(reasoning.extra, to: &object, include: include, path: "thinking", warnings: &warnings)
        return .object(object)
    }

    private static func encodeToolChoice(_ choice: WireToolChoice?, parallel: Bool?, warnings: inout [WireWarning]) -> JSONValue? {
        var object = JSONObject()
        switch choice {
        case .auto?, nil:
            // Only a parallel-calls setting needs a choice object to live in.
            guard choice != nil || parallel == false else { return nil }
            object["type"] = "auto"
        case .required?: object["type"] = "any"
        case .none?:
            if parallel == false {
                warnings.append(WireWarning(.droppedField, "`none` tool choice carries no parallel setting", path: "tool_choice"))
            }
            return ["type": "none"]
        case .function(let name)?:
            object["type"] = "tool"
            object["name"] = .string(name)
        case .opaque(let opaque)?:
            guard opaque.protocol == .anthropicMessages else {
                warnings.append(WireWarning(.droppedField, "tool_choice from \(opaque.protocol.rawValue) cannot be carried", path: "tool_choice"))
                return nil
            }
            return opaque.value
        }
        if let parallel { object["disable_parallel_tool_use"] = .bool(!parallel) }
        return .object(object)
    }

    private static func encodeTool(_ tool: WireTool, include: Bool, path: String, warnings: inout [WireWarning]) -> JSONValue? {
        switch tool {
        case .function(let function):
            var object = JSONObject()
            object["name"] = .string(function.name)
            if let value = function.description { object["description"] = .string(value) }
            // Anthropic requires a schema; an absent one means "no arguments".
            object["input_schema"] = function.parameters ?? ["type": "object", "properties": [:]]
            if let value = function.strict { object["strict"] = .bool(value) }
            appendExtra(function.extra, to: &object, include: include, path: path, warnings: &warnings)
            appendExtra(function.envelopeExtra, to: &object, include: include, path: path, warnings: &warnings)
            return .object(object)
        case .opaque(let opaque):
            guard opaque.protocol == .anthropicMessages else {
                warnings.append(WireWarning(.droppedContent, "tool from \(opaque.protocol.rawValue) cannot be carried", path: path))
                return nil
            }
            return opaque.value
        }
    }
}

/// Assembles wire messages into Anthropic turns (see
/// ``AnthropicMessagesCodec/buildRequest(_:options:)`` for the rules).
private struct AnthropicTurns {
    struct Turn {
        var role: String
        var blocks: [AnthropicBlock]
        /// The source message's form; `nil` once merged.
        var form: WireContentForm?
        var extra: JSONObject
        var path: String
    }

    let context: AnthropicEncode.Context
    var turns: [Turn] = []

    init(context: AnthropicEncode.Context) {
        self.context = context
    }

    mutating func add(_ message: WireMessage, path: String, warnings: inout [WireWarning]) {
        let contentPath = WirePath.key(path, "content")
        if context.include, ![.system, .developer, .tool, .item].contains(message.role) {
            // Same protocol: as it came.
            let blocks = AnthropicEncode.blocks(message.parts, context: context, path: contentPath, warnings: &warnings)
            turns.append(Turn(role: message.role.rawValue, blocks: blocks, form: message.contentForm, extra: message.extra, path: path))
            return
        }
        // Bags of another protocol's message have no place; warn once here.
        if !context.include {
            var unused = JSONObject()
            appendExtra(message.extra, to: &unused, include: false, path: path, warnings: &warnings)
        }
        var results: [AnthropicBlock] = []
        var rest: [AnthropicBlock] = []
        var calls: [AnthropicBlock] = []
        for (i, part) in message.parts.enumerated() {
            let partPath = WirePath.index(contentPath, i)
            switch (message.role, part) {
            case (_, .toolResult):
                if let block = AnthropicEncode.block(part, context: context, path: partPath, warnings: &warnings) {
                    results.append(block)
                }
            case (.item, .toolCall):
                if let block = AnthropicEncode.block(part, context: context, path: partPath, warnings: &warnings) {
                    calls.append(block)
                }
            case (.item, _), (.tool, _):
                warnings.append(WireWarning(.droppedContent, "content of a `\(message.role)` message cannot be carried", path: partPath))
            case (.user, .toolCall), (.user, .reasoning):
                warnings.append(WireWarning(.droppedContent, "model output in a user turn cannot be carried", path: partPath))
            default:
                if let block = AnthropicEncode.block(part, context: context, path: partPath, warnings: &warnings) {
                    rest.append(block)
                }
            }
        }
        if !results.isEmpty {
            turns.append(Turn(role: "user", blocks: results, form: nil, extra: [:], path: path))
        }
        if !calls.isEmpty {
            turns.append(Turn(role: "assistant", blocks: calls, form: nil, extra: [:], path: path))
        }
        switch message.role {
        case .user, .assistant:
            let form = results.isEmpty ? message.contentForm : nil
            turns.append(Turn(role: message.role.rawValue, blocks: rest, form: form, extra: [:], path: path))
        case .system, .developer:
            warnings.append(WireWarning(.lossyConversion, "a `\(message.role)` message after the conversation began sent as user text", path: path))
            turns.append(Turn(role: "user", blocks: rest, form: nil, extra: [:], path: path))
        case .tool, .item:
            break
        default:
            if !rest.isEmpty {
                warnings.append(WireWarning(.droppedContent, "role `\(message.role)` cannot be carried by Anthropic", path: path))
            }
        }
    }

    func finish(warnings: inout [WireWarning]) -> [JSONValue] {
        var output = turns
        if !context.include {
            // Drop empty and whitespace-only text blocks (Anthropic rejects
            // both; Chat clients send `"content": "\n"` beside tool calls)
            // and empty turns, then merge same-role neighbours and put tool
            // results first in their user turn.
            output = output.compactMap { turn in
                var turn = turn
                turn.blocks.removeAll { $0.plainText?.allSatisfy(\.isWhitespace) == true }
                return turn.blocks.isEmpty ? nil : turn
            }
            var merged: [Turn] = []
            for turn in output {
                if var last = merged.last, last.role == turn.role {
                    last.blocks += turn.blocks
                    last.form = nil
                    merged[merged.count - 1] = last
                } else {
                    merged.append(turn)
                }
            }
            for i in merged.indices where merged[i].role == "user" {
                let blocks = merged[i].blocks
                let firstOther = blocks.firstIndex { !$0.isToolResult } ?? blocks.endIndex
                if blocks[firstOther...].contains(where: \.isToolResult) {
                    warnings.append(WireWarning(.lossyConversion, "tool results moved before other content of their turn", path: merged[i].path))
                    merged[i].blocks = blocks.filter(\.isToolResult) + blocks.filter { !$0.isToolResult }
                }
            }
            output = merged
        }
        return output.map { turn in
            var object = JSONObject()
            object["role"] = .string(turn.role)
            if let content = AnthropicEncode.content(turn.blocks, form: turn.form, emptyDefault: .array([])) {
                object["content"] = content
            }
            var ignored: [WireWarning] = []
            appendExtra(turn.extra, to: &object, include: true, path: turn.path, warnings: &ignored)
            return .object(object)
        }
    }
}

// MARK: - Non-streaming responses

/// Values a response encoder needs when the wire response lacks them.
package struct AnthropicResponseDefaults: Hashable, Sendable {
    package var id: String
    package var model: String
    /// Systems whose reasoning signatures the client may be given back
    /// (they will return in its next request). Other reasoning keeps its
    /// text with an empty signature.
    package var trustedReasoningOrigins: Set<WireSystemID>

    package init(id: String, model: String, trustedReasoningOrigins: Set<WireSystemID> = ["anthropic"]) {
        self.id = id
        self.model = model
        self.trustedReasoningOrigins = trustedReasoningOrigins
    }
}

extension AnthropicMessagesCodec {
    /// Decodes a non-streaming upstream reply.
    ///
    /// - Parameter origin: the system id stamped on every reasoning part
    ///   (`"anthropic"` for the first-party API; Bedrock or Vertex endpoints
    ///   pass their own).
    public static func parseResponse(
        _ body: some Collection<UInt8>,
        origin: WireSystemID? = "anthropic",
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        try parseResponse(JSONValue.parseWire(body), origin: origin)
    }

    public static func parseResponse(
        _ json: JSONValue,
        origin: WireSystemID? = "anthropic",
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var warnings: [WireWarning] = []
        var reader = FieldReader(object, path: "")
        let id = try reader.string("id")
        _ = try reader.string("type")
        _ = try reader.string("role")
        let model = try reader.string("model")
        guard let rawContent = reader.raw("content") else { throw WireDecodingError(.missingField, path: "content") }
        guard case .array = rawContent else { throw reader.mismatch("content", "an array") }
        let content = try AnthropicDecode.content(rawContent, path: "content", origin: origin, warnings: &warnings)
        var response = WireResponse(
            message: WireMessage(role: .assistant, parts: content.parts),
            id: id, model: model, source: .anthropicMessages,
        )
        if let reason = try reader.string("stop_reason") {
            response.finishReason = AnthropicFinish.decode(reason)
        }
        for key in AnthropicFinish.extraKeys {
            if let value = reader.raw(key) { response.choiceExtra[key] = value }
        }
        if let usage = try reader.object("usage") {
            response.usage = try AnthropicUsage.decode(usage, path: "usage")
        }
        response.extra = reader.remaining(warnings: &warnings)
        return WireDecoded(value: response, warnings: warnings)
    }

    /// Encodes a non-streaming reply for an Anthropic client.
    ///
    /// Another protocol's reply gets `stop_sequence: null` and a `usage`
    /// with zeros for unknown counts, both of which clients require.
    package static func encodeResponse(_ response: WireResponse, defaults: AnthropicResponseDefaults) -> WireEncoded {
        var warnings: [WireWarning] = []
        let include = response.source == .anthropicMessages
        let context = AnthropicEncode.Context(
            include: include, trusted: defaults.trustedReasoningOrigins, keepUnsignedReasoning: true,
        )
        var object = JSONObject()
        object["id"] = .string(response.id ?? defaults.id)
        object["type"] = "message"
        object["role"] = "assistant"
        object["model"] = .string(response.model ?? defaults.model)
        var blocks: [JSONValue] = []
        for (i, part) in response.message.parts.enumerated() {
            let path = WirePath.index("content", i)
            if case .toolResult = part {
                warnings.append(WireWarning(.droppedContent, "tool results cannot appear in a reply", path: path))
                continue
            }
            if let block = AnthropicEncode.block(part, context: context, path: path, warnings: &warnings) {
                blocks.append(block.json)
            }
        }
        object["content"] = .array(blocks)
        // Same protocol without a reason: the source's `null` comes back from the bag.
        if !(include && response.finishReason == nil) {
            object["stop_reason"] = .string(AnthropicFinish.encode(response.finishReason, sameProtocol: include))
        }
        if include {
            appendExtra(response.choiceExtra, to: &object, include: true, path: "", warnings: &warnings)
        } else {
            appendExtra(response.choiceExtra, to: &object, include: false, path: "", warnings: &warnings)
            object["stop_sequence"] = .null
        }
        if response.usage != nil || !include {
            object["usage"] = AnthropicUsage.encode(response.usage, include: include)
        }
        if !response.message.extra.isEmpty {
            var unused = JSONObject()
            appendExtra(response.message.extra, to: &unused, include: false, path: "", warnings: &warnings)
        }
        appendExtra(response.extra, to: &object, include: include, path: "", warnings: &warnings)
        return WireEncoded(json: .object(object), warnings: warnings)
    }
}
