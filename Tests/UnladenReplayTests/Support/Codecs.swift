import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

/// The four codecs behind one switch, with fixed reply defaults.
enum Codecs {
    static func origin(_ wire: WireProtocol) -> WireSystemID? {
        switch wire {
        case .chatCompletions: nil
        case .responses: "openai"
        case .anthropicMessages: "anthropic"
        case .gemini: "gemini"
        }
    }

    // MARK: Requests

    static func parseRequest(_ bytes: [UInt8], as wire: WireProtocol, model: String = "replay-model", stream: Bool = false) throws -> WireDecoded<WireRequest> {
        switch wire {
        case .chatCompletions: try ChatCompletionsCodec.parseRequest(bytes)
        case .responses: try ResponsesCodec.parseRequest(bytes)
        case .anthropicMessages: try AnthropicMessagesCodec.parseRequest(bytes)
        case .gemini: try GeminiCodec.parseRequest(bytes, model: model, stream: stream)
        }
    }

    /// Encodes a request with each codec's default options (same-protocol
    /// replay trusts the protocol's own system).
    static func buildRequest(_ request: WireRequest, as wire: WireProtocol) -> WireEncoded {
        switch wire {
        case .chatCompletions: ChatCompletionsCodec.buildRequest(request)
        case .responses: ResponsesCodec.buildRequest(request)
        case .anthropicMessages: AnthropicMessagesCodec.buildRequest(request)
        case .gemini: GeminiCodec.buildRequest(request)
        }
    }

    // MARK: Replies

    static func parseResponse(_ bytes: [UInt8], as wire: WireProtocol, origin: WireSystemID?) throws -> WireDecoded<WireResponse> {
        switch wire {
        case .chatCompletions: try ChatCompletionsCodec.parseResponse(bytes, origin: origin)
        case .responses: try ResponsesCodec.parseResponse(bytes, origin: origin)
        case .anthropicMessages: try AnthropicMessagesCodec.parseResponse(bytes, origin: origin)
        case .gemini: try GeminiCodec.parseResponse(bytes, origin: origin)
        }
    }

    static func encodeResponse(_ response: WireResponse, as wire: WireProtocol) -> WireEncoded {
        switch wire {
        case .chatCompletions:
            ChatCompletionsCodec.encodeResponse(response, defaults: ChatResponseDefaults(id: "chatcmpl-replay", model: "replay-model", created: 1_700_000_000))
        case .responses:
            ResponsesCodec.encodeResponse(response, defaults: ResponsesResponseDefaults(id: "resp_replay", model: "replay-model", created: 1_700_000_000))
        case .anthropicMessages:
            AnthropicMessagesCodec.encodeResponse(response, defaults: AnthropicResponseDefaults(id: "msg_replay", model: "replay-model"))
        case .gemini:
            GeminiCodec.encodeResponse(response, defaults: GeminiResponseDefaults(id: "resp-replay", model: "replay-model"))
        }
    }

    // MARK: Streams

    static func decodeStream(_ elements: [SSEElement], as wire: WireProtocol, origin: WireSystemID?) throws -> (events: [WireEvent], warnings: [WireWarning]) {
        var decoder = AnyWireStreamDecoder(for: wire, origin: origin)
        var events: [WireEvent] = []
        for element in elements { events += try decoder.decode(element) }
        events += decoder.finish()
        return (events, decoder.warnings)
    }

    static func encodeStream(_ events: [WireEvent], as wire: WireProtocol) -> (elements: [SSEElement], warnings: [WireWarning]) {
        var elements: [SSEElement] = []
        switch wire {
        case .chatCompletions:
            var encoder = ChatCompletionsStreamEncoder(
                defaults: ChatResponseDefaults(id: "chatcmpl-replay", model: "replay-model", created: 1_700_000_000), includeUsage: true,
            )
            for event in events { elements += encoder.encode(event) }
            elements += encoder.finish()
            return (elements, encoder.warnings)
        case .responses:
            var encoder = ResponsesStreamEncoder(defaults: ResponsesResponseDefaults(id: "resp_replay", model: "replay-model", created: 1_700_000_000))
            for event in events { elements += encoder.encode(event) }
            elements += encoder.finish()
            return (elements, encoder.warnings)
        case .anthropicMessages:
            var encoder = AnthropicMessagesStreamEncoder(defaults: AnthropicResponseDefaults(id: "msg_replay", model: "replay-model"))
            for event in events { elements += encoder.encode(event) }
            elements += encoder.finish()
            return (elements, encoder.warnings)
        case .gemini:
            var encoder = GeminiStreamEncoder(defaults: GeminiResponseDefaults(id: "resp-replay", model: "replay-model"))
            for event in events { elements += encoder.encode(event) }
            elements += encoder.finish()
            return (elements, encoder.warnings)
        }
    }

    /// The protocol's own well-formedness check of an encoded stream.
    static func checkStream(_ elements: [SSEElement], as wire: WireProtocol) -> [String] {
        switch wire {
        case .chatCompletions: checkChatStream(elements)
        case .responses: checkResponsesStream(elements)
        case .anthropicMessages: checkAnthropicStream(elements)
        case .gemini: checkGeminiStream(elements)
        }
    }
}

/// A recorded reply decoded by Unladen: the complete reply (accumulated, for
/// a stream), the events (for a stream), warnings and in-stream errors.
struct DecodedReply {
    var response: WireResponse
    var events: [WireEvent]?
    var warnings: [WireWarning]
    var streamErrors: [WireStreamError]
}

extension Recording {
    func decodeReply(origin: WireSystemID?? = nil) throws -> DecodedReply {
        let origin = origin ?? Codecs.origin(wire)
        if isStream {
            let (events, warnings) = try Codecs.decodeStream(responseElements(), as: wire, origin: origin)
            let accumulator = WireResponseAccumulator(events)
            return DecodedReply(
                response: accumulator.response, events: events,
                warnings: warnings + accumulator.warnings, streamErrors: accumulator.errors,
            )
        }
        let decoded = try Codecs.parseResponse(responseBytes ?? [], as: wire, origin: origin)
        return DecodedReply(response: decoded.value, events: nil, warnings: decoded.warnings, streamErrors: [])
    }
}

// MARK: - Facts

/// What a reply says, in the shape of the importer's `facts`.
struct ReplySummary {
    var text = ""
    var reasoning = ""
    var refusal = ""
    var signedReasoning = false
    var toolCalls: [(name: String, arguments: JSONValue)] = []
    var finish: String?
    var unifiedFinish: WireFinishReason.Unified?
    var inputTokens: Int?
    var outputTokens: Int?
    var error: String?

    init(_ response: WireResponse, errors: [WireStreamError] = []) {
        for part in response.message.parts {
            switch part {
            case .text(let text):
                self.text += text.text
                // Gemini 3 signs text parts too.
                if text.signature != nil { signedReasoning = true }
            case .reasoning(let reasoning):
                self.reasoning += reasoning.text
                if reasoning.hasSignedData { signedReasoning = true }
            case .refusal(let refusal): self.refusal += refusal.text
            case .toolCall(let call):
                toolCalls.append((call.name, Self.arguments(call.arguments)))
                if call.signature != nil { signedReasoning = true }
            default: break
            }
        }
        finish = response.finishReason?.raw
        unifiedFinish = response.finishReason?.unified
        inputTokens = response.usage?.inputTokens
        outputTokens = response.usage?.outputTokens
        error = errors.first?.message
    }

    static func arguments(_ text: String) -> JSONValue {
        if text.allSatisfy(\.isWhitespace) { return .object([:]) }
        return (try? JSONValue(parsing: text))?.canonical ?? .object(["$raw": .string(text)])
    }

    /// Differences from the recording's facts, one line each, keyed by the
    /// fact (`facts.text`, `facts.toolCalls`…) for known-issue lookup.
    func differences(from facts: JSONValue) -> [(check: String, problem: String)] {
        var out: [(String, String)] = []
        func compare<T: Equatable>(_ name: String, _ ours: T, _ theirs: T) {
            if ours != theirs { out.append(("facts.\(name)", "\(name): decoded \(ours), recorded \(theirs)")) }
        }
        compare("text", text, facts["text"]?.stringValue ?? "")
        compare("reasoning", reasoning, facts["reasoning"]?.stringValue ?? "")
        compare("refusal", refusal, facts["refusal"]?.stringValue ?? "")
        compare("signedReasoning", signedReasoning, facts["signedReasoning"] == true)
        let recordedCalls = (facts["toolCalls"]?.arrayValue ?? []).map {
            "\($0["name"]?.stringValue ?? "") \(($0["arguments"] ?? .null).canonical)"
        }
        compare("toolCalls", toolCalls.map { "\($0.name) \($0.arguments)" }, recordedCalls)
        compare("finish", finish, facts["finish"]?.stringValue)
        if facts["blocked"] != nil {
            // A blocked prompt (Gemini `promptFeedback.blockReason`, no
            // candidate) is a content-filter finish.
            compare("finish", unifiedFinish, .contentFilter)
        }
        if let usage = facts["usage"] {
            compare("usage", [inputTokens, outputTokens], [usage["input"]?.numberValue?.int, usage["output"]?.numberValue?.int])
        }
        compare("error", error, facts["error"]?.stringValue)
        return out
    }
}

/// Codes of warnings that note something lost or wrong (as opposed to the
/// lossless bag notes `unknown_field` / `opaque_content`).
func lossyWarnings(_ warnings: [WireWarning], allowing expected: Set<String>) -> [String] {
    warnings
        .filter { ![WireWarning.Code.unknownField, .opaqueContent].contains($0.code) && !expected.contains($0.code.rawValue) }
        .map(\.description)
}
