@_spi(Wire) import UnladenCore

/// The one thin conversion between the semantic types and the wire model:
/// pure functions, no I/O.
///
/// - Semantic → wire is lossless: every semantic field has a wire field.
/// - Wire → semantic drops unknown-field bags and opaque content (with a
///   warning) but keeps signatures, encrypted reasoning, item ids and their
///   origin in ``ReplayToken``s, so the message converts back to the same
///   wire parts.
/// - ``forTarget(_:trusted:)`` is the one policy step: it removes replay data
///   the target endpoint does not trust, before conversion.
enum WireConversion {
    /// The endpoint a request is converted for: picks the provider options
    /// that apply and where a message's cache breakpoint goes.
    struct Target {
        var apiProtocol: APIProtocol
        var system: String

        /// `options` resolved for this target, as a patch.
        func patch(_ options: ProviderOptions) -> WirePatch? {
            options.resolved(protocol: apiProtocol, system: system).map { WirePatch(protocol: apiProtocol.wire, object: $0) }
        }
    }

    // MARK: Semantic → wire

    static func request(_ request: ModelRequest, model: String, chatDialect: Bool = false) throws(UnladenError) -> WireRequest {
        var warnings: [CallWarning] = []
        return try self.request(request, model: model, target: nil, chatDialect: chatDialect, warnings: &warnings)
    }

    /// The wire request for `request`, addressed to `model`. The caller
    /// applies ``forTarget(_:trusted:)`` to the messages first.
    /// - Parameters:
    ///   - target: resolves message-, part- and tool-level provider options
    ///     (none without one) and where message breakpoints go.
    ///   - chatDialect: restore the Chat dialect data replay tokens keep
    ///     (``ReplayToken/dialect``); for Chat endpoints only, as other
    ///     encoders would report it dropped.
    ///   - warnings: breakpoints that no part can carry.
    static func request(
        _ request: ModelRequest,
        model: String,
        target: Target?,
        chatDialect: Bool = false,
        warnings: inout [CallWarning],
    ) throws(UnladenError) -> WireRequest {
        var messages: [WireMessage] = []
        for (i, message) in request.messages.enumerated() {
            messages.append(try wireMessage(message, path: "messages[\(i)]", chatDialect: chatDialect, target: target, warnings: &warnings))
        }
        var wire = WireRequest(model: model, messages: messages)
        if !request.tools.isEmpty {
            wire.tools = request.tools.map { tool in
                .function(WireFunctionTool(
                    name: tool.name, description: tool.description, parameters: tool.inputSchema, strict: tool.strict,
                    cacheControl: tool.cache?.wire, patch: target?.patch(tool.providerOptions),
                ))
            }
        }
        wire.toolChoice = request.toolChoice.map { choice in
            switch choice {
            case .auto: .auto
            case .none: .none
            case .required: .required
            case .tool(let name): .function(name)
            }
        }
        let settings = request.settings
        wire.parallelToolCalls = settings.parallelToolCalls
        wire.maxOutputTokens = settings.maxOutputTokens
        wire.temperature = try number(settings.temperature, "temperature")
        wire.topP = try number(settings.topP, "topP")
        wire.topK = settings.topK.map { JSONNumber($0) }
        wire.frequencyPenalty = try number(settings.frequencyPenalty, "frequencyPenalty")
        wire.presencePenalty = try number(settings.presencePenalty, "presencePenalty")
        wire.seed = settings.seed
        wire.stop = settings.stopSequences.map { .multiple($0) }
        wire.reasoning = settings.reasoning.map(reasoningConfig)
        wire.responseFormat = settings.responseFormat.map { format in
            switch format {
            case .text: WireResponseFormat(kind: .text)
            case .json: WireResponseFormat(kind: .jsonObject)
            case .jsonSchema(let schema, let name, let description, let strict):
                WireResponseFormat(kind: .jsonSchema, name: name, description: description, schema: schema, strict: strict)
            }
        }
        wire.user = settings.user
        wire.promptCacheKey = settings.promptCacheKey
        return wire
    }

    static func reasoningConfig(_ settings: ReasoningSettings) -> WireReasoningConfig {
        var config = WireReasoningConfig(effort: settings.effort?.rawValue, budgetTokens: settings.budgetTokens, enabled: settings.enabled)
        switch settings.visibility {
        case .hidden?: config.visible = false
        case .summary(let detail)?: config.summary = detail ?? "auto"
        case .full?: config.visible = true
        case nil: break
        }
        return config
    }

    private static func number(_ value: Double?, _ name: String) throws(UnladenError) -> JSONNumber? {
        guard let value else { return nil }
        guard let number = JSONNumber(value) else { throw .invalidRequest("`\(name)` must be finite, got \(value)") }
        return number
    }

    static func wireMessage(_ message: Message, path: String, chatDialect: Bool = false) throws(UnladenError) -> WireMessage {
        var warnings: [CallWarning] = []
        return try wireMessage(message, path: path, chatDialect: chatDialect, target: nil, warnings: &warnings)
    }

    static func wireMessage(
        _ message: Message,
        path: String,
        chatDialect: Bool,
        target: Target?,
        warnings: inout [CallWarning],
    ) throws(UnladenError) -> WireMessage {
        let role: WireRole = switch message.role {
        case .system: .system
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        }
        var parts: [WirePart] = []
        for (j, part) in message.content.enumerated() {
            let partPath = "\(path).content[\(j)]"
            guard allowed(part, in: message.role) else {
                throw .invalidRequest("\(partPath): a \(message.role.rawValue) message cannot hold \(kind(of: part))")
            }
            parts.append(try wirePart(part, path: partPath, chatDialect: chatDialect, target: target, warnings: &warnings))
        }
        if let cache = message.cache {
            // A breakpoint at the end of the message: on its last part that
            // can carry one there (Chat has no place on a tool call).
            let carriers = parts.indices.filter { i in
                switch parts[i] {
                case .text, .image, .file, .toolResult: true
                case .toolCall: target?.apiProtocol != .chatCompletions
                default: false
                }
            }
            if let last = carriers.last {
                if parts[last].cacheControl == nil { parts[last].cacheControl = cache.wire }
            } else {
                warnings.append(CallWarning(.droppedField, "cache breakpoint dropped: no part of the message can carry one", path: "\(path).cache_control"))
            }
        }
        return WireMessage(role: role, parts: parts, patch: target?.patch(message.providerOptions))
    }

    static func allowed(_ part: ContentPart, in role: Role) -> Bool {
        switch (role, part.base) {
        case (.system, .text): true
        case (.user, .text), (.user, .image), (.user, .file): true
        case (.assistant, .toolResult): false
        case (.assistant, _): true
        case (.tool, .toolResult): true
        default: false
        }
    }

    static func kind(of part: ContentPart) -> String {
        switch part.base {
        case .text: "text"
        case .image: "an image"
        case .file: "a file"
        case .reasoning: "reasoning"
        case .refusal: "a refusal"
        case .toolCall: "a tool call"
        case .toolResult: "a tool result"
        case .annotated: "an annotated part"
        }
    }

    static func wirePart(_ part: ContentPart, path: String, chatDialect: Bool = false) throws(UnladenError) -> WirePart {
        var warnings: [CallWarning] = []
        return try wirePart(part, path: path, chatDialect: chatDialect, target: nil, warnings: &warnings)
    }

    /// `part` with its ``PartOptions``: the breakpoint on the kinds that
    /// carry one (with a warning for the others), the options resolved for
    /// `target`.
    static func wirePart(
        _ part: ContentPart,
        path: String,
        chatDialect: Bool,
        target: Target?,
        warnings: inout [CallWarning],
    ) throws(UnladenError) -> WirePart {
        var wire = try plainWirePart(part.base, path: path, chatDialect: chatDialect, target: target, warnings: &warnings)
        let options = part.options
        if let cache = options.cache {
            switch wire {
            case .text, .image, .file, .toolCall, .toolResult:
                wire.cacheControl = cache.wire
            default:
                warnings.append(CallWarning(.droppedField, "cache breakpoint dropped: \(kind(of: part)) cannot carry one", path: "\(path).cache_control"))
            }
        }
        if let patch = target?.patch(options.providerOptions) {
            switch wire {
            case .text(var value): value.patch = patch; wire = .text(value)
            case .image(var value): value.patch = patch; wire = .image(value)
            case .file(var value): value.patch = patch; wire = .file(value)
            case .reasoning(var value): value.patch = patch; wire = .reasoning(value)
            case .refusal(var value): value.patch = patch; wire = .refusal(value)
            case .toolCall(var value): value.patch = patch; wire = .toolCall(value)
            case .toolResult(var value): value.patch = patch; wire = .toolResult(value)
            case .opaque: break
            }
        }
        return wire
    }

    private static func plainWirePart(
        _ part: ContentPart,
        path: String,
        chatDialect: Bool,
        target: Target?,
        warnings: inout [CallWarning],
    ) throws(UnladenError) -> WirePart {
        let bag = { (token: ReplayToken?) -> JSONObject in chatDialect ? token?.dialect ?? [:] : [:] }
        switch part {
        case .annotated(let base, _):
            return try plainWirePart(base.base, path: path, chatDialect: chatDialect, target: target, warnings: &warnings)
        case .text(let text, let token):
            return .text(WireText(text, signature: token?.signature, itemID: token?.itemID, origin: token?.origin, extra: bag(token)))
        case .image(let media):
            return .image(wireMedia(media))
        case .file(let media):
            return .file(wireMedia(media))
        case .reasoning(let text, let token):
            return .reasoning(WireReasoning(
                text: text, signature: token?.signature, encrypted: token?.encrypted, itemID: token?.itemID,
                summaryIndex: token?.summaryIndex, origin: token?.origin, sourceKey: token?.sourceKey, extra: bag(token),
            ))
        case .refusal(let text, let token):
            return .refusal(WireRefusal(text, itemID: token?.itemID, origin: token?.origin, sourceKey: token?.sourceKey))
        case .toolCall(let call):
            let token = call.replay
            return .toolCall(WireToolCall(
                id: call.id, idSynthesized: token?.idSynthesized ?? false, name: call.name, arguments: call.arguments,
                itemType: token?.itemType, itemID: token?.itemID, signature: token?.signature, origin: token?.origin,
                extra: bag(token),
            ))
        case .toolResult(let result):
            var content: [WirePart] = []
            for (k, part) in result.output.enumerated() {
                switch part.base {
                case .text, .image, .file:
                    content.append(try wirePart(part, path: "\(path).output[\(k)]", chatDialect: false, target: target, warnings: &warnings))
                default: throw .invalidRequest("\(path).output[\(k)]: a tool result cannot hold \(kind(of: part))")
                }
            }
            return .toolResult(WireToolResult(
                callID: result.callID, name: result.toolName, content: content, isError: result.isError ? true : nil,
            ))
        }
    }

    static func wireMedia(_ media: Media) -> WireMedia {
        let source: WireMediaSource = switch media.source {
        case .url(let url): .url(url)
        case .base64(let data): .base64(data)
        case .fileID(let id): .fileID(id)
        }
        return WireMedia(source: source, mediaType: media.mediaType, detail: media.detail, filename: media.filename)
    }

    // MARK: Replay policy

    /// `messages` as they may go to an endpoint trusting `trusted` systems:
    /// reasoning produced by any other system is left out (its signature or
    /// encrypted payload cannot be verified there, and its text is that
    /// model's private scratchpad); other parts keep their content and lose
    /// only the foreign signature and item id. Parts without a token (written
    /// by the caller) are untouched.
    static func forTarget(_ messages: [Message], trusted: Set<String>) -> (messages: [Message], notices: [CallWarning]) {
        var notices: [CallWarning] = []
        var output: [Message] = []
        for (i, message) in messages.enumerated() {
            var message = message
            var droppedReasoning: Set<String> = []
            var droppedSigned: Set<String> = []
            func filter(_ part: ContentPart) -> ContentPart? {
                switch part {
                case .annotated(let base, let options):
                    return filter(base).map { .annotated($0, options) }
                case .reasoning(_, let token?) where !trusted.contains(token.system):
                    droppedReasoning.insert(token.system)
                    return nil
                case .text(let text, let token?) where !trusted.contains(token.system):
                    return .text(text, replay: nil)
                case .refusal(let text, let token?) where !trusted.contains(token.system):
                    return .refusal(text, replay: nil)
                case .toolCall(var call):
                    guard let token = call.replay, !trusted.contains(token.system) else { return part }
                    if token.hasSignedData { droppedSigned.insert(token.system) }
                    call.replay = token.idSynthesized || token.itemType != nil
                        ? ReplayToken(system: token.system, idSynthesized: token.idSynthesized, itemType: token.itemType)
                        : nil
                    return .toolCall(call)
                default:
                    return part
                }
            }
            message.content = message.content.compactMap(filter)
            for system in droppedReasoning.sorted() {
                notices.append(CallWarning(.replayDataDropped, "reasoning from `\(system)` left out: this endpoint cannot verify it", path: "messages[\(i)]"))
            }
            for system in droppedSigned.sorted() {
                notices.append(CallWarning(.replayDataDropped, "tool call signatures from `\(system)` left out", path: "messages[\(i)]"))
            }
            output.append(message)
        }
        return (output, notices)
    }

    // MARK: Wire → semantic

    /// The semantic form of a reply's assistant turn from the endpoint
    /// system `system`. Opaque content is left out with a warning.
    static func message(_ wire: WireMessage, system: String, warnings: inout [CallWarning]) -> Message {
        var content: [ContentPart] = []
        for (i, part) in wire.parts.enumerated() {
            if let part = self.part(part, system: system) {
                content.append(part)
            } else {
                warnings.append(CallWarning(.opaqueContent, "provider content Unladen does not model was left out of the message", path: "content[\(i)]"))
            }
        }
        let role: Role = switch wire.role {
        case .system, .developer: .system
        case .assistant: .assistant
        case .tool: .tool
        default: .user
        }
        return Message(role: role, content: content)
    }

    static func part(_ part: WirePart, system: String) -> ContentPart? {
        switch part {
        case .text(let text):
            return .text(text.text, replay: token(
                system: system, signature: text.signature, itemID: text.itemID, origin: text.origin, dialect: dialect(text.extra),
            ))
        case .image(let media):
            return .image(self.media(media))
        case .file(let media):
            return .file(self.media(media))
        case .reasoning(let reasoning):
            // Always tokenized: the producing system decides where it may go.
            return .reasoning(reasoning.text, replay: ReplayToken(
                system: system, signature: reasoning.signature, encrypted: reasoning.encrypted, itemID: reasoning.itemID,
                origin: reasoning.origin, summaryIndex: reasoning.summaryIndex, sourceKey: reasoning.sourceKey,
                dialect: dialect(reasoning.extra),
            ))
        case .refusal(let refusal):
            return .refusal(refusal.text, replay: token(system: system, itemID: refusal.itemID, origin: refusal.origin, sourceKey: refusal.sourceKey))
        case .toolCall(let call):
            return .toolCall(toolCall(call, system: system))
        case .toolResult(let result):
            return .toolResult(ToolResult(
                callID: result.callID, toolName: result.name,
                output: result.content.compactMap { self.part($0, system: system) }, isError: result.isError ?? false,
            ))
        case .opaque:
            return nil
        }
    }

    static func toolCall(_ call: WireToolCall, system: String) -> ToolCall {
        ToolCall(
            id: call.id, name: call.name, arguments: call.arguments,
            replay: token(
                system: system, signature: call.signature, itemID: call.itemID, origin: call.origin,
                idSynthesized: call.idSynthesized, itemType: call.itemType, dialect: dialect(call.extra),
            ),
        )
    }

    /// A token if there is anything to replay.
    static func token(
        system: String,
        signature: String? = nil,
        itemID: String? = nil,
        origin: String? = nil,
        sourceKey: String? = nil,
        idSynthesized: Bool = false,
        itemType: String? = nil,
        dialect: JSONObject? = nil,
    ) -> ReplayToken? {
        guard signature != nil || itemID != nil || origin != nil || sourceKey != nil || idSynthesized || itemType != nil || dialect != nil
        else { return nil }
        return ReplayToken(
            system: system, signature: signature, itemID: itemID, origin: origin,
            sourceKey: sourceKey, idSynthesized: idSynthesized, itemType: itemType, dialect: dialect,
        )
    }

    /// The bag keys a Chat replay needs (``ReplayToken/dialect``), `nil` if none.
    static func dialect(_ extra: JSONObject) -> JSONObject? {
        var kept = JSONObject()
        for key in ChatCompletionsCodec.replayBagKeys { kept[key] = extra[key] }
        return kept.isEmpty ? nil : kept
    }

    static func media(_ media: WireMedia) -> Media {
        let source: Media.Source = switch media.source {
        case .url(let url): .url(url)
        case .base64(let data): .base64(data)
        case .fileID(let id): .fileID(id)
        }
        return Media(source, mediaType: media.mediaType, filename: media.filename, detail: media.detail)
    }

    static func response(_ wire: WireResponse, system: String, warnings: [CallWarning]) -> ModelResponse {
        var warnings = warnings
        var message = message(wire.message, system: system, warnings: &warnings)
        message.role = .assistant
        return ModelResponse(
            message: message,
            finishReason: finishReason(wire.finishReason),
            usage: usage(wire.usage),
            warnings: warnings,
            metadata: ResponseMetadata(id: wire.id, model: wire.model, created: wire.created),
        )
    }

    static func finishReason(_ wire: WireFinishReason?) -> FinishReason {
        guard let wire else { return FinishReason(.other) }
        let kind: FinishReason.Kind = switch wire.unified {
        case .stop: .stop
        case .length: .length
        case .toolCalls: .toolCalls
        case .contentFilter: .contentFilter
        case .error: .error
        case .other: .other
        }
        return FinishReason(kind, raw: wire.raw)
    }

    static func usage(_ wire: WireUsage?) -> Usage {
        guard let wire else { return Usage() }
        return Usage(
            inputTokens: wire.inputTokens, outputTokens: wire.outputTokens, totalTokens: wire.totalTokens,
            cachedInputTokens: wire.cachedInputTokens, cacheWriteTokens: wire.cacheWriteTokens, reasoningTokens: wire.reasoningTokens,
        )
    }

    static func warning(_ wire: WireWarning) -> CallWarning {
        CallWarning(CallWarning.Code(rawValue: wire.code.rawValue), wire.message, path: wire.path)
    }

    // MARK: Provider options

    /// `body` with the options for `protocol` and then `system` deep-merged
    /// into its top level (see ``ProviderOptions``).
    static func merge(_ options: ProviderOptions, into body: JSONValue, protocol: APIProtocol, system: String) -> JSONValue {
        var body = body
        var keys = [`protocol`.rawValue]
        if system != `protocol`.rawValue { keys.append(system) }
        for key in keys {
            if let patch = options[key] { body = deepMerge(body, .object(patch)) }
        }
        return body
    }

    /// `patch` over `base`: objects merge key by key, `null` removes a key,
    /// anything else replaces.
    static func deepMerge(_ base: JSONValue?, _ patch: JSONValue) -> JSONValue {
        guard case .object(let patchObject) = patch else { return patch }
        var object = base?.objectValue ?? [:]
        for (key, value) in patchObject {
            if value.isNull {
                object.removeValue(forKey: key)
            } else {
                object[key] = deepMerge(object[key], value)
            }
        }
        return .object(object)
    }
}
