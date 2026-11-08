import Foundation
import Testing
import Unladen

/// Cache breakpoints and message-, part- and tool-level provider options,
/// end to end: the exact body each target gets and the warnings reported.
@Suite struct PromptCacheTests {
    static let anthropicReply = """
    {"id":"msg_0","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"Done."}],
     "stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":2,"cache_read_input_tokens":3}}
    """
    static let chatReply = """
    {"id":"gen-1","object":"chat.completion","created":1,"model":"anthropic/claude-sonnet-4-5",
     "choices":[{"index":0,"message":{"role":"assistant","content":"Done."},"finish_reason":"stop"}],
     "usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}
    """
    static let responsesReply = """
    {"id":"resp_1","object":"response","created_at":1,"status":"completed","model":"gpt-5.2",
     "output":[{"type":"message","id":"msg_1","status":"completed","role":"assistant",
                "content":[{"type":"output_text","text":"Done.","annotations":[]}]}],
     "usage":{"input_tokens":5,"output_tokens":2,"total_tokens":7}}
    """
    static let geminiReply = """
    {"candidates":[{"content":{"role":"model","parts":[{"text":"Done."}]},"finishReason":"STOP"}],
     "usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"totalTokenCount":7},"modelVersion":"gemini-2.5-flash"}
    """

    static let schema: JSONValue = ["type": "object", "properties": ["q": ["type": "string"]]]

    /// A system prompt cached for an hour, a document cached in the user
    /// turn, and the tool definitions cached.
    static let history: [Message] = [
        Message.system("You are a contract analyst.").cached(ttl: .oneHour),
        .user([.text("<contract>…</contract>").cached(), .text("Summarise clause 4.")]),
    ]
    static let tools = [Tool(name: "search", description: "Search the contract", inputSchema: schema).cached()]

    /// OpenRouter with Claude over Chat (the preset forces Messages; a
    /// registry without that rule keeps Chat, with the Claude Profile).
    static func openRouterChat(_ provider: FakeProvider, policy: WarningPolicy = .strict) throws -> LanguageModel {
        var registry = ProviderRegistry.builtIn
        var openRouter = try #require(registry["openrouter"])
        openRouter.models = openRouter.models.map { rule in
            var rule = rule
            rule.profile.forcedProtocol = nil
            return rule
        }
        registry.register(openRouter)
        let client = ModelClient(
            transport: provider.transport, registry: registry, apiKeys: ["openrouter": "sk-or"], environment: [:], warningPolicy: policy,
        )
        return try client.model("openrouter/anthropic/claude-sonnet-4-5", preferring: .chatCompletions)
    }

    // MARK: Anthropic

    @Test func anthropicGetsCacheControlOnBlocksSystemAndTools() async throws {
        let provider = FakeProvider(.json(Self.anthropicReply))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")
        let response = try await model.generate(Self.history, tools: Self.tools)

        // Claude reads tools before system: the tools' five minutes become
        // the system prompt's hour (a 1h breakpoint may not follow a 5m one).
        #expect(response.warnings.map(\.path) == ["tools[0].cache_control"])
        #expect(response.warnings.allSatisfy { $0.code == .adjusted && !$0.isEscalatedWhenStrict })
        #expect(response.usage.cachedInputTokens == 3)
        let expected: JSONValue = [
            "model": "claude-sonnet-4-5",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "<contract>…</contract>", "cache_control": ["type": "ephemeral"]],
                    ["type": "text", "text": "Summarise clause 4."],
                ],
            ]],
            "max_tokens": 16000,
            "system": [["type": "text", "text": "You are a contract analyst.", "cache_control": ["type": "ephemeral", "ttl": "1h"]]],
            "tools": [[
                "name": "search", "description": "Search the contract", "input_schema": Self.schema,
                "cache_control": ["type": "ephemeral", "ttl": "1h"],
            ]],
        ]
        #expect(provider.lastBody == expected)
    }

    @Test func anthropicMessageBreakpointGoesOnTheLastBlock() async throws {
        let provider = FakeProvider(.json(Self.anthropicReply))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")
        let call = ToolCall(id: "toolu_1", name: "search", arguments: #"{"q":"clause 4"}"#)
        let history: [Message] = [
            .user("Find clause 4."),
            Message.assistant([.text("Searching."), .toolCall(call)]).cached(),
            Message.tool(ToolResult(call: call, output: "Clause 4: …")).cached(ttl: .fiveMinutes),
        ]
        _ = try await model.generate(history, tools: [Tool(name: "search", inputSchema: Self.schema)])
        let expected: JSONValue = [
            ["role": "user", "content": "Find clause 4."],
            ["role": "assistant", "content": [
                ["type": "text", "text": "Searching."],
                ["type": "tool_use", "id": "toolu_1", "name": "search", "input": ["q": "clause 4"], "cache_control": ["type": "ephemeral"]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": "Clause 4: …",
                 "cache_control": ["type": "ephemeral", "ttl": "5m"]],
            ]],
        ]
        #expect(provider.lastBody["messages"] == expected)
    }

    @Test func anthropicProviderOptionsGoOnTheirObjects() async throws {
        let provider = FakeProvider(.json(Self.anthropicReply))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")
        let document = ContentPart.file(Media(.url("https://example.com/c.pdf"), mediaType: "application/pdf", filename: "Contract"))
            .withProviderOptions(["anthropic": ["citations": ["enabled": true]], "chat": ["ignored": true]])
            .cached()
        let user = Message(
            role: .user, content: [document, .text("Cite clause 4.")],
            providerOptions: ["anthropic": ["x_turn": 1], "gemini": ["ignored": true]],
        )
        let tool = Tool(name: "search", inputSchema: Self.schema, providerOptions: ["anthropic": ["defer_loading": true]])
        let response = try await model.generate([user], tools: [tool])

        #expect(response.warnings.isEmpty, "\(response.warnings)")
        let expected: JSONValue = [
            "role": "user",
            "content": [
                [
                    "type": "document", "source": ["type": "url", "url": "https://example.com/c.pdf"], "title": "Contract",
                    "cache_control": ["type": "ephemeral"], "citations": ["enabled": true],
                ],
                ["type": "text", "text": "Cite clause 4."],
            ],
            "x_turn": 1,
        ]
        #expect(provider.lastBody.at("messages[0]") == expected)
        #expect(provider.lastBody.at("tools[0]") == ["name": "search", "input_schema": Self.schema, "defer_loading": true])
    }

    /// A system message's own options have no Anthropic object: an error
    /// under the strict policy, reported under the lenient one.
    @Test func anthropicSystemMessageOptionsHaveNoObject() async throws {
        let system = Message(role: .system, content: [.text("Be brief.")], providerOptions: ["anthropic": ["x": 1]])
        let strict = FakeProvider(.json(Self.anthropicReply))
        await #expect(throws: UnladenError.self) {
            _ = try await client(strict).model("anthropic/claude-sonnet-4-5").generate([system, .user("Hi")])
        }
        #expect(strict.requests.isEmpty)

        let provider = FakeProvider(.json(Self.anthropicReply))
        let response = try await client(provider, policy: .lenient).model("anthropic/claude-sonnet-4-5").generate([system, .user("Hi")])
        #expect(response.warnings.map(\.code) == [.droppedField])
        #expect(response.warnings.first?.path == "messages[0]")
        #expect(provider.lastBody["system"] == "Be brief.")
    }

    /// Claude takes four breakpoints: the tools', the system prompt's, then
    /// the newest ones are kept; the rest are reported, never thrown.
    @Test func breakpointsBeyondFourAreTrimmedOldestFirst() async throws {
        let provider = FakeProvider(.json(Self.anthropicReply))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")
        let history: [Message] = [
            Message.system("System.").cached(),
            Message.user("Turn 1.").cached(),
            Message.assistant("Answer 1.").cached(),
            Message.user("Turn 2.").cached(),
            Message.assistant("Answer 2.").cached(),
            Message.user("Turn 3.").cached(),
        ]
        let response = try await model.generate(history, tools: Self.tools)

        #expect(response.warnings.map(\.path) == [
            "messages[3].content[0].cache_control",
            "messages[2].content[0].cache_control",
            "messages[1].content[0].cache_control",
        ])
        #expect(response.warnings.allSatisfy { $0.code == .droppedField && $0.isCacheHint && !$0.isEscalatedWhenStrict })
        let body = provider.lastBody
        let marked = (body["messages"]?.arrayValue ?? []).map { $0.at("content[0].cache_control") != nil }
        #expect(marked == [false, false, false, true, true])
        #expect(body.at("system[0].cache_control") != nil)
        #expect(body.at("tools[0].cache_control") != nil)
    }

    // MARK: OpenRouter Chat (Claude)

    @Test func openRouterClaudeOverChatGetsCacheControlOnParts() async throws {
        let provider = FakeProvider(.json(Self.chatReply))
        let model = try Self.openRouterChat(provider)
        let call = ToolCall(id: "call_1", name: "search", arguments: #"{"q":"clause 4"}"#)
        var history = Self.history
        history[1].providerOptions = ["chat": ["name": "analyst"], "openrouter": ["name": "alice"]]
        history += [
            Message.assistant([.text("Searching."), .toolCall(call)]).cached(),
            Message.tool(ToolResult(call: call, output: "Clause 4: …")).cached(),
        ]
        let response = try await model.generate(history, tools: Self.tools)

        // Five breakpoints for Claude's four: the oldest message one goes;
        // the tools' TTL rises to the system prompt's hour.
        #expect(response.warnings.map(\.path) == ["messages[1].content[0].cache_control", "tools[0].cache_control"])
        #expect(response.warnings.map(\.code) == [.droppedField, .adjusted])
        #expect(response.warnings.allSatisfy { !$0.isEscalatedWhenStrict })
        #expect(provider.requests.first?.path == "/api/v1/chat/completions")
        let expected: JSONValue = [
            "model": "anthropic/claude-sonnet-4-5",
            "messages": [
                ["role": "system", "content": [
                    ["type": "text", "text": "You are a contract analyst.", "cache_control": ["type": "ephemeral", "ttl": "1h"]],
                ]],
                ["role": "user", "content": [
                    ["type": "text", "text": "<contract>…</contract>"],
                    ["type": "text", "text": "Summarise clause 4."],
                ], "name": "alice"],
                // Chat has no place for a breakpoint on a tool call: the
                // message's goes on its text.
                ["role": "assistant", "content": [
                    ["type": "text", "text": "Searching.", "cache_control": ["type": "ephemeral"]],
                ], "tool_calls": [
                    ["id": "call_1", "type": "function", "function": ["name": "search", "arguments": #"{"q":"clause 4"}"#]],
                ]],
                ["role": "tool", "content": [
                    ["type": "text", "text": "Clause 4: …", "cache_control": ["type": "ephemeral"]],
                ], "tool_call_id": "call_1"],
            ],
            "tools": [[
                "type": "function",
                "function": ["name": "search", "description": "Search the contract", "parameters": Self.schema],
                "cache_control": ["type": "ephemeral", "ttl": "1h"],
            ]],
        ]
        #expect(provider.lastBody == expected)
    }

    // MARK: Targets without breakpoints

    @Test func openAIResponsesDropsBreakpointsAsCacheHints() async throws {
        let provider = FakeProvider(.json(Self.responsesReply))
        let model = try client(provider).model("openai/gpt-5.2")
        let response = try await model.generate(Self.history, tools: Self.tools)

        let expected: JSONValue = [
            "model": "gpt-5.2",
            "input": [
                ["type": "message", "role": "system", "content": "You are a contract analyst."],
                ["type": "message", "role": "user", "content": [
                    ["type": "input_text", "text": "<contract>…</contract>"],
                    ["type": "input_text", "text": "Summarise clause 4."],
                ]],
            ],
            "tools": [[
                "type": "function", "name": "search", "description": "Search the contract", "parameters": Self.schema, "strict": false,
            ]],
        ]
        #expect(provider.lastBody == expected)
        #expect(response.warnings.map(\.path) == [
            "input[0].content[0].cache_control", "input[1].content[0].cache_control", "tools[0].cache_control",
        ])
        #expect(response.warnings.allSatisfy { $0.code == .droppedField && $0.isCacheHint })
    }

    @Test func openAIChatDropsBreakpointsAsCacheHints() async throws {
        let provider = FakeProvider(.json(Self.chatReply))
        let model = try client(provider).model("openai/gpt-4o", preferring: .chatCompletions)
        let response = try await model.generate(Self.history, tools: Self.tools)

        let expected: JSONValue = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": "You are a contract analyst."],
                ["role": "user", "content": [
                    ["type": "text", "text": "<contract>…</contract>"],
                    ["type": "text", "text": "Summarise clause 4."],
                ]],
            ],
            "tools": [["type": "function", "function": ["name": "search", "description": "Search the contract", "parameters": Self.schema]]],
        ]
        #expect(provider.lastBody == expected)
        #expect(response.warnings.map(\.path) == [
            "messages[0].content[0].cache_control", "messages[1].content[0].cache_control", "tools[0].cache_control",
        ])
        #expect(response.warnings.allSatisfy { $0.code == .droppedField && $0.isCacheHint })
    }

    @Test func geminiDropsBreakpointsAsCacheHintsAndTakesItsOptions() async throws {
        let provider = FakeProvider(.json(Self.geminiReply))
        let model = try client(provider).model("gemini/gemini-2.5-flash")
        var history = Self.history
        history[0].providerOptions = ["gemini": ["role": "system"]]
        history[1].content[1] = history[1].content[1].withProviderOptions(["gemini": ["thought": false]])
        let response = try await model.generate(history, tools: Self.tools)

        let expected: JSONValue = [
            "contents": [["parts": [["text": "<contract>…</contract>"], ["text": "Summarise clause 4.", "thought": false]], "role": "user"]],
            "systemInstruction": ["parts": [["text": "You are a contract analyst."]], "role": "system"],
            "tools": [["functionDeclarations": [["name": "search", "description": "Search the contract", "parametersJsonSchema": Self.schema]]]],
        ]
        #expect(provider.lastBody == expected)
        #expect(response.warnings.map(\.path) == [
            "contents[1].parts[0].cache_control", "systemInstruction.parts[0].cache_control", "tools[0].cache_control",
        ])
        #expect(response.warnings.allSatisfy { $0.code == .droppedField && $0.isCacheHint })
    }

    // MARK: Codable

    func roundTrip(_ history: [Message]) throws -> [Message] {
        try JSONDecoder().decode([Message].self, from: JSONEncoder().encode(history))
    }

    @Test func breakpointsAndOptionsRoundTrip() throws {
        let history: [Message] = [
            Message.system("Sys").cached(ttl: .oneHour),
            Message(
                role: .user,
                content: [
                    .text("doc").cached(),
                    .image(.url("https://example.com/a.png")).withProviderOptions(["anthropic": try JSONValue(parsing: #"{"x":null,"y":0.50}"#).objectValue!]),
                    .text("plain"),
                ],
                providerOptions: ["chat": ["name": "n"]],
            ),
            .tool(ToolResult(callID: "c", toolName: "f", output: [.text("out").cached(ttl: "2h")])),
        ]
        let decoded = try roundTrip(history)
        #expect(decoded == history)
        guard case .annotated(_, let options) = decoded[1].content[1] else {
            Issue.record("expected an annotated part")
            return
        }
        #expect(options.providerOptions["anthropic"]?["y"]?.numberValue?.literal == "0.50")
        #expect(options.providerOptions["anthropic"]?["x"] == .null)
    }

    /// A history saved before breakpoints existed loads unchanged, and a
    /// history without them encodes as before.
    @Test func historySavedBeforeBreakpointsStillLoads() throws {
        let saved = #"""
        [{"role":"system","content":[{"type":"text","text":"Be brief."}]},
         {"role":"user","content":[{"type":"text","text":"Hi"},{"type":"image","media":{"url":"https://example.com/a.png"}}]},
         {"role":"tool","content":[{"type":"toolResult","toolResult":{"callID":"c","toolName":"f","output":[{"type":"text","text":"ok"}],"isError":false}}]}]
        """#
        let history = try JSONDecoder().decode([Message].self, from: Data(saved.utf8))
        #expect(history == [
            .system("Be brief."),
            .user([.text("Hi"), .image(.url("https://example.com/a.png"))]),
            .tool(ToolResult(callID: "c", toolName: "f", output: [.text("ok")])),
        ])
        #expect(history.allSatisfy { $0.cache == nil && $0.providerOptions.isEmpty })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(history), as: UTF8.self)
        #expect(!text.contains("cache") && !text.contains("providerOptions"))
    }

    @Test func partOptionsCompose() {
        let part = ContentPart.text("x").cached(ttl: .oneHour).withProviderOptions(["anthropic": ["a": 1]])
            .withProviderOptions(["anthropic": ["b": 2]])
        #expect(part.base == .text("x"))
        #expect(part.options.cache == CacheBreakpoint(ttl: .oneHour))
        #expect(part.options.providerOptions["anthropic"] == ["a": 1, "b": 2])
        #expect(Message.user([part]).text == "x")
        #expect(ContentPart.text("x").with(PartOptions()) == .text("x"))
    }

    // MARK: Tool results, TTLs and part options

    /// A breakpoint on a tool result's output marks the `tool_result`
    /// block; several on one result become one.
    @Test func toolResultOutputBreakpointMarksTheResult() async throws {
        let provider = FakeProvider(.json(Self.anthropicReply))
        let model = try client(provider, policy: .lenient).model("anthropic/claude-sonnet-4-5")
        let call = ToolCall(id: "toolu_1", name: "search", arguments: "{}")
        let history: [Message] = [
            .user("Find it."), .assistant([.toolCall(call)]),
            .tool(ToolResult(call: call, output: [.text("x").cached(ttl: .oneHour), .text("y").cached()])),
        ]
        let response = try await model.generate(history, tools: [Tool(name: "search", inputSchema: Self.schema)])
        #expect(provider.lastBody.at("messages[2].content[0]") == [
            "type": "tool_result", "tool_use_id": "toolu_1",
            "content": [["type": "text", "text": "x"], ["type": "text", "text": "y"]],
            "cache_control": ["type": "ephemeral"],
        ])
        #expect(response.warnings.map(\.path) == ["messages[2].content[0].output[0].cache_control"])
        #expect(response.warnings.allSatisfy { $0.isCacheHint })
    }

    /// An empty tool result keeps its breakpoint on Chat.
    @Test func emptyToolResultBreakpointOnChat() async throws {
        let provider = FakeProvider(.json(Self.chatReply))
        let call = ToolCall(id: "call_1", name: "search", arguments: "{}")
        let history: [Message] = [
            .user("Find it."), .assistant([.toolCall(call)]),
            Message.tool(ToolResult(call: call, output: [])).cached(),
        ]
        let response = try await Self.openRouterChat(provider).generate(history, tools: [Tool(name: "search", inputSchema: Self.schema)])
        #expect(response.warnings.isEmpty, "\(response.warnings)")
        #expect(provider.lastBody.at("messages[2].content") == [["type": "text", "text": "", "cache_control": ["type": "ephemeral"]]])
    }

    /// Claude rejects a 1h breakpoint after a 5m one: the earlier one is
    /// raised (reported, never an error).
    @Test func earlierBreakpointTTLsRiseToALaterHour() async throws {
        let provider = FakeProvider(.json(Self.anthropicReply))
        let model = try client(provider).model("anthropic/claude-sonnet-4-5")
        let history: [Message] = [Message.system("Sys.").cached(), Message.user("Hi.").cached(ttl: .oneHour)]
        let response = try await model.generate(history)
        #expect(response.warnings.map(\.code) == [.adjusted])
        #expect(response.warnings.first?.path == "messages[0].content[0].cache_control")
        #expect(provider.lastBody.at("system[0].cache_control") == ["type": "ephemeral", "ttl": "1h"])
    }

    /// Options compare and hash the same however they were stacked.
    @Test func annotatedPartsCompareByBaseAndOptions() {
        let built = ContentPart.text("x").cached().withProviderOptions(["anthropic": ["b": 1]])
        let nested = ContentPart.annotated(
            .annotated(.text("x"), PartOptions(cache: CacheBreakpoint())),
            PartOptions(providerOptions: ["anthropic": ["b": 1]]),
        )
        #expect(built == nested)
        #expect(Set([built, nested]).count == 1)
        #expect(ContentPart.annotated(.text("x"), PartOptions()) == .text("x"))
        #expect(Set([ContentPart.annotated(.text("x"), PartOptions()), .text("x")]).count == 1)
        #expect(built != .text("x") && nested.cached(ttl: .oneHour) != built)
        #expect(ContentPart.text("x") != .reasoning("x"))
    }

    /// Options on reasoning, a Chat message field, are reported at the part.
    @Test func chatReasoningOptionsDropAtThePart() async throws {
        let provider = FakeProvider(.json(Self.chatReply))
        let history: [Message] = [
            .user("Hi"),
            .assistant([.reasoning("hm").withProviderOptions(["chat": ["x": 1]]), .text("ok")]),
            .user("Again"),
        ]
        let response = try await Self.openRouterChat(provider, policy: .lenient).generate(history)
        #expect(response.warnings.contains { $0.code == .droppedField && $0.path == "messages[1].content[0]" }, "\(response.warnings)")
    }

    /// A breakpoint on a part that cannot carry one is a cache hint.
    @Test func reasoningCannotBeABreakpoint() async throws {
        let provider = FakeProvider(.json(Self.anthropicReply))
        let model = try client(provider, policy: .lenient).model("anthropic/claude-sonnet-4-5")
        let history: [Message] = [.user("Hi"), .assistant([.reasoning("hm").cached()]), .user("Again")]
        let response = try await model.generate(history)
        #expect(response.warnings.contains { $0.path == "messages[1].content[0].cache_control" && $0.isCacheHint })
    }
}
