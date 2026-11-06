import Foundation
import Testing
import Unladen
@_spi(Wire) import UnladenCore

/// A conversation recorded over two calls: the first call's request and
/// reply, then the request the recording client sent next (the reply
/// appended, tool results added) and its reply.
struct RecordedExchange: Sendable, CustomTestStringConvertible {
    let first: String
    let second: String
    var testDescription: String { first }

    var turn1: Recording { Recording.named(first) }
    var turn2: Recording { Recording.named(second) }

    static let all: [RecordedExchange] = [
        // Signed adaptive thinking, text, a tool call (Messages, streamed).
        RecordedExchange(first: "anthropic/tool-thinking-turn1-sonnet-5-5", second: "anthropic/tool-thinking-turn2-sonnet-5-5"),
        // A function call carrying Gemini 3's thought signature.
        RecordedExchange(first: "gemini/3-signature-stream-turn1", second: "gemini/3-signature-stream-turn2"),
        // Three parallel calls with Mistral's nine-character ids.
        RecordedExchange(first: "mistral/parallel-tools-stream", second: "mistral/parallel-tools-turn2-stream"),
        // A later call in a conversation with an earlier tool exchange.
        RecordedExchange(first: "openai/chat-tool-calls-gpt-4o-mini", second: "openai/chat-tool-result-turn-gpt-4o-mini"),
    ]
}

/// Layer C: the library (``ModelClient``, ``LanguageModel``) driven the way
/// an application drives it, against recorded replies.
///
/// - A recorded two-call tool conversation, replayed through the library
///   (reply appended as is, tool results answered with the recorded
///   outputs), sends the second request the recording client sent: the
///   assistant turn with its signatures and ids, and the results.
/// - A conversation started on Claude (signed thinking, a tool call)
///   continues on another vendor after a fallback: Claude's replay data is
///   left out (reported, never an error), calls and results stay paired,
///   each vendor gets what it requires, and its recorded answer comes back.
@Suite struct LibraryScenarioTests {
    func client(_ transport: ReplayTransport) -> ModelClient {
        let keys = ["anthropic", "openai", "gemini", "deepseek", "mistral", "groq", "moonshot", "openrouter", "xai"]
        return ModelClient(transport: transport.transport, apiKeys: Dictionary(uniqueKeysWithValues: keys.map { ($0, "test-key") }), environment: [:])
    }

    /// The model reply, streamed or not as the recording was.
    func call(_ model: LanguageModel, _ request: ModelRequest, streamed: Bool) async throws -> ModelResponse {
        streamed ? try await model.stream(request).collect() : try await model.generate(request)
    }

    @Test(arguments: RecordedExchange.all)
    func toolConversationReplaysAsRecorded(_ exchange: RecordedExchange) async throws {
        let turn1 = exchange.turn1, turn2 = exchange.turn2
        let wire = turn1.wire
        let first = try RecordedConversation(try #require(turn1.requestJSON), wire)
        let replay = ReplayTransport([turn1, turn2])
        let model = try client(replay).model(try #require(turn1.target), preferring: wire.apiProtocol)

        var request = ModelRequest(messages: first.messages, tools: first.tools)
        let reply = try await call(model, request, streamed: turn1.isStream)
        let facts1 = try #require(turn1.facts)
        #expect(reply.toolCalls.map(\.name) == (facts1["toolCalls"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })

        // The client answers each call with what it answered when recorded.
        let second = try RecordedConversation(try #require(turn2.requestJSON), wire)
        let outputs = Array(second.resultOutputs.dropFirst(first.resultOutputs.count))
        try #require(outputs.count == reply.toolCalls.count, "\(outputs.count) recorded results for \(reply.toolCalls.count) calls")
        request.messages.append(reply.message)
        request.messages.append(.tool(zip(reply.toolCalls, outputs).map { call, output in
            ToolResult(call: call, output: [.text(output)])
        }))
        let answer = try await call(model, request, streamed: turn2.isStream)

        // What went out is what the recording client sent.
        let sent = try #require(replay.requests.last).json
        let key = RecordedConversation.conversationKey(wire)
        let recorded = try #require(turn2.requestJSON)[key] ?? .null
        let problems = jsonDifferences(RecordedConversation.canonical(sent[key] ?? .null, wire), RecordedConversation.canonical(recorded, wire), path: "$.\(key)")
            .filter { difference in !turn2.allowedRequestChanges.keys.contains { matches(difference, path: $0) } }
        #expect(problems == [])
        #expect(answer.text == turn2.facts?["text"]?.stringValue)
    }

    // MARK: Fallback

    /// Where a Claude conversation goes after Claude fails, and the
    /// recorded reply that vendor gives.
    struct Fallback: Sendable, CustomTestStringConvertible {
        let target: String
        let reply: String
        var testDescription: String { target }
    }

    static let fallbacks: [Fallback] = [
        Fallback(target: "openai/gpt-5-mini", reply: "openai/responses-reasoning-gpt-5-mini"),
        Fallback(target: "gemini/gemini-3-pro-preview", reply: "gemini/3-signature-stream-turn2"),
        Fallback(target: "deepseek/deepseek-v4-flash", reply: "deepseek/reasoning-stream"),
        Fallback(target: "moonshot/kimi-k2-0905-preview", reply: "moonshot/tool-call-stream"),
        Fallback(target: "groq/openai/gpt-oss-120b", reply: "groq/tool-call-stream"),
        Fallback(target: "xai/grok-4", reply: "xai/chat-text-stream"),
    ]

    @Test(arguments: fallbacks)
    func claudeConversationContinuesElsewhere(_ fallback: Fallback) async throws {
        let turn1 = Recording.named("anthropic/tool-thinking-turn1-sonnet-5-5")
        let overloaded = Recording.named("anthropic/error-overloaded-529")
        let next = Recording.named(fallback.reply)
        let replay = ReplayTransport([turn1, overloaded, next])
        let client = client(replay)
        let claude = try client.model(try #require(turn1.target))
        let first = try RecordedConversation(try #require(turn1.requestJSON), .anthropicMessages)

        var request = ModelRequest(messages: first.messages, tools: first.tools)
        let reply = try await claude.stream(request).collect()
        let toolCall = try #require(reply.toolCalls.first)
        request.messages.append(reply.message)
        request.messages.append(.tool(ToolResult(call: toolCall, output: "Mexico")))

        // Claude is overloaded: retryable, so the application falls back.
        do {
            _ = try await claude.stream(request).collect()
            Issue.record("expected 529")
        } catch UnladenError.http(let http) {
            #expect(http.statusCode == 529 && http.isRetryable)
        }
        let other = try client.model(fallback.target, preferring: next.wire.apiProtocol)
        let answer = try await call(other, request, streamed: next.isStream)

        let sent = try #require(replay.requests.last)
        let signature = try #require(Recording.named("anthropic/tool-thinking-turn2-sonnet-5-5").requestJSON?["messages"]?[1]?["content"]?[0]?["signature"]?.stringValue)
        #expect(!sent.body.containsSubsequence(Array(signature.prefix(40).utf8)), "Claude's signature reached \(fallback.target)")
        #expect(answer.warnings.contains { $0.code == CallWarning.Code.replayDataDropped })
        #expect(answer.text == next.facts?["text"]?.stringValue)

        // The call and its result, paired in the vendor's terms.
        let body = sent.json
        let wire = try client.registry.resolve(fallback.target, preferring: next.wire.apiProtocol).endpoint.apiProtocol.wire
        switch wire {
        case .chatCompletions:
            let messages = body["messages"]?.arrayValue ?? []
            let assistant = try #require(messages.first { $0["tool_calls"] != nil })
            let id = try #require(assistant["tool_calls"]?[0]?["id"]?.stringValue)
            #expect(messages.contains { $0["role"] == "tool" && $0["tool_call_id"] == .string(id) && $0["content"] == "Mexico" })
            if fallback.target.hasPrefix("deepseek/") {
                // Thinking mode: a tool turn without reasoning_content is a 400.
                #expect(assistant["reasoning_content"]?.stringValue != nil)
            }
        case .responses:
            let input = body["input"]?.arrayValue ?? []
            let id = try #require(input.first { $0["type"] == "function_call" }?["call_id"]?.stringValue)
            #expect(input.contains { $0["type"] == "function_call_output" && $0["call_id"] == .string(id) })
            #expect(!input.contains { $0["type"] == "reasoning" })
        case .gemini:
            let parts = (body["contents"]?.arrayValue ?? []).flatMap { $0["parts"]?.arrayValue ?? [] }
            let functionCall = try #require(parts.first { $0["functionCall"] != nil })
            #expect(functionCall["thoughtSignature"] == .string(GeminiRequestOptions.skipSignatureValidator))
            #expect(parts.contains { $0["functionResponse"]?["name"] == functionCall["functionCall"]?["name"] })
        case .anthropicMessages:
            Issue.record("not a fallback")
        }
    }
}

extension [UInt8] {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return needle.isEmpty }
        return (0...(count - needle.count)).contains { self[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

/// The conversation and tools of a recorded request, read back as an
/// application would have built them (text, tool calls, tool results).
struct RecordedConversation {
    var messages: [Message] = []
    var tools: [Tool] = []
    /// The text of each tool result, in order.
    var resultOutputs: [String] = []

    static func conversationKey(_ wire: WireProtocol) -> String {
        switch wire {
        case .chatCompletions, .anthropicMessages: "messages"
        case .responses: "input"
        case .gemini: "contents"
        }
    }

    struct Unsupported: Error, CustomStringConvertible {
        var description: String
    }

    init(_ body: JSONValue, _ wire: WireProtocol) throws {
        switch wire {
        case .chatCompletions:
            for tool in body["tools"]?.arrayValue ?? [] {
                let function = tool["function"] ?? .null
                tools.append(Tool(name: function["name"]?.stringValue ?? "", description: function["description"]?.stringValue,
                                  inputSchema: function["parameters"] ?? ["type": "object"]))
            }
            for message in body["messages"]?.arrayValue ?? [] {
                let text = Self.text(message["content"])
                switch message["role"]?.stringValue {
                case "system", "developer": messages.append(.system(text))
                case "user": messages.append(.user(text))
                case "assistant":
                    var content: [ContentPart] = text.isEmpty ? [] : [.text(text)]
                    for call in message["tool_calls"]?.arrayValue ?? [] {
                        content.append(.toolCall(ToolCall(
                            id: call["id"]?.stringValue ?? "", name: call["function"]?["name"]?.stringValue ?? "",
                            arguments: call["function"]?["arguments"]?.stringValue ?? "{}",
                        )))
                    }
                    messages.append(.assistant(content))
                case "tool":
                    resultOutputs.append(text)
                    let id = message["tool_call_id"]?.stringValue ?? ""
                    let name = messages.last { $0.role == .assistant }?.toolCalls.first { $0.id == id }?.name
                    let result = ToolResult(callID: id, toolName: name, output: [.text(text)])
                    if let last = messages.last, last.role == .tool {
                        messages[messages.count - 1].content.append(.toolResult(result))
                    } else {
                        messages.append(.tool(result))
                    }
                default: throw Unsupported(description: "role \(message["role"] ?? .null)")
                }
            }
        case .anthropicMessages:
            for tool in body["tools"]?.arrayValue ?? [] {
                tools.append(Tool(name: tool["name"]?.stringValue ?? "", description: tool["description"]?.stringValue,
                                  inputSchema: tool["input_schema"] ?? ["type": "object"]))
            }
            for message in body["messages"]?.arrayValue ?? [] {
                let blocks = message["content"]?.arrayValue ?? [message["content"] ?? .null]
                if message["role"] == "user", blocks.contains(where: { $0["type"] == "tool_result" }) {
                    for block in blocks where block["type"] == "tool_result" { resultOutputs.append(Self.text(block["content"])) }
                    continue
                }
                guard message["role"] == "user" else { continue }
                messages.append(.user(blocks.map { Self.text($0) }.joined()))
            }
        case .gemini:
            for tool in body["tools"]?.arrayValue ?? [] {
                for declaration in tool["functionDeclarations"]?.arrayValue ?? [] {
                    tools.append(Tool(name: declaration["name"]?.stringValue ?? "", description: declaration["description"]?.stringValue,
                                      inputSchema: declaration["parameters_json_schema"] ?? declaration["parametersJsonSchema"] ?? ["type": "object"]))
                }
            }
            for content in body["contents"]?.arrayValue ?? [] {
                let parts = content["parts"]?.arrayValue ?? []
                for part in parts {
                    if let response = part["functionResponse"]?["response"] {
                        resultOutputs.append(response["return_value"]?.stringValue ?? Self.text(response))
                    }
                }
                guard content["role"] == "user", parts.allSatisfy({ $0["text"] != nil }) else { continue }
                messages.append(.user(parts.map { Self.text($0) }.joined()))
            }
        case .responses:
            throw Unsupported(description: "Responses conversations are not read back")
        }
    }

    /// `conversation` with spelling choices that mean the same to the
    /// vendor made uniform, so a conversation an application builds with
    /// the library compares with one another client sent:
    ///
    /// - tool call arguments as parsed JSON (`{"a": 1}` is `{"a":1}`);
    /// - a string `content` as one text block, `is_error: false` as absent
    ///   (Messages);
    /// - empty or `null` content beside tool calls as absent (Chat);
    /// - Gemini thought signatures in standard base64 (the Google SDK
    ///   writes the bytes it got back URL-safe), and ids pydantic-ai made up
    ///   for Gemini calls (`pyd_ai_…`, never sent by Gemini) left out.
    static func canonical(_ value: JSONValue, _ wire: WireProtocol) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map { canonical($0, wire) })
        case .object(var object):
            if case .string(let arguments)? = object["arguments"], let parsed = try? JSONValue(parsing: Array(arguments.utf8)) {
                object["arguments"] = parsed
            }
            switch wire {
            case .anthropicMessages:
                let textBlocks: (String) -> JSONValue = { [["text": .string($0), "type": "text"]] }
                if object["role"] != nil, case .string(let text)? = object["content"] { object["content"] = textBlocks(text) }
                if object["type"] == "tool_result" {
                    if object["is_error"] == false { _ = object.removeValue(forKey: "is_error") }
                    if case .string(let text)? = object["content"] { object["content"] = textBlocks(text) }
                }
            case .chatCompletions:
                if object["tool_calls"] != nil, [JSONValue.null, .array([]), .string("")].contains(object["content"] ?? .null) {
                    _ = object.removeValue(forKey: "content")
                }
            case .gemini:
                if case .string(let signature)? = object["thoughtSignature"] {
                    object["thoughtSignature"] = .string(signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
                }
                for key in ["functionCall", "functionResponse"] {
                    if case .object(var call)? = object[key], call["id"]?.stringValue?.hasPrefix("pyd_ai_") == true {
                        _ = call.removeValue(forKey: "id")
                        object[key] = .object(call)
                    }
                }
            case .responses:
                break
            }
            return .object(JSONObject(object.map { ($0.key, canonical($0.value, wire)) }))
        default:
            return value
        }
    }

    /// The text of a string, a text block, or a list of text blocks.
    static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: text
        case .array(let items)?: items.map { text($0) }.joined()
        case .object(let object)?: object["text"].map { text($0) } ?? ""
        default: ""
        }
    }
}
