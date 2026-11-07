/// Google Gemini `generateContent` codec.
///
/// Directions:
/// - ``parseRequest(_:model:stream:)`` client JSON → ``WireRequest``
///   (gateway only, `package`)
/// - ``buildRequest(_:options:)`` ``WireRequest`` → upstream JSON body
/// - ``parseResponse(_:origin:)`` upstream JSON → ``WireResponse``;
///   streaming: ``GeminiStreamDecoder``
/// - ``encodeResponse(_:defaults:)`` ``WireResponse`` → client JSON
///   (gateway only); streaming: ``GeminiStreamEncoder``
///
/// **Model and streaming live in the URL**, not the body:
/// `POST /v1beta/models/{model}:generateContent` and
/// `…:streamGenerateContent?alt=sse`. The gateway reads them from the path
/// (``parsePath(_:)``) and passes them to ``parseRequest(_:model:stream:)``;
/// ``buildRequest(_:options:)`` writes the body only (``WireRequest/model``
/// and ``WireRequest/stream`` are not written) and the caller sends it to
/// ``path(model:stream:)``. Streams must use `alt=sse` (without it Gemini
/// streams one JSON array, which this codec does not read).
///
/// Mapping notes:
/// - `contents[]` → messages (`user` → user, `model` → assistant; a missing
///   role is read as `user` and written back as `"user"`); parts: see
///   ``GeminiDecode/part(_:path:origin:isReply:warnings:)``. Text with
///   `thought: true` is reasoning; `thoughtSignature` goes to
///   ``WireText/signature``, ``WireReasoning/signature`` or
///   ``WireToolCall/signature``. A part's unknown keys are its bag; for
///   parts that wrap an object (`functionCall`, `functionResponse`,
///   `inlineData`, `fileData`) the bag holds the inner object's unknown keys
///   and the part's own under `"#part"`.
/// - `functionCall.args` (an object) ↔ ``WireToolCall/arguments`` (text):
///   decoders write it compactly with the deterministic JSON writer
///   (numbers and key order preserved); encoders parse it back. Arguments
///   that are not a JSON object are sent as `{}` with a warning (as for
///   Anthropic); empty arguments omit `args`.
/// - `functionResponse.response`: `{"output": s}` / `{"error": s}` with a
///   string is the text `s` (form ``WireContentForm/string``, `error` sets
///   ``WireToolResult/isError``); any other object is its compact JSON text
///   (form ``WireContentForm/parts``), written back as that object to
///   Gemini. Other protocols' results become `{"output": text}` (or
///   `{"error": text}`). `functionResponse.parts` (media) follow the text.
/// - Ids: see ``GeminiToolID``. Responses without `id` are matched to the
///   first unanswered call of the same name (else the latest such call).
/// - `systemInstruction` (a `Content`, or a bare string some clients send)
///   ↔ ``WireRequest/instructions``; its keys besides `parts` (`role`) go
///   to ``WireRequest/instructionsExtra``.
/// - `tools[]`: `functionDeclarations` become function tools (`parameters`
///   or `parametersJsonSchema`, recorded in ``WireFunctionTool/sourceKey``;
///   other protocols' tools are written with `parametersJsonSchema`); every
///   other tool (`googleSearch`, `codeExecution`, `urlContext`…) is opaque.
///   Consecutive function tools are written as one `functionDeclarations`
///   tool.
/// - `toolConfig.functionCallingConfig` ↔ ``WireRequest/toolChoice``:
///   `AUTO` ↔ auto, `NONE` ↔ none, `ANY` ↔ required, `ANY` with one allowed
///   name ↔ function; anything else (`VALIDATED`, several names) is opaque.
/// - `generationConfig`: `maxOutputTokens`, `temperature`, `topP`, `topK`,
///   `candidateCount`, `stopSequences`, `seed`, `presencePenalty`,
///   `frequencyPenalty` ↔ the request fields; `responseMimeType`
///   `application/json` (+ `responseSchema`/`responseJsonSchema`, recorded
///   in ``WireResponseFormat/sourceKey``) and `text/plain` ↔
///   ``WireRequest/responseFormat``; `thinkingConfig` `thinkingBudget` ↔
///   ``WireReasoningConfig/budgetTokens``, `thinkingLevel` ↔
///   ``WireReasoningConfig/effort``, `includeThoughts` ↔
///   ``WireReasoningConfig/visible``.
/// - Unknown keys of `generationConfig` and `toolConfig` (and a
///   `generationConfig` the codec does not fully read) are kept in
///   ``WireRequest/extra`` under the same key, as a partial object the
///   encoder merges into what it writes. `safetySettings`, `cachedContent`
///   and `labels` stay in the top-level bag without a warning.
/// - Field names are camelCase only; snake_case keys (which Google's API
///   also accepts) are kept in bags like any unknown key.
///
/// Encoders write keys in a fixed order: `contents`, `systemInstruction`,
/// `tools`, `toolConfig`, `generationConfig`, then unknown fields in decode
/// order (responses: `candidates`, `promptFeedback`, `usageMetadata`,
/// `modelVersion`, `responseId`).
@_spi(Wire) public enum GeminiCodec {}

/// Settings for building a Gemini request that the wire model does not (and
/// should not) carry. Profiles supply them per endpoint and model.
@_spi(Wire) public struct GeminiRequestOptions: Hashable, Sendable {
    /// Systems whose `thoughtSignature`s the upstream accepts (the endpoint
    /// trust set). Signatures from other systems are dropped with a warning.
    public var trustedSignatureOrigins: Set<WireSystemID>
    /// The `thoughtSignature` to send on a function call that has none the
    /// upstream accepts, unless an earlier call of the same model turn got
    /// one (Gemini signs only the first call of parallel calls).
    ///
    /// Gemini 3 rejects history whose function calls lack signatures (HTTP
    /// 400); Google documents `"skip_thought_signature_validator"` for
    /// history it did not sign (calls made by another model, or by a client
    /// that dropped the signature). `nil` (the default) sends nothing; a
    /// Gemini 3 Profile sets ``skipSignatureValidator``.
    public var missingSignatureFallback: String?

    /// The documented sentinel for ``missingSignatureFallback``.
    public static let skipSignatureValidator = "skip_thought_signature_validator"

    /// The function-declaration key for tool schemas: `parameters` (the
    /// OpenAPI subset) or `parametersJsonSchema`. When set it wins over the
    /// client's own key; `nil` keeps the same-protocol key, else
    /// `parametersJsonSchema`.
    public var parametersKey: String?

    public init(
        trustedSignatureOrigins: Set<WireSystemID> = ["gemini"],
        missingSignatureFallback: String? = nil,
        parametersKey: String? = nil,
    ) {
        self.trustedSignatureOrigins = trustedSignatureOrigins
        self.missingSignatureFallback = missingSignatureFallback
        self.parametersKey = parametersKey
    }
}

// MARK: - Paths

extension GeminiCodec {
    /// The request path for `model`: `/v1beta/models/{model}:generateContent`
    /// or, streaming, `/v1beta/models/{model}:streamGenerateContent?alt=sse`.
    /// A `models/` prefix on `model` is not repeated. The rest is
    /// percent-encoded as one path segment (everything but RFC 3986
    /// unreserved characters, `/` included), so no model id can reach
    /// another path or add a query.
    public static func path(model: String, stream: Bool) -> String {
        let name = percentEncodedSegment(model.hasPrefix("models/") ? String(model.dropFirst(7)) : model)
        return stream
            ? "/v1beta/models/\(name):streamGenerateContent?alt=sse"
            : "/v1beta/models/\(name):generateContent"
    }

    static func percentEncodedSegment(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(byte)
            default:
                out += [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Splits a client's request path (`…/models/{model}:generateContent`
    /// or `:streamGenerateContent`, any version prefix, any query) into the
    /// model and the stream flag; `nil` for other paths.
    package static func parsePath(_ path: String) -> (model: String, stream: Bool)? {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        guard let marker = route.ranges(of: "/models/").last else { return nil }
        let tail = route[marker.upperBound...]
        guard let colon = tail.lastIndex(of: ":") else { return nil }
        let model = String(tail[..<colon])
        guard !model.isEmpty else { return nil }
        switch tail[tail.index(after: colon)...] {
        case "generateContent": return (model, false)
        case "streamGenerateContent": return (model, true)
        default: return nil
        }
    }
}

// MARK: - Requests

extension GeminiCodec {
    /// Top-level request fields kept in the bag without a warning.
    static let quietRequestKeys: Set<String> = ["safetySettings", "cachedContent", "labels"]
    /// Bag keys that hold a partial object merged into an encoded field.
    static let nestedBagKeys: Set<String> = ["generationConfig", "toolConfig"]

    /// Decodes a client's `generateContent` request.
    ///
    /// - Parameters:
    ///   - model: the model from the URL path (``parsePath(_:)``).
    ///   - stream: `true` for `streamGenerateContent`; stored in
    ///     ``WireRequest/stream``.
    ///
    /// Throws for invalid JSON, a missing `contents`, or a known field of the
    /// wrong type. Unknown fields and content go into bags and opaque parts,
    /// with warnings.
    package static func parseRequest(
        _ body: some Collection<UInt8>,
        model: String,
        stream: Bool,
    ) throws(WireDecodingError) -> WireDecoded<WireRequest> {
        try parseRequest(JSONValue.parseWire(body), model: model, stream: stream)
    }

    package static func parseRequest(_ json: JSONValue, model: String, stream: Bool) throws(WireDecodingError) -> WireDecoded<WireRequest> {
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var warnings: [WireWarning] = []
        var reader = FieldReader(object, path: "")
        let contents = try reader.requiredArray("contents")
        var request = WireRequest(model: model, messages: try decodeContents(contents, warnings: &warnings), source: .gemini)
        request.stream = stream

        switch object["systemInstruction"] {
        case .string(let text)?:
            _ = reader.raw("systemInstruction")
            request.instructions = text.isEmpty ? [] : [.text(WireText(text))]
            request.instructionsForm = .string
        case .object(let system)?:
            _ = reader.raw("systemInstruction")
            var inner = FieldReader(system, path: "systemInstruction")
            request.instructions = try GeminiDecode.parts(
                inner.raw("parts"), path: inner.path("parts"), origin: nil, isReply: false, warnings: &warnings,
            )
            request.instructionsForm = system["parts"] == nil ? .absent : .parts
            // `role` is Gemini's own key: kept in the bag quietly.
            var local: [WireWarning] = []
            request.instructionsExtra = inner.remaining(warnings: &local)
            warnings += local.filter { $0.path != inner.path("role") }
        case .null?, nil:
            break
        default:
            throw reader.mismatch("systemInstruction", "an object")
        }
        if let tools = try reader.array("tools") {
            request.tools = try decodeTools(tools, warnings: &warnings)
        }
        if let config = try reader.object("toolConfig") {
            decodeToolConfig(config, into: &request, warnings: &warnings)
        }
        if let config = try reader.object("generationConfig") {
            try decodeGenerationConfig(config, into: &request, warnings: &warnings)
        }

        var local: [WireWarning] = []
        for (key, value) in reader.remaining(warnings: &local) {
            request.extra[key] = value
        }
        warnings += local.filter { warning in !quietRequestKeys.contains { warning.path == $0 } }
        return WireDecoded(value: request, warnings: warnings)
    }

    /// Decodes `contents`, synthesizing missing tool ids and matching
    /// id-less responses to calls (see ``GeminiToolID``).
    private static func decodeContents(_ contents: [JSONValue], warnings: inout [WireWarning]) throws(WireDecodingError) -> [WireMessage] {
        var messages: [WireMessage] = []
        var calls: [(name: String, id: String)] = []
        var unanswered: [String] = []
        for (c, value) in contents.enumerated() {
            let path = WirePath.index("contents", c)
            guard case .object(let object) = value else {
                throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
            }
            var reader = FieldReader(object, path: path)
            let role: WireRole = switch try reader.string("role") {
            case "model"?: .assistant
            case "user"?, nil: .user
            case let other?: WireRole(rawValue: other)
            }
            var parts = try GeminiDecode.parts(reader.raw("parts"), path: reader.path("parts"), origin: nil, isReply: false, warnings: &warnings)
            for p in parts.indices {
                switch parts[p] {
                case .toolCall(var call):
                    if call.idSynthesized { call.id = GeminiToolID.request(content: c, part: p) }
                    calls.append((call.name, call.id))
                    unanswered.append(call.id)
                    parts[p] = .toolCall(call)
                case .toolResult(var result):
                    if result.callIDSynthesized {
                        let name = result.name
                        let open = unanswered.first { id in calls.contains { $0.id == id && $0.name == name } }
                        result.callID = open ?? calls.last { $0.name == name }?.id ?? GeminiToolID.request(content: c, part: p)
                    }
                    unanswered.removeAll { $0 == result.callID }
                    parts[p] = .toolResult(result)
                default:
                    break
                }
            }
            let form: WireContentForm? = object["parts"] == nil ? .absent : nil
            messages.append(WireMessage(role: role, parts: parts, contentForm: form, extra: reader.remaining(warnings: &warnings)))
        }
        return messages
    }

    private static func decodeTools(_ tools: [JSONValue], warnings: inout [WireWarning]) throws(WireDecodingError) -> [WireTool] {
        var decoded: [WireTool] = []
        for (i, tool) in tools.enumerated() {
            let path = WirePath.index("tools", i)
            guard case .object(var object) = tool else {
                throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
            }
            if case .array(let declarations)? = object["functionDeclarations"] {
                object["functionDeclarations"] = nil
                for (j, declaration) in declarations.enumerated() {
                    decoded.append(decodeDeclaration(
                        declaration, path: WirePath.index(WirePath.key(path, "functionDeclarations"), j), warnings: &warnings,
                    ))
                }
            }
            if !object.isEmpty {
                let known = object.keys.contains { knownOpaqueTools.contains($0) }
                if !known { warnings.append(WireWarning(.opaqueContent, "tool kept as opaque", path: path)) }
                decoded.append(.opaque(WireOpaque(protocol: .gemini, value: .object(object))))
            }
        }
        return decoded
    }

    /// Built-in tools kept opaque without a warning.
    static let knownOpaqueTools: Set<String> = [
        "googleSearch", "googleSearchRetrieval", "codeExecution", "urlContext", "fileSearch", "computerUse", "googleMaps",
        "enterpriseWebSearch", "retrieval", "mcpServers",
    ]

    private static func decodeDeclaration(_ value: JSONValue, path: String, warnings: inout [WireWarning]) -> WireTool {
        guard case .object(let object) = value, case .string(let name)? = object["name"] else {
            warnings.append(WireWarning(.opaqueContent, "function declaration without `name` kept as opaque", path: path))
            return .opaque(WireOpaque(protocol: .gemini, value: ["functionDeclarations": [value]]))
        }
        var reader = FieldReader(object, path: path)
        _ = reader.raw("name")
        var tool = WireFunctionTool(name: name)
        tool.description = object["description"]?.stringValue
        if tool.description != nil { _ = reader.raw("description") }
        for key in ["parametersJsonSchema", "parameters"] {
            if let schema = object[key], !schema.isNull, tool.parameters == nil {
                _ = reader.raw(key)
                tool.parameters = schema
                tool.sourceKey = key
            }
        }
        tool.extra = reader.remaining(warnings: &warnings)
        return .function(tool)
    }

    private static func decodeToolConfig(_ config: JSONObject, into request: inout WireRequest, warnings: inout [WireWarning]) {
        var rest = config
        if case .object(let calling)? = config["functionCallingConfig"] {
            rest["functionCallingConfig"] = nil
            let names = calling["allowedFunctionNames"]?.arrayValue?.compactMap(\.stringValue)
            let keys = Set(calling.keys)
            var choice: WireToolChoice?
            switch calling["mode"]?.stringValue {
            case "AUTO"? where keys == ["mode"]: choice = .auto
            case "NONE"? where keys == ["mode"]: choice = WireToolChoice.none
            case "ANY"? where keys == ["mode"]: choice = .required
            case "ANY"? where keys == ["mode", "allowedFunctionNames"] && names?.count == 1
                && calling["allowedFunctionNames"]?.arrayValue?.count == 1:
                choice = .function(names![0])
            default: break
            }
            if let choice {
                request.toolChoice = choice
            } else {
                warnings.append(WireWarning(.opaqueContent, "functionCallingConfig kept as opaque", path: "toolConfig.functionCallingConfig"))
                request.toolChoice = .opaque(WireOpaque(protocol: .gemini, value: .object(calling)))
            }
        }
        if !rest.isEmpty {
            for key in rest.keys {
                warnings.append(WireWarning(.unknownField, "kept unknown field `\(key)`", path: WirePath.key("toolConfig", key)))
            }
            request.extra["toolConfig"] = .object(rest)
        }
    }

    private static func decodeGenerationConfig(
        _ config: JSONObject,
        into request: inout WireRequest,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) {
        var reader = FieldReader(config, path: "generationConfig")
        if let sequences = try reader.array("stopSequences") {
            var values: [String] = []
            for (i, value) in sequences.enumerated() {
                guard case .string(let text) = value else {
                    throw WireDecodingError(.typeMismatch(expected: "a string"), path: WirePath.index(reader.path("stopSequences"), i))
                }
                values.append(text)
            }
            request.stop = .multiple(values)
        }
        // Structured output: only the shapes other protocols can express.
        let mime = config["responseMimeType"]?.stringValue
        let schemaKeys = ["responseJsonSchema", "responseSchema"].filter { config[$0].map { !$0.isNull } ?? false }
        if mime == "application/json", schemaKeys.count <= 1 {
            _ = reader.raw("responseMimeType")
            var format = WireResponseFormat(kind: .jsonObject)
            if let key = schemaKeys.first {
                format.kind = .jsonSchema
                format.schema = reader.raw(key)
                format.sourceKey = key
            }
            request.responseFormat = format
        } else if mime == "text/plain", schemaKeys.isEmpty {
            _ = reader.raw("responseMimeType")
            request.responseFormat = WireResponseFormat(kind: .text)
        }
        request.candidateCount = try reader.int("candidateCount")
        request.maxOutputTokens = try reader.int("maxOutputTokens")
        request.temperature = try reader.number("temperature")
        request.topP = try reader.number("topP")
        request.topK = try reader.number("topK")
        request.seed = try reader.int("seed")
        request.presencePenalty = try reader.number("presencePenalty")
        request.frequencyPenalty = try reader.number("frequencyPenalty")
        if let thinking = try reader.object("thinkingConfig") {
            var inner = FieldReader(thinking, path: reader.path("thinkingConfig"))
            var reasoning = WireReasoningConfig()
            reasoning.visible = try inner.bool("includeThoughts")
            reasoning.budgetTokens = try inner.int("thinkingBudget")
            reasoning.effort = try inner.string("thinkingLevel")
            reasoning.extra = inner.remaining(warnings: &warnings)
            request.reasoning = reasoning
        }
        let rest = reader.remaining(warnings: &warnings)
        if !rest.isEmpty { request.extra["generationConfig"] = .object(rest) }
    }

    /// Encodes a request body for a Gemini upstream (send it to
    /// ``path(model:stream:)``).
    ///
    /// Bags and opaque content are written only if `request.source` is
    /// Gemini. For another source the builder also restructures the
    /// conversation the way Gemini requires:
    /// - leading `system`/`developer` messages join ``WireRequest/instructions``
    ///   in `systemInstruction`; later ones become user text (with a warning);
    /// - tool results (Chat `tool` messages, Responses items) become
    ///   `functionResponse` parts of user turns, named after their call;
    /// - consecutive turns of the same role are merged and empty turns and
    ///   empty or whitespace-only text parts dropped.
    ///
    /// Signatures are written when ``GeminiReplay`` accepts their origin
    /// (``GeminiRequestOptions/trustedSignatureOrigins``); reasoning it does
    /// not accept is dropped. Function calls left without a signature get
    /// ``GeminiRequestOptions/missingSignatureFallback``. Synthesized ids are
    /// omitted (see ``GeminiToolID``).
    public static func buildRequest(_ request: WireRequest, options: GeminiRequestOptions = .init()) -> WireEncoded {
        var warnings: [WireWarning] = []
        let include = request.source == .gemini
        let context = GeminiEncode.Context(include: include, trusted: options.trustedSignatureOrigins, keepUnsignedReasoning: false)
        var object = JSONObject()

        // Function names by call id, for results that do not name theirs.
        var callNames: [String: String] = [:]
        for message in request.messages {
            for case .toolCall(let call) in message.parts { callNames[call.id] = call.name }
        }

        var systemParts = request.instructions
        var systemForm = request.instructionsForm
        var turns = GeminiTurns(context: context, callNames: callNames, fallback: options.missingSignatureFallback)
        var leading = true
        for (i, message) in request.messages.enumerated() {
            let path = WirePath.index("contents", i)
            if leading, message.role == .system || message.role == .developer {
                systemForm = systemParts == nil ? message.contentForm : .parts
                systemParts = (systemParts ?? []) + message.parts
                var unused = JSONObject()
                appendExtra(message.extra, to: &unused, include: false, path: path, warnings: &warnings)
                continue
            }
            leading = false
            turns.add(message, path: path, warnings: &warnings)
        }
        object["contents"] = .array(turns.finish(warnings: &warnings))

        if let parts = systemParts {
            var encoded: [JSONValue] = []
            for (i, part) in parts.enumerated() {
                let path = WirePath.index("systemInstruction.parts", i)
                if !include, !part.isText {
                    warnings.append(WireWarning(.droppedContent, "only text can appear in systemInstruction", path: path))
                    continue
                }
                if let value = GeminiEncode.part(part, context: context, path: path, warnings: &warnings) { encoded.append(value) }
            }
            if include, systemForm == .string, encoded.count <= 1, request.instructionsExtra.isEmpty {
                object["systemInstruction"] = .string(encoded.first?["text"]?.stringValue ?? "")
            } else if !(encoded.isEmpty && !include) {
                var system = JSONObject()
                if !(include && systemForm == .absent && encoded.isEmpty) { system["parts"] = .array(encoded) }
                appendExtra(request.instructionsExtra, to: &system, include: include, path: "systemInstruction", warnings: &warnings)
                object["systemInstruction"] = .object(system)
            }
        }
        if let tools = request.tools {
            object["tools"] = .array(encodeTools(tools, include: include, parametersKey: options.parametersKey, warnings: &warnings))
        }
        var toolConfig = JSONObject()
        if let choice = request.toolChoice, let calling = encodeToolChoice(choice, warnings: &warnings) {
            toolConfig["functionCallingConfig"] = calling
        }
        mergeNested("toolConfig", into: &toolConfig, request: request, include: include, warnings: &warnings)
        if !toolConfig.isEmpty { object["toolConfig"] = .object(toolConfig) }
        var config = encodeGenerationConfig(request, include: include, warnings: &warnings)
        mergeNested("generationConfig", into: &config, request: request, include: include, warnings: &warnings)
        if !config.isEmpty { object["generationConfig"] = .object(config) }

        dropUnsupported(request, warnings: &warnings)
        var extra = request.extra
        for key in nestedBagKeys { extra[key] = nil }
        appendExtra(extra, to: &object, include: include, path: "", warnings: &warnings)
        return WireEncoded(json: .object(object), warnings: warnings)
    }

    /// Merges the partial object kept under `key` in the request bag.
    private static func mergeNested(
        _ key: String,
        into object: inout JSONObject,
        request: WireRequest,
        include: Bool,
        warnings: inout [WireWarning],
    ) {
        guard let value = request.extra[key] else { return }
        if case .object(let partial) = value {
            appendExtra(partial, to: &object, include: include, path: key, warnings: &warnings)
        } else {
            appendExtra([key: value], to: &object, include: false, path: "", warnings: &warnings)
        }
    }

    private static func dropUnsupported(_ request: WireRequest, warnings: inout [WireWarning]) {
        func drop(_ present: Bool, _ field: String) {
            if present { warnings.append(WireWarning(.droppedField, "Gemini has no `\(field)`", path: field)) }
        }
        drop(request.parallelToolCalls == false, "parallel_tool_calls")
        drop(request.serviceTier != nil, "service_tier")
        drop(request.store != nil, "store")
        drop(request.user != nil, "user")
        drop(request.promptCacheKey != nil, "prompt_cache_key")
        drop(request.safetyIdentifier != nil, "safety_identifier")
        drop(request.verbosity != nil, "verbosity")
        // Gemini streams always report usage; only unknown options matter.
        drop(!(request.streamOptions?.extra.isEmpty ?? true), "stream_options")
    }

    private static func encodeTools(
        _ tools: [WireTool],
        include: Bool,
        parametersKey: String?,
        warnings: inout [WireWarning],
    ) -> [JSONValue] {
        var items: [JSONValue] = []
        var declarations: [JSONValue] = []
        func flush() {
            if !declarations.isEmpty { items.append(["functionDeclarations": .array(declarations)]) }
            declarations = []
        }
        for (i, tool) in tools.enumerated() {
            let path = WirePath.index("tools", i)
            switch tool {
            case .function(let function):
                var object = JSONObject()
                object["name"] = .string(function.name)
                if let value = function.description { object["description"] = .string(value) }
                if let schema = function.parameters {
                    let key = parametersKey ?? (include && function.sourceKey == "parameters" ? "parameters" : "parametersJsonSchema")
                    object[key] = schema
                }
                if function.strict == true {
                    warnings.append(WireWarning(.droppedField, "Gemini function declarations have no `strict`", path: WirePath.key(path, "strict")))
                }
                appendExtra(function.extra, to: &object, include: include, path: path, warnings: &warnings)
                appendExtra(function.envelopeExtra, to: &object, include: include, path: path, warnings: &warnings)
                declarations.append(.object(object))
            case .opaque(let opaque):
                guard opaque.protocol == .gemini else {
                    warnings.append(WireWarning(.droppedContent, "tool from \(opaque.protocol.rawValue) cannot be carried", path: path))
                    continue
                }
                flush()
                items.append(opaque.value)
            }
        }
        flush()
        return items
    }

    private static func encodeToolChoice(_ choice: WireToolChoice, warnings: inout [WireWarning]) -> JSONValue? {
        switch choice {
        case .auto: return ["mode": "AUTO"]
        case .none: return ["mode": "NONE"]
        case .required: return ["mode": "ANY"]
        case .function(let name): return ["mode": "ANY", "allowedFunctionNames": [.string(name)]]
        case .opaque(let opaque):
            guard opaque.protocol == .gemini else {
                warnings.append(WireWarning(.droppedField, "tool_choice from \(opaque.protocol.rawValue) cannot be carried", path: "toolConfig"))
                return nil
            }
            return opaque.value
        }
    }

    private static func encodeGenerationConfig(_ request: WireRequest, include: Bool, warnings: inout [WireWarning]) -> JSONObject {
        var config = JSONObject()
        if let stop = request.stop { config["stopSequences"] = .array(stop.sequences.map { .string($0) }) }
        if let format = request.responseFormat {
            switch format.kind {
            case .jsonObject, .jsonSchema:
                config["responseMimeType"] = "application/json"
                if let schema = format.schema {
                    let key = include && format.sourceKey == "responseSchema" ? "responseSchema" : "responseJsonSchema"
                    config[key] = schema
                }
                if format.description != nil {
                    warnings.append(WireWarning(.droppedField, "Gemini response schemas have no description", path: "response_format"))
                }
            case .text:
                config["responseMimeType"] = "text/plain"
            default:
                warnings.append(WireWarning(.droppedField, "response format `\(format.kind.rawValue)` cannot be carried", path: "response_format"))
            }
            if !format.extra.isEmpty {
                var unused = JSONObject()
                appendExtra(format.extra, to: &unused, include: false, path: "response_format", warnings: &warnings)
            }
        }
        if let value = request.candidateCount { config["candidateCount"] = .number(JSONNumber(value)) }
        if let value = request.maxOutputTokens { config["maxOutputTokens"] = .number(JSONNumber(value)) }
        if let value = request.temperature { config["temperature"] = .number(value) }
        if let value = request.topP { config["topP"] = .number(value) }
        if let value = request.topK { config["topK"] = .number(value) }
        if let value = request.seed { config["seed"] = .number(JSONNumber(value)) }
        if let value = request.presencePenalty { config["presencePenalty"] = .number(value) }
        if let value = request.frequencyPenalty { config["frequencyPenalty"] = .number(value) }
        if let reasoning = request.reasoning, let thinking = encodeThinking(reasoning, include: include, warnings: &warnings) {
            config["thinkingConfig"] = thinking
        }
        return config
    }

    /// `thinkingConfig`. From another protocol: thinking that is enabled, or
    /// a Responses summary request, asks for thoughts (`includeThoughts`),
    /// since those clients expect to see reasoning; `enabled: false` and
    /// effort `none` become a zero budget; effort `xhigh` is `high`.
    private static func encodeThinking(_ reasoning: WireReasoningConfig, include: Bool, warnings: inout [WireWarning]) -> JSONValue? {
        var object = JSONObject()
        var visible = reasoning.visible
        var budget = reasoning.budgetTokens
        var level = reasoning.effort
        if !include {
            if visible == nil, reasoning.enabled == true || reasoning.summary != nil { visible = true }
            if budget == nil, reasoning.enabled == false || level == "none" {
                budget = 0
                level = nil
            }
            if level == "none" { level = nil }
            if level == "xhigh" { level = "high" }
        } else if reasoning.enabled != nil {
            warnings.append(WireWarning(.droppedField, "Gemini thinking has no on/off switch", path: "thinkingConfig"))
        }
        if let visible { object["includeThoughts"] = .bool(visible) }
        if let budget { object["thinkingBudget"] = .number(JSONNumber(budget)) }
        if let level { object["thinkingLevel"] = .string(level) }
        appendExtra(reasoning.extra, to: &object, include: include, path: "generationConfig.thinkingConfig", warnings: &warnings)
        if reasoning.summary != nil, include {
            warnings.append(WireWarning(.droppedField, "Gemini thinking has no summary setting", path: "thinkingConfig"))
        }
        return object.isEmpty ? nil : .object(object)
    }
}

/// Assembles wire messages into Gemini `contents` (see
/// ``GeminiCodec/buildRequest(_:options:)`` for the rules).
private struct GeminiTurns {
    struct Turn {
        var role: String
        var parts: [JSONValue]
        var extra: JSONObject
        var absentParts: Bool
    }

    let context: GeminiEncode.Context
    let callNames: [String: String]
    let fallback: String?
    var turns: [Turn] = []

    init(context: GeminiEncode.Context, callNames: [String: String], fallback: String?) {
        self.context = context
        self.callNames = callNames
        self.fallback = fallback
    }

    mutating func add(_ message: WireMessage, path: String, warnings: inout [WireWarning]) {
        let partsPath = WirePath.key(path, "parts")
        if context.include, message.role != .item {
            // Same protocol: one turn, as it came.
            var parts: [JSONValue] = []
            for (i, part) in message.parts.enumerated() {
                let partPath = WirePath.index(partsPath, i)
                if let value = GeminiEncode.part(part, context: context, path: partPath, callNames: callNames, warnings: &warnings) {
                    parts.append(value)
                }
            }
            let role = switch message.role {
            case .assistant: "model"
            default: message.role.rawValue
            }
            turns.append(Turn(role: role, parts: parts, extra: message.extra, absentParts: message.contentForm == .absent && parts.isEmpty))
            return
        }
        // Bags of another protocol's message have no place; warn once here.
        if !context.include {
            var unused = JSONObject()
            appendExtra(message.extra, to: &unused, include: false, path: path, warnings: &warnings)
        }
        let role: String
        switch message.role {
        case .user, .tool, .item: role = "user"
        case .assistant: role = "model"
        case .system, .developer:
            warnings.append(WireWarning(.lossyConversion, "a `\(message.role)` message after the conversation began sent as user text", path: path))
            role = "user"
        default:
            warnings.append(WireWarning(.lossyConversion, "role `\(message.role)` sent as a user turn", path: path))
            role = "user"
        }
        for (i, part) in message.parts.enumerated() {
            let partPath = WirePath.index(partsPath, i)
            // Calls are the model's and results the user's, whatever the
            // message (Responses items, Chat `tool` messages).
            var partRole = role
            switch (message.role, part) {
            case (_, .toolResult):
                partRole = "user"
            case (.item, .toolCall):
                partRole = "model"
            case (.item, _), (.tool, _):
                warnings.append(WireWarning(.droppedContent, "content of a `\(message.role)` message cannot be carried", path: partPath))
                continue
            case (_, .toolCall), (_, .reasoning):
                if role == "user" {
                    warnings.append(WireWarning(.droppedContent, "model output in a user turn cannot be carried", path: partPath))
                    continue
                }
            default:
                break
            }
            guard let value = GeminiEncode.part(part, context: context, path: partPath, callNames: callNames, warnings: &warnings) else {
                continue
            }
            if let last = turns.last, last.role == partRole {
                turns[turns.count - 1].parts.append(value)
            } else {
                turns.append(Turn(role: partRole, parts: [value], extra: [:], absentParts: false))
            }
        }
    }

    func finish(warnings: inout [WireWarning]) -> [JSONValue] {
        var output = turns
        if !context.include {
            // Turns were merged as parts arrived; drop empty and
            // whitespace-only text parts and the turns they leave empty,
            // then merge again.
            var merged: [Turn] = []
            for var turn in output {
                turn.parts.removeAll { part in
                    part.objectValue?.count == 1 && part["text"]?.stringValue?.allSatisfy(\.isWhitespace) == true
                }
                guard !turn.parts.isEmpty else { continue }
                if let last = merged.last, last.role == turn.role {
                    merged[merged.count - 1].parts += turn.parts
                } else {
                    merged.append(turn)
                }
            }
            output = merged
        }
        return output.map { turn in
            var object = JSONObject()
            if !turn.absentParts { object["parts"] = .array(signed(turn)) }
            object["role"] = .string(turn.role)
            var ignored: [WireWarning] = []
            appendExtra(turn.extra, to: &object, include: true, path: "", warnings: &ignored)
            return .object(object)
        }
    }

    /// The turn's parts with ``fallback`` on function calls that need a
    /// signature: in a model turn, every call before the first signed one.
    private func signed(_ turn: Turn) -> [JSONValue] {
        guard let fallback, turn.role == "model" else { return turn.parts }
        var signedCall = false
        return turn.parts.map { part in
            guard case .object(var object) = part, object["functionCall"] != nil else { return part }
            if object["thoughtSignature"] != nil {
                signedCall = true
                return part
            }
            guard !signedCall else { return part }
            object["thoughtSignature"] = .string(fallback)
            return .object(object)
        }
    }
}

// MARK: - Non-streaming responses

/// Values a response encoder needs when the wire response lacks them.
package struct GeminiResponseDefaults: Hashable, Sendable {
    package var id: String
    package var model: String
    /// Systems whose signatures the client may be given back (they return
    /// in its next request). Others are dropped; their reasoning text is kept
    /// as thought parts.
    package var trustedSignatureOrigins: Set<WireSystemID>

    package init(id: String, model: String, trustedSignatureOrigins: Set<WireSystemID> = ["gemini"]) {
        self.id = id
        self.model = model
        self.trustedSignatureOrigins = trustedSignatureOrigins
    }
}

extension GeminiCodec {
    /// Top-level reply keys the decoders read.
    static let knownResponseKeys: Set<String> = ["candidates", "promptFeedback", "usageMetadata", "modelVersion", "responseId"]

    /// Decodes a non-streaming upstream reply.
    ///
    /// - The first candidate is the reply (others are dropped with a
    ///   warning); its unknown keys (`safetyRatings`, `citationMetadata`,
    ///   `groundingMetadata`, `avgLogprobs`…) and `promptFeedback` go to
    ///   ``WireResponse/choiceExtra``; `index` is dropped.
    /// - `STOP` with function calls is ``WireFinishReason/Unified/toolCalls``;
    ///   a prompt blocked before any candidate (`promptFeedback.blockReason`)
    ///   is ``WireFinishReason/Unified/contentFilter`` without a raw value.
    /// - Calls without `id` get `unladen_gc_<responseId>_<n>`.
    /// - Media parts are kept opaque, as streams deliver them.
    ///
    /// - Parameter origin: the system id stamped on reasoning and on
    ///   signatures (`"gemini"` for the Gemini API; Vertex endpoints pass
    ///   their own).
    public static func parseResponse(
        _ body: some Collection<UInt8>,
        origin: WireSystemID? = "gemini",
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        try parseResponse(JSONValue.parseWire(body), origin: origin)
    }

    public static func parseResponse(
        _ json: JSONValue,
        origin: WireSystemID? = "gemini",
    ) throws(WireDecodingError) -> WireDecoded<WireResponse> {
        guard case .object(let object) = json else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: "")
        }
        var warnings: [WireWarning] = []
        var reader = FieldReader(object, path: "")
        let candidates = try reader.array("candidates") ?? []
        var usage: WireUsage?
        if let object = try reader.object("usageMetadata") { usage = try GeminiUsage.decode(object, path: "usageMetadata") }
        let model = try reader.string("modelVersion")
        let id = try reader.string("responseId")
        var response = WireResponse(message: WireMessage(role: .assistant, parts: []), id: id, model: model, usage: usage, source: .gemini)
        if let first = candidates.first {
            guard case .object(let candidate) = first else {
                throw WireDecodingError(.typeMismatch(expected: "an object"), path: "candidates[0]")
            }
            var inner = FieldReader(candidate, path: "candidates[0]")
            _ = try inner.int("index")
            if let content = try inner.object("content") {
                var contentReader = FieldReader(content, path: "candidates[0].content")
                _ = try contentReader.string("role")
                var parts = try GeminiDecode.parts(
                    contentReader.raw("parts"), path: contentReader.path("parts"), origin: origin, isReply: true, warnings: &warnings,
                )
                var calls = 0
                var seed = GeminiToolID.ReplySeed()
                for i in parts.indices {
                    seed.add(parts[i])
                    guard case .toolCall(var call) = parts[i] else { continue }
                    if call.idSynthesized { call.id = GeminiToolID.reply(responseID: id, call: calls, seed: seed) }
                    calls += 1
                    parts[i] = .toolCall(call)
                }
                response.message = WireMessage(role: .assistant, parts: parts, extra: contentReader.remaining(warnings: &warnings))
            }
            if let reason = try inner.string("finishReason") {
                let hasCalls = response.message.parts.contains { if case .toolCall = $0 { true } else { false } }
                response.finishReason = GeminiFinish.decode(reason, hasToolCalls: hasCalls)
            }
            var ignored: [WireWarning] = []
            response.choiceExtra = inner.remaining(warnings: &ignored)
        }
        if candidates.count > 1 {
            warnings.append(WireWarning(.droppedContent, "only the first of \(candidates.count) candidates is kept", path: "candidates"))
        }
        if let feedback = reader.raw("promptFeedback") {
            response.choiceExtra["promptFeedback"] = feedback
            if candidates.isEmpty, feedback["blockReason"] != nil { response.finishReason = GeminiFinish.blockedPrompt }
        }
        response.extra = reader.remaining(warnings: &warnings)
        return WireDecoded(value: response, warnings: warnings)
    }

    /// Encodes a non-streaming reply for a Gemini client.
    ///
    /// Tool results cannot appear; reasoning whose signature the client may
    /// not have keeps its text as a thought part. Usage is always written
    /// for another protocol's reply (with a computed total).
    package static func encodeResponse(_ response: WireResponse, defaults: GeminiResponseDefaults) -> WireEncoded {
        var warnings: [WireWarning] = []
        let include = response.source == .gemini
        let context = GeminiEncode.Context(include: include, trusted: defaults.trustedSignatureOrigins, keepUnsignedReasoning: true)
        var parts: [JSONValue] = []
        for (i, part) in response.message.parts.enumerated() {
            let path = WirePath.index("candidates[0].content.parts", i)
            if case .toolResult = part {
                warnings.append(WireWarning(.droppedContent, "tool results cannot appear in a reply", path: path))
                continue
            }
            if let value = GeminiEncode.part(part, context: context, path: path, warnings: &warnings) { parts.append(value) }
        }
        let object = GeminiChunk.make(
            parts: parts, contentExtra: response.message.extra, reason: response.finishReason, writeReason: true,
            choiceExtra: response.choiceExtra, usage: response.usage, include: include,
            id: response.id ?? defaults.id, model: response.model ?? defaults.model, extra: response.extra, warnings: &warnings,
        )
        return WireEncoded(json: .object(object), warnings: warnings)
    }
}

/// Builds one `GenerateContentResponse` object (a whole reply or a chunk).
enum GeminiChunk {
    static func make(
        parts: [JSONValue],
        contentExtra: JSONObject = [:],
        reason: WireFinishReason?,
        writeReason: Bool,
        choiceExtra: JSONObject,
        usage: WireUsage?,
        include: Bool,
        id: String,
        model: String,
        extra: JSONObject,
        warnings: inout [WireWarning],
    ) -> JSONObject {
        var object = JSONObject()
        var candidateExtra = choiceExtra
        var topLevel = JSONObject()
        for key in GeminiFinish.topLevelKeys {
            if let value = candidateExtra.removeValue(forKey: key) { topLevel[key] = value }
        }
        let blocked = include && writeReason && GeminiFinish.isBlockedPrompt(choiceExtra, reason: reason, hasParts: !parts.isEmpty)
        if !blocked {
            var content = JSONObject()
            content["parts"] = .array(parts)
            content["role"] = "model"
            appendExtra(contentExtra, to: &content, include: include, path: "candidates[0].content", warnings: &warnings)
            var candidate = JSONObject()
            candidate["content"] = .object(content)
            if writeReason { candidate["finishReason"] = .string(GeminiFinish.encode(reason, sameProtocol: include)) }
            appendExtra(candidateExtra, to: &candidate, include: include, path: "candidates[0]", warnings: &warnings)
            object["candidates"] = [.object(candidate)]
        }
        if include {
            for (key, value) in topLevel { object[key] = value }
        } else {
            var unused = JSONObject()
            appendExtra(topLevel, to: &unused, include: false, path: "", warnings: &warnings)
        }
        if let usage {
            object["usageMetadata"] = GeminiUsage.encode(usage, include: include)
        } else if writeReason, !include {
            object["usageMetadata"] = GeminiUsage.encode(WireUsage(), include: false)
        }
        object["modelVersion"] = .string(model)
        object["responseId"] = .string(id)
        appendExtra(extra, to: &object, include: include, path: "", warnings: &warnings)
        return object
    }
}
