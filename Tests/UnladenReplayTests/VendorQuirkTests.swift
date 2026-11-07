import Foundation
import HTTPTypes
import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

/// Layer B, by hand: what each vendor's preset must do to a request, where
/// the rule comes from a recorded rejection or acceptance (cited per test).
/// Requests start from recorded traffic (a real client's or a real
/// conversation's) wherever one fits.
@Suite struct VendorQuirkTests {
    let registry = ProviderRegistry.builtIn

    /// The recorded request of `id`, decoded as its client sent it.
    func recordedRequest(_ id: String) throws -> WireRequest {
        let recording = Recording.named(id)
        return try Codecs.parseRequest(
            try #require(recording.requestBytes), as: recording.wire,
            model: recording.model ?? "replay-model", stream: recording.isStream,
        ).value
    }

    /// `request` as `reference` would be sent it.
    func prepare(
        _ request: WireRequest, for reference: String, preferring: APIProtocol? = nil, stream: Bool = false,
    ) throws -> (http: HTTPRequest, body: JSONValue, warnings: [WireWarning]) {
        let target = try registry.resolve(reference, preferring: preferring)
        let call = UpstreamCall(target: target, apiKey: "test-key", transport: MockTransport(chunks: []))
        let prepared = try call.prepare(request, stream: stream)
        return (prepared.http, try JSONValue(parsing: prepared.body), prepared.warnings)
    }

    /// Every string anywhere in `value`, for "nothing of X leaked" checks.
    func strings(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let items): items.flatMap(strings)
        case .object(let object): object.values.flatMap(strings)
        default: []
        }
    }

    func keys(_ value: JSONValue) -> Set<String> {
        switch value {
        case .array(let items): items.reduce(into: Set()) { $0.formUnion(keys($1)) }
        case .object(let object): object.reduce(into: Set(object.keys)) { $0.formUnion(keys($1.value)) }
        default: []
        }
    }

    // MARK: DeepSeek

    /// DeepSeek thinking mode rejects an assistant tool turn without
    /// `reasoning_content` (pydantic-ai `test_deepseek_field_mode_thinking_backfill`,
    /// magpie `deepseek_anthropic_thinking_test`). A Claude conversation
    /// (signed thinking, a tool call, its result) continued on DeepSeek gets
    /// it, and none of Claude's signature.
    @Test func deepSeekGetsReasoningContentOnAClaudeToolTurn() throws {
        let claude = try recordedRequest("anthropic/tool-thinking-turn2-sonnet-5-5")
        let signature = try #require(Recording.named("anthropic/tool-thinking-turn2-sonnet-5-5").requestJSON?["messages"]?[1]?["content"]?[0]?["signature"]?.stringValue)
        let (http, body, _) = try prepare(claude, for: "deepseek/deepseek-v4-flash")
        #expect(http.path == "/v1/chat/completions")
        let messages = try #require(body["messages"]?.arrayValue)
        let assistant = try #require(messages.first { $0["role"] == "assistant" })
        #expect(assistant["tool_calls"]?[0]?["id"] == "toolu_01ScR64hSDRHQDUX7JwLinxz")
        #expect(assistant["reasoning_content"]?.stringValue?.isEmpty == false)
        #expect(messages.contains { $0["role"] == "tool" && $0["tool_call_id"] == "toolu_01ScR64hSDRHQDUX7JwLinxz" })
        #expect(!strings(body).contains(signature))
        #expect(body["max_tokens"] != nil && body["max_completion_tokens"] == nil)
    }

    /// DeepSeek reads `max_tokens` only: a client asking OpenAI's way
    /// (`max_completion_tokens`, as OpenCode does) got DeepSeek's 8K default
    /// (magpie #2355). The recorded OpenCode request goes with `max_tokens`.
    @Test func deepSeekGetsMaxTokens() throws {
        let opencode = try recordedRequest("clients/opencode-chat")
        let (_, body, _) = try prepare(opencode, for: "deepseek/deepseek-v4-flash")
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["max_tokens"] == 32000)
    }

    // MARK: OpenAI

    /// GPT-5 and o-series reject sampling parameters and `max_tokens`
    /// (pydantic-ai `test_openai_model_settings_temperature_ignored_on_gpt_5`,
    /// vercel `reasoning-model-legacy-parameter-error.json`).
    @Test(arguments: ["openai/gpt-5", "openai/o3-mini"])
    func openAIReasoningModelsDropSamplingAndUseMaxCompletionTokens(_ reference: String) throws {
        var request = try recordedRequest("openai/chat-text-gpt-4o")
        request.temperature = 0.7
        request.topP = 0.9
        request.maxOutputTokens = 300
        request.spellings[.maxOutputTokens] = "max_tokens"
        let (_, body, warnings) = try prepare(request, for: reference, preferring: .chatCompletions)
        #expect(body["temperature"] == nil && body["top_p"] == nil)
        #expect(body["max_completion_tokens"] == 300 && body["max_tokens"] == nil)
        #expect(warnings.contains { $0.code == .unsupportedByModel && $0.path == "temperature" })
    }

    // MARK: Anthropic

    /// Claude Opus 4.6 refused effort `xhigh` with 400 "Supported levels:
    /// high, low, max, medium" (pydantic-ai, recorded as
    /// `anthropic/error-effort-xhigh-opus-4-6`). A Codex request asking
    /// `xhigh` is clamped to a level the model takes.
    @Test func claudeOpus46EffortIsClamped() throws {
        var codex = try recordedRequest("clients/codex")
        codex.reasoning = WireReasoningConfig(effort: "xhigh")
        let (http, body, _) = try prepare(codex, for: "anthropic/claude-opus-4-6")
        #expect(http.path == "/v1/messages")
        let effort = try #require(body["output_config"]?["effort"]?.stringValue)
        #expect(["low", "medium", "high", "max"].contains(effort))
    }

    /// Claude 4.7 and later reject `temperature`/`top_p` (pydantic-ai
    /// `test_bedrock_anthropic_5_api_rejects_sampling_settings`).
    @Test func currentClaudeDropsSamplingParameters() throws {
        var request = try recordedRequest("openai/chat-text-gpt-4o")
        request.temperature = 0.2
        request.topP = 0.5
        let (_, body, _) = try prepare(request, for: "anthropic/claude-opus-5-5")
        #expect(body["temperature"] == nil && body["top_p"] == nil)
    }

    /// Budget thinking on Claude before 4.6: an effort becomes a budget, and
    /// temperature goes while thinking is on.
    @Test func claudeBudgetThinkingFromAnEffort() throws {
        var request = try recordedRequest("openai/chat-text-gpt-4o")
        request.reasoning = WireReasoningConfig(effort: "high")
        request.temperature = 0.3
        let (_, body, _) = try prepare(request, for: "anthropic/claude-sonnet-4-5")
        #expect(body["thinking"]?["type"] == "enabled")
        let budget = try #require(body["thinking"]?["budget_tokens"]?.numberValue?.int)
        #expect(budget >= 1024)
        #expect(try #require(body["max_tokens"]?.numberValue?.int) > budget)
        #expect(body["temperature"] == nil)
    }

    /// Claude Code 2.1.296 sends an inline `system` message mid-conversation
    /// (magpie `workdir/claude-code-2.1.296.json`), and Anthropic takes it
    /// (pydantic-ai `test_mid_conversation_system_prompt[inline-system-supported]`):
    /// passed through to Anthropic, it stays a `system` message.
    @Test func claudeCodeInlineSystemMessageReachesAnthropic() throws {
        let claudeCode = try recordedRequest("clients/claude-code")
        let (_, body, warnings) = try prepare(claudeCode, for: "anthropic/claude-opus-5-5")
        let recorded = try #require(Recording.named("clients/claude-code").requestJSON)
        #expect(body["messages"] == recorded["messages"])
        #expect(!warnings.contains { $0.code == .lossyConversion })
    }

    /// OpenRouter serves Claude through its Messages API (cache breakpoints
    /// survive), with a bearer key.
    @Test func openRouterClaudeGoesThroughMessages() throws {
        let claudeCode = try recordedRequest("clients/claude-code")
        let (http, body, _) = try prepare(claudeCode, for: "openrouter/anthropic/claude-sonnet-5")
        #expect(http.authority == "openrouter.ai" && http.path == "/api/v1/messages")
        #expect(http.headerFields[.authorization] == "Bearer test-key")
        #expect(body["model"] == "anthropic/claude-sonnet-5")
        #expect(keys(body).contains("cache_control"))
    }

    // MARK: Gemini

    /// Gemini 3 rejects a function call without its thought signature (magpie
    /// `gemini_signature_test` #687). A Claude tool turn continued on Gemini 3
    /// carries the documented validator-skip signature instead of Claude's.
    @Test func gemini3GetsASignatureOnForeignCalls() throws {
        let claude = try recordedRequest("anthropic/tool-thinking-turn2-sonnet-5-5")
        let (http, body, _) = try prepare(claude, for: "gemini/gemini-3-pro-preview")
        #expect(http.path == "/v1beta/models/gemini-3-pro-preview:generateContent")
        let parts = (body["contents"]?.arrayValue ?? []).flatMap { $0["parts"]?.arrayValue ?? [] }
        let call = try #require(parts.first { $0["functionCall"] != nil })
        #expect(call["thoughtSignature"] == .string(GeminiRequestOptions.skipSignatureValidator))
    }

    /// Gemini 3's own signatures go back as they came (recorded second turn).
    @Test func gemini3KeepsItsOwnSignature() throws {
        let turn2 = try recordedRequest("gemini/3-signature-stream-turn2")
        let recorded = try #require(Recording.named("gemini/3-signature-stream-turn2").requestJSON)
        let (_, body, _) = try prepare(turn2, for: "gemini/gemini-3-pro-preview", stream: true)
        #expect(jsonDifferences(body["contents"] ?? .null, recorded["contents"] ?? .null) == [])
    }

    /// Gemini 2.5 takes a thinking budget, Gemini 3 a thinking level.
    @Test func geminiReasoningControlPerGeneration() throws {
        var request = try recordedRequest("openai/chat-text-gpt-4o")
        request.reasoning = WireReasoningConfig(effort: "low")
        let (_, flash, _) = try prepare(request, for: "gemini/gemini-2.5-flash")
        #expect(flash["generationConfig"]?["thinkingConfig"]?["thinkingBudget"]?.numberValue != nil)
        let (_, three, _) = try prepare(request, for: "gemini/gemini-3-pro-preview")
        #expect(three["generationConfig"]?["thinkingConfig"]?["thinkingLevel"] == "low")
    }

    // MARK: Mistral

    /// Mistral answers 422 `extra_forbidden` to fields it does not know,
    /// OpenAI's `store` among them (magpie `mistral_extra_fields_test` #393).
    /// The recorded OpenCode request (`store: false`) goes without it.
    @Test func mistralGetsNoFieldItRejects() throws {
        let opencode = try recordedRequest("clients/opencode-chat")
        let (_, body, _) = try prepare(opencode, for: "mistral/mistral-small-latest")
        #expect(body["store"] == nil)
        #expect(body["max_completion_tokens"] == nil && body["max_tokens"] == 32000)
    }

    /// Mistral takes tool call ids of nine letters and digits only (400
    /// "Tool call id was toolu_… but must be a-z, A-Z, 0-9, with a length
    /// of 9"); pydantic-ai rewrites foreign ids (recorded as
    /// `mistral/foreign-tool-ids`, accepted). A Claude tool turn sent to
    /// Mistral gets the same (the `mistralToolIDs` transform).
    @Test func mistralGetsNineCharacterToolCallIDs() throws {
        let claude = try recordedRequest("anthropic/tool-thinking-turn2-sonnet-5-5")
        let (_, body, _) = try prepare(claude, for: "mistral/mistral-small-latest")
        let messages = body["messages"]?.arrayValue ?? []
        let ids = messages.flatMap { ($0["tool_calls"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue } }
            + messages.compactMap { $0["tool_call_id"]?.stringValue }
        #expect(!ids.isEmpty)
        for id in ids {
            #expect(id.count == 9 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }, "\(id)")
        }
        // Each result still answers its call.
        let callIDs = messages.flatMap { ($0["tool_calls"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue } }
        let answered = Set(messages.compactMap { $0["tool_call_id"]?.stringValue })
        #expect(answered.isSubset(of: Set(callIDs)))
    }

    /// Mistral rejects unknown fields (422 `extra_forbidden`): a Gemini
    /// OpenAI-compatible history goes without the `extra_content` its tool
    /// call signature came in, though the Chat codec types it.
    @Test func mistralGetsNoGeminiExtraContent() throws {
        let turn2 = try recordedRequest("gemini-openai/signature-stream-turn2")
        #expect(turn2.messages.contains { $0.parts.contains { if case .toolCall(let call) = $0 { call.signature != nil } else { false } } })
        let (_, body, warnings) = try prepare(turn2, for: "mistral/mistral-large-latest")
        #expect(!keys(body).contains("extra_content"))
        #expect(warnings.contains { $0.code == .unsupportedByModel && $0.message.contains("extra_content") })
    }

    // MARK: Kimi, Groq, xAI

    /// Kimi turns away other vendors' `reasoning_details` (magpie
    /// `kimi_reasoning_details_test` #1765) but takes `reasoning_content`.
    /// A conversation OpenRouter answered (recorded reply with
    /// `reasoning_details`) continued on Kimi.
    @Test func kimiGetsReasoningContentNotReasoningDetails() throws {
        let recording = Recording.named("openrouter/reasoning-details-replay")
        #expect(recording.responseJSON?["choices"]?[0]?["message"]?["reasoning_details"] != nil)
        let reply = try recording.decodeReply().response
        var request = try recordedRequest("openrouter/reasoning-details-replay")
        request.messages.append(reply.message)
        request.messages.append(WireMessage(role: .user, parts: [.text(WireText("And then?"))]))
        let (http, body, _) = try prepare(request, for: "moonshot/kimi-k2-0905-preview")
        #expect(http.authority == "api.moonshot.ai")
        #expect(!keys(body).contains("reasoning_details"))
        let assistant = try #require(body["messages"]?.arrayValue?.last { $0["role"] == "assistant" })
        #expect(assistant["reasoning_content"]?.stringValue?.isEmpty == false)
    }

    /// Groq (like Ollama) rejects text-part arrays in some message roles:
    /// content made only of text goes as a string.
    @Test func groqGetsStringContent() throws {
        let claudeCode = try recordedRequest("clients/claude-code")
        let (_, body, _) = try prepare(claudeCode, for: "groq/openai/gpt-oss-120b")
        for message in body["messages"]?.arrayValue ?? [] where message["tool_calls"] == nil && message["role"] != "tool" {
            #expect(message["content"]?.stringValue != nil, "\(message["role"] ?? .null) content is not a string")
        }
    }

    /// Grok 4 rejects penalties and stop sequences.
    @Test func grok4DropsPenaltiesAndStop() throws {
        var request = try recordedRequest("openai/chat-text-gpt-4o")
        request.presencePenalty = 0.5
        request.frequencyPenalty = 0.5
        request.stop = .multiple(["END"])
        let (_, body, _) = try prepare(request, for: "xai/grok-4", preferring: .chatCompletions)
        #expect(body["presence_penalty"] == nil && body["frequency_penalty"] == nil && body["stop"] == nil)
    }
}
