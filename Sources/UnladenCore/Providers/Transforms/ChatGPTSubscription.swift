// ``ProfileTransform/chatgptSubscription``, and the fingerprint of a
// conversation's opening it names the prompt cache by.

extension WireTransforms {
    /// Responses fields OpenAI's API refuses with a ChatGPT sign-in's
    /// token, when a Responses client sends them (they are unknown-field
    /// bags to the wire model).
    public static let chatgptRefusedFields = [
        "background", "conversation", "max_tool_calls", "metadata", "moderation", "multi_agent", "prompt",
        "prompt_cache_retention", "previous_response_id", "top_logprobs", "truncation",
    ]

    /// Tools OpenAI runs itself, which it will not run for a ChatGPT
    /// sign-in: a request offering one is refused whole.
    public static let chatgptHostedTools: Set<String> = [
        "image_generation", "file_search", "code_interpreter", "computer_use", "computer_use_preview", "computer", "mcp",
        "tool_search",
    ]

    /// See ``ProfileTransform/chatgptSubscription``.
    public static func chatgptSubscription(_ request: inout WireRequest, warnings: inout [WireWarning]) {
        // Nothing is stored, so each request carries the whole conversation.
        request.store = false
        if request.maxOutputTokens != nil {
            request.maxOutputTokens = nil
            warnings.append(WireWarning(.unsupportedByModel, "a ChatGPT sign-in takes no output limit", path: "max_output_tokens"))
        }
        request.safetyIdentifier = nil
        for field in chatgptRefusedFields where request.extra.removeValue(forKey: field) != nil {
            warnings.append(WireWarning(.unsupportedByModel, "a ChatGPT sign-in does not take `\(field)`", path: field))
        }
        for i in request.messages.indices where request.messages[i].role == .system {
            request.messages[i].role = .developer
        }
        if let tools = request.tools {
            let kept = tools.filter { tool in
                guard case .opaque(let opaque) = tool, let type = opaque.value["type"]?.stringValue else { return true }
                return !chatgptHostedTools.contains(type)
            }
            if kept.count != tools.count {
                warnings.append(WireWarning(.droppedContent, "a ChatGPT sign-in cannot use OpenAI's hosted tools", path: "tools"))
            }
            request.tools = kept.isEmpty ? nil : kept
            if kept.isEmpty { request.toolChoice = nil }
        }
        // OpenAI keeps a ChatGPT sign-in's prompt cache by this key.
        if request.promptCacheKey == nil, let fingerprint = request.openingFingerprint {
            request.promptCacheKey = "unladen-" + fingerprint
        }
    }
}

extension WireRequest {
    /// A hash of how the conversation opens, its instructions and first
    /// user message, which every later turn repeats: 16 hex digits, `nil`
    /// without a user message.
    public var openingFingerprint: String? {
        guard let first = messages.first(where: { $0.role == .user }) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func add(_ text: String) {
            for byte in text.utf8.prefix(16 << 10) {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0xff
            hash = hash &* 0x0000_0100_0000_01b3
        }
        for part in instructions ?? [] { if case .text(let text) = part { add(text.text) } }
        for part in first.parts { if case .text(let text) = part { add(text.text) } }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
