extension WireTransforms {
    /// Empties every unknown-field bag of `request` (top level, messages,
    /// parts, tools, nested settings), one warning per non-empty bag. For a
    /// Profile with ``Profile/strictUnknownFields``; only meaningful when the
    /// target is the request's source protocol (other encoders drop bags
    /// anyway).
    public static func stripUnknownFields(_ request: inout WireRequest, warnings: inout [WireWarning]) {
        func clear(_ bag: inout JSONObject, _ path: String) {
            let keys = bag.keys.enumerated().filter { !bag.values[$0.offset].isNull }.map(\.element)
            if !keys.isEmpty {
                let list = keys.map { "`\($0)`" }.joined(separator: ", ")
                warnings.append(WireWarning(.droppedField, "upstream rejects unknown fields; dropped \(list)", path: path))
            }
            bag = [:]
        }
        func clearParts(_ parts: inout [WirePart], _ path: String) {
            for i in parts.indices {
                let partPath = WirePath.index(path, i)
                switch parts[i] {
                case .text(var value): clear(&value.extra, partPath); parts[i] = .text(value)
                case .image(var value): clear(&value.extra, partPath); parts[i] = .image(value)
                case .file(var value): clear(&value.extra, partPath); parts[i] = .file(value)
                case .reasoning(var value): clear(&value.extra, partPath); parts[i] = .reasoning(value)
                case .toolCall(var value): clear(&value.extra, partPath); parts[i] = .toolCall(value)
                case .refusal(var value): clear(&value.extra, partPath); parts[i] = .refusal(value)
                case .toolResult(var value):
                    clear(&value.extra, partPath)
                    clearParts(&value.content, WirePath.key(partPath, "content"))
                    parts[i] = .toolResult(value)
                case .opaque:
                    break
                }
            }
        }
        clear(&request.extra, "")
        clear(&request.instructionsExtra, "instructions")
        if var parts = request.instructions {
            clearParts(&parts, "instructions")
            request.instructions = parts
        }
        for i in request.messages.indices {
            let path = WirePath.index("messages", i)
            clear(&request.messages[i].extra, path)
            clearParts(&request.messages[i].parts, WirePath.key(path, "content"))
        }
        if let tools = request.tools {
            request.tools = tools.enumerated().map { i, tool in
                guard case .function(var function) = tool else { return tool }
                clear(&function.extra, WirePath.index("tools", i))
                clear(&function.envelopeExtra, WirePath.index("tools", i))
                return .function(function)
            }
        }
        if request.streamOptions != nil { clear(&request.streamOptions!.extra, "stream_options") }
        if request.reasoning != nil { clear(&request.reasoning!.extra, "reasoning") }
        if request.responseFormat != nil { clear(&request.responseFormat!.extra, "response_format") }
    }

    /// Drops the modelled fields only OpenAI's platform defines (`store`,
    /// `service_tier`, `prompt_cache_key`, `safety_identifier`, `verbosity`),
    /// one warning each, whatever protocol the request came in. For a Profile
    /// with ``Profile/strictUnknownFields``: Mistral answers OpenCode's
    /// `store: false` with 422 `extra_forbidden` (magpie #393).
    public static func stripOpenAIPlatformFields(_ request: inout WireRequest, warnings: inout [WireWarning]) {
        func drop<Value>(_ field: inout Value?, _ name: String) {
            guard field != nil else { return }
            field = nil
            warnings.append(WireWarning(.droppedField, "upstream rejects unknown fields; dropped `\(name)`", path: name))
        }
        drop(&request.store, "store")
        drop(&request.serviceTier, "service_tier")
        drop(&request.promptCacheKey, "prompt_cache_key")
        drop(&request.safetyIdentifier, "safety_identifier")
        drop(&request.verbosity, "verbosity")
    }
}
