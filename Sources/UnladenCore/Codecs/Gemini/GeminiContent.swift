// Gemini `generateContent` parts, shared by the request and response
// directions, plus tool ids, finish reasons, usage and the signature replay
// decision.

// MARK: - Signature replay

/// Decides whether a `thoughtSignature` (on a thought, text or function-call
/// part) may be written for a Gemini peer.
///
/// This is the single swap point for the phase-4 endpoint trust sets:
/// everything Gemini-bound asks ``accepts(origin:sameProtocol:trusted:)``.
enum GeminiReplay {
    /// The system id Gemini decoders stamp on signatures by default.
    static let system: WireSystemID = "gemini"

    /// - Data with an origin is accepted iff the origin is trusted.
    /// - Data without one came from a client request; it is accepted only
    ///   when that request was Gemini too (the client is replaying what a
    ///   Gemini reply gave it).
    static func accepts(origin: WireSystemID?, sameProtocol: Bool, trusted: Set<WireSystemID>) -> Bool {
        guard let origin else { return sameProtocol }
        return trusted.contains(origin)
    }
}

// MARK: - Tool ids

/// Gemini function calls and responses may omit `id`; the wire model needs
/// one on every call (see ``WireToolCall``).
///
/// Decoders synthesize ids that start with ``mark`` and set
/// ``WireToolCall/idSynthesized`` / ``WireToolResult/callIDSynthesized``:
/// - requests: `unladen_gc_<content index>_<part index>` (the call's
///   position; a response without id gets its call's id, or its own
///   position when no call matches);
/// - replies: `unladen_gc_<response id>_<n>` for the n-th call, so the ids a
///   client stores stay unique across the turns of a conversation. Without
///   a `responseId` (some relays), `unladen_gc_h<hash>_<n>`, where the hash
///   (64-bit FNV-1a, hex) covers the reply's parts up to and including the
///   call: deterministic for a given reply, different across replies that
///   differ in anything before the call (a reply that repeats an earlier
///   one exactly, signatures included, repeats its ids).
///
/// Gemini encoders omit an id that is marked synthesized *or* starts with
/// ``mark``: a client of another protocol (Chat, Anthropic) echoes the id
/// without the flag, and Gemini must not receive ids it never made. The ids
/// use only `[A-Za-z0-9_-]`, so Anthropic accepts them as they are.
@_spi(Wire) public enum GeminiToolID {
    public static let mark = "unladen_gc_"

    public static func isSynthesized(_ id: String) -> Bool { id.hasPrefix(mark) }

    static func request(content: Int, part: Int) -> String { "\(mark)\(content)_\(part)" }

    /// A running hash of a reply's parts, for ids of replies without a
    /// `responseId`.
    struct ReplySeed: Sendable {
        private var hash: UInt64 = 0xcbf2_9ce4_8422_2325

        private mutating func mix(_ text: String) {
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
            hash ^= 0xff
            hash &*= 0x0000_0100_0000_01b3
        }

        mutating func add(_ part: WirePart) {
            switch part {
            case .text(let text):
                mix("t"); mix(text.text); mix(text.signature ?? "")
            case .reasoning(let reasoning):
                mix("r"); mix(reasoning.text); mix(reasoning.signature ?? "")
            case .toolCall(let call):
                mix("c"); mix(call.name); mix(call.arguments); mix(call.signature ?? "")
            case .opaque(let opaque):
                mix("o"); mix(String(decoding: opaque.value.encoded(), as: UTF8.self))
            case .image, .file, .toolResult, .refusal:
                mix("x")
            }
        }

        var tag: String {
            let hex = String(hash, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }
    }

    /// The id of the `call`-th call of a reply; `seed` must include the
    /// call's part.
    static func reply(responseID: String?, call: Int, seed: ReplySeed) -> String {
        guard let responseID, !responseID.isEmpty else { return "\(mark)h\(seed.tag)_\(call)" }
        let seed = String(responseID.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-": Character(scalar)
            default: "-"
            }
        })
        return "\(mark)\(seed)_\(call)"
    }
}

// MARK: - Decoding

enum GeminiDecode {
    /// Part types kept opaque on purpose (server-side code execution and
    /// tools); they produce no warning.
    static let knownOpaqueKeys: Set<String> = ["executableCode", "codeExecutionResult", "toolCall", "toolResponse"]

    /// The bag key that holds a part's own unknown keys when the part wraps
    /// an inner object (`functionCall`, `functionResponse`, `inlineData`,
    /// `fileData`), whose unknown keys are the bag proper.
    static let partBagKey = "#part"

    /// Decodes a `Content`'s `parts`.
    static func parts(
        _ raw: JSONValue?,
        path: String,
        origin: WireSystemID?,
        isReply: Bool,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> [WirePart] {
        guard let raw, !raw.isNull else { return [] }
        guard case .array(let items) = raw else { throw WireDecodingError(.typeMismatch(expected: "an array"), path: path) }
        var parts: [WirePart] = []
        parts.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            parts.append(try part(item, path: WirePath.index(path, i), origin: origin, isReply: isReply, warnings: &warnings))
        }
        return parts
    }

    /// Decodes one part. Tool calls without `id` get an empty id with
    /// ``WireToolCall/idSynthesized`` set, and responses without `id` an
    /// empty call id with ``WireToolResult/callIDSynthesized`` set: the
    /// caller assigns them (see ``GeminiToolID``).
    ///
    /// - `origin` is stamped on every reasoning part and on text and calls
    ///   that carry a signature (replies); `nil` for client requests.
    /// - `isReply`: media in a reply is kept opaque (as streams deliver it).
    static func part(
        _ value: JSONValue,
        path: String,
        origin: WireSystemID?,
        isReply: Bool,
        warnings: inout [WireWarning],
    ) throws(WireDecodingError) -> WirePart {
        guard case .object(let object) = value else {
            throw WireDecodingError(.typeMismatch(expected: "an object"), path: path)
        }
        func opaque(_ why: String?) -> WirePart {
            if let why { warnings.append(WireWarning(.opaqueContent, why, path: path)) }
            return .opaque(WireOpaque(protocol: .gemini, value: value))
        }
        var reader = FieldReader(object, path: path)
        let signature = object["thoughtSignature"]?.stringValue

        if case .string(let text)? = object["text"] {
            _ = reader.raw("text")
            if signature != nil { _ = reader.raw("thoughtSignature") }
            if object["thought"] == true {
                _ = reader.raw("thought")
                return .reasoning(WireReasoning(
                    text: text, signature: signature, origin: origin, extra: reader.remaining(warnings: &warnings),
                ))
            }
            return .text(WireText(
                text, signature: signature, origin: signature == nil ? nil : origin, extra: reader.remaining(warnings: &warnings),
            ))
        }

        if case .object(let call)? = object["functionCall"] {
            guard case .string(let name)? = call["name"] else { return opaque("functionCall without `name` kept as opaque") }
            var inner = FieldReader(call, path: reader.path("functionCall"))
            _ = inner.raw("name")
            let id = try inner.string("id")
            var arguments = ""
            if let args = call["args"], !args.isNull {
                _ = inner.raw("args")
                arguments = String(decoding: args.encoded(), as: UTF8.self)
            }
            _ = reader.raw("functionCall")
            if signature != nil { _ = reader.raw("thoughtSignature") }
            var extra = inner.remaining(warnings: &warnings)
            let outer = reader.remaining(warnings: &warnings)
            if !outer.isEmpty { extra[partBagKey] = .object(outer) }
            return .toolCall(WireToolCall(
                id: id ?? "", idSynthesized: id == nil, name: name, arguments: arguments,
                signature: signature, origin: signature == nil ? nil : origin, extra: extra,
            ))
        }

        if case .object(let response)? = object["functionResponse"] {
            guard case .string(let name)? = response["name"] else { return opaque("functionResponse without `name` kept as opaque") }
            var inner = FieldReader(response, path: reader.path("functionResponse"))
            _ = inner.raw("name")
            let id = try inner.string("id")
            var result = WireToolResult(callID: id ?? "", callIDSynthesized: id == nil, name: name, content: [])
            if let output = try inner.object("response") {
                if output.count == 1, case .string(let text)? = output["output"] {
                    result.content = [.text(WireText(text))]
                    result.contentForm = .string
                } else if output.count == 1, case .string(let text)? = output["error"] {
                    result.content = [.text(WireText(text))]
                    result.contentForm = .string
                    result.isError = true
                } else {
                    result.content = [.text(WireText(String(decoding: JSONValue.object(output).encoded(), as: UTF8.self)))]
                    result.contentForm = .parts
                }
            } else {
                result.contentForm = .absent
            }
            if let media = try inner.array("parts") {
                for (i, item) in media.enumerated() {
                    result.content.append(try part(
                        item, path: WirePath.index(inner.path("parts"), i), origin: origin, isReply: false, warnings: &warnings,
                    ))
                }
            }
            _ = reader.raw("functionResponse")
            var extra = inner.remaining(warnings: &warnings)
            let outer = reader.remaining(warnings: &warnings)
            if !outer.isEmpty { extra[partBagKey] = .object(outer) }
            result.extra = extra
            return .toolResult(result)
        }

        for key in ["inlineData", "fileData"] {
            guard case .object(let data)? = object[key] else { continue }
            if isReply { return opaque(nil) }
            var inner = FieldReader(data, path: reader.path(key))
            let mediaType: String?
            let source: WireMediaSource
            if key == "inlineData" {
                guard case .string(let type)? = data["mimeType"], case .string(let bytes)? = data["data"] else {
                    return opaque("inlineData without `mimeType` and `data` kept as opaque")
                }
                _ = inner.raw("mimeType")
                _ = inner.raw("data")
                mediaType = type
                source = .base64(bytes)
            } else {
                guard case .string(let uri)? = data["fileUri"] else { return opaque("fileData without `fileUri` kept as opaque") }
                _ = inner.raw("fileUri")
                mediaType = try inner.string("mimeType")
                source = .url(uri)
            }
            _ = reader.raw(key)
            var media = WireMedia(source: source, mediaType: mediaType, extra: inner.remaining(warnings: &warnings))
            let outer = reader.remaining(warnings: &warnings)
            if !outer.isEmpty { media.extra[partBagKey] = .object(outer) }
            return mediaType?.hasPrefix("image/") == true ? .image(media) : .file(media)
        }

        let known = object.keys.contains { knownOpaqueKeys.contains($0) }
        return opaque(known ? nil : "part with keys \(object.keys) kept as opaque")
    }

    /// An in-stream `{"error":{…}}` payload.
    static func streamError(_ value: JSONValue?) -> WireStreamError {
        guard case .object(let object)? = value else {
            return WireStreamError(message: value?.description ?? "unknown error", raw: value)
        }
        return WireStreamError(
            message: object["message"]?.stringValue ?? "",
            type: object["status"]?.stringValue,
            code: object["code"]?.numberValue?.literal,
            raw: value,
        )
    }
}

// MARK: - Encoding

enum GeminiEncode {
    /// Settings that every part encoder needs.
    struct Context {
        /// The target is the source protocol: bags and opaque parts go back.
        var include: Bool
        /// Systems whose signatures the peer accepts.
        var trusted: Set<WireSystemID>
        /// Replies to a client keep reasoning text whose signature cannot be
        /// given (as a thought part without one); requests to an upstream
        /// drop such reasoning.
        var keepUnsignedReasoning: Bool

        func accepts(_ origin: WireSystemID?) -> Bool {
            GeminiReplay.accepts(origin: origin, sameProtocol: include, trusted: trusted)
        }
    }

    /// Encodes one part, or `nil` (with a warning) if Gemini cannot carry
    /// it. Tool calls are encoded by ``functionCall(_:signature:context:path:warnings:)``,
    /// which needs the turn's signature state; here they get their own
    /// accepted signature only.
    static func part(
        _ part: WirePart,
        context: Context,
        path: String,
        callNames: [String: String] = [:],
        warnings: inout [WireWarning],
    ) -> JSONValue? {
        let include = context.include
        var object = JSONObject()
        switch part {
        case .text(let text):
            object["text"] = .string(text.text)
            if let signature = text.signature {
                if context.accepts(text.origin) {
                    object["thoughtSignature"] = .string(signature)
                } else {
                    warnings.append(WireWarning(
                        .droppedContent, "text signature from \(text.origin ?? "another protocol") cannot be carried by Gemini", path: path,
                    ))
                }
            }
            appendExtra(text.extra, to: &object, include: include, path: path, warnings: &warnings)

        case .refusal(let refusal):
            warnings.append(WireWarning(.lossyConversion, "refusal sent as a text part", path: path))
            object["text"] = .string(refusal.text)
            appendExtra(refusal.extra, to: &object, include: false, path: path, warnings: &warnings)

        case .reasoning(let reasoning):
            let accepted = context.accepts(reasoning.origin)
            if reasoning.encrypted != nil {
                warnings.append(WireWarning(.droppedContent, "encrypted reasoning cannot be carried by Gemini", path: path))
                if reasoning.text.isEmpty, reasoning.signature == nil || !accepted { return nil }
            }
            guard accepted || (context.keepUnsignedReasoning && !reasoning.text.isEmpty) else {
                if reasoning.hasSignedData || !reasoning.text.isEmpty {
                    let from = reasoning.origin ?? "another protocol"
                    warnings.append(WireWarning(.droppedContent, "reasoning from \(from) cannot be replayed to Gemini", path: path))
                }
                return nil
            }
            object["text"] = .string(reasoning.text)
            object["thought"] = true
            if let signature = reasoning.signature {
                if accepted {
                    object["thoughtSignature"] = .string(signature)
                } else {
                    warnings.append(WireWarning(
                        .droppedContent, "reasoning signature from \(reasoning.origin ?? "another protocol") cannot be carried by Gemini",
                        path: path,
                    ))
                }
            }
            appendExtra(reasoning.extra, to: &object, include: include, path: path, warnings: &warnings)

        case .image(let media), .file(let media):
            var data = JSONObject()
            let key: String
            switch media.source {
            case .base64(let bytes):
                key = "inlineData"
                data["mimeType"] = .string(media.mediaType ?? (part.isImage ? "image/png" : "application/octet-stream"))
                data["data"] = .string(bytes)
            case .url(let url):
                if let parsed = DataURL.parse(url) {
                    key = "inlineData"
                    data["mimeType"] = .string(parsed.mediaType)
                    data["data"] = .string(parsed.data)
                } else {
                    key = "fileData"
                    if let type = media.mediaType { data["mimeType"] = .string(type) }
                    data["fileUri"] = .string(url)
                }
            case .fileID:
                warnings.append(WireWarning(.droppedContent, "provider file ids cannot be carried by Gemini", path: path))
                return nil
            }
            if media.detail != nil {
                warnings.append(WireWarning(.droppedField, "Gemini parts have no image detail setting", path: WirePath.key(path, "detail")))
            }
            if media.filename != nil {
                warnings.append(WireWarning(.droppedField, "Gemini parts have no file name", path: WirePath.key(path, "filename")))
            }
            var extra = media.extra
            let outer = extra.removeValue(forKey: GeminiDecode.partBagKey)
            appendExtra(extra, to: &data, include: include, path: WirePath.key(path, key), warnings: &warnings)
            object[key] = .object(data)
            if case .object(let outer)? = outer {
                appendExtra(outer, to: &object, include: include, path: path, warnings: &warnings)
            }

        case .toolCall(let call):
            let signature = call.signature.flatMap { context.accepts(call.origin) ? $0 : nil }
            if call.signature != nil, signature == nil {
                warnings.append(WireWarning(
                    .droppedContent, "tool call signature from \(call.origin ?? "another protocol") cannot be carried by Gemini", path: path,
                ))
            }
            return functionCall(call, signature: signature, context: context, path: path, warnings: &warnings)

        case .toolResult(let result):
            var response = JSONObject()
            if !omitsID(result.callID, synthesized: result.callIDSynthesized) { response["id"] = .string(result.callID) }
            let name = result.name ?? callNames[result.callID]
            if name == nil {
                warnings.append(WireWarning(.lossyConversion, "tool result without a known function name", path: path))
            }
            response["name"] = .string(name ?? "")
            let texts = result.content.compactMap { part -> String? in
                if case .text(let text) = part { return text.text }
                return nil
            }
            let joined = texts.joined()
            if texts.count > 1 {
                warnings.append(WireWarning(.lossyConversion, "tool result text parts joined", path: path))
            }
            if include, result.contentForm == .parts, texts.count == 1,
               case .object(let whole)? = try? JSONValue(parsing: joined)
            {
                response["response"] = .object(whole)
            } else if !(include && result.contentForm == .absent && texts.isEmpty) {
                response["response"] = [result.isError == true ? "error" : "output": .string(joined)]
            }
            var media: [JSONValue] = []
            for (i, inner) in result.content.enumerated() {
                switch inner {
                case .text: continue
                case .image, .file, .opaque:
                    if let encoded = self.part(inner, context: context, path: WirePath.index(WirePath.key(path, "parts"), i), warnings: &warnings) {
                        media.append(encoded)
                    }
                default:
                    warnings.append(WireWarning(.droppedContent, "content cannot appear in a functionResponse", path: path))
                }
            }
            if !media.isEmpty { response["parts"] = .array(media) }
            if let itemType = result.itemType {
                warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a functionResponse", path: path))
            }
            var extra = result.extra
            let outer = extra.removeValue(forKey: GeminiDecode.partBagKey)
            appendExtra(extra, to: &response, include: include, path: WirePath.key(path, "functionResponse"), warnings: &warnings)
            object["functionResponse"] = .object(response)
            if case .object(let outer)? = outer {
                appendExtra(outer, to: &object, include: include, path: path, warnings: &warnings)
            }

        case .opaque(let opaque):
            guard opaque.protocol == .gemini else {
                warnings.append(WireWarning(.droppedContent, "\(opaque.protocol.rawValue) content cannot be carried by Gemini", path: path))
                return nil
            }
            return opaque.value
        }
        return .object(object)
    }

    /// A `functionCall` part with `signature` (already accepted, or a
    /// fallback) as its `thoughtSignature`.
    static func functionCall(
        _ call: WireToolCall,
        signature: String?,
        context: Context,
        path: String,
        warnings: inout [WireWarning],
    ) -> JSONValue {
        var inner = JSONObject()
        if !omitsID(call.id, synthesized: call.idSynthesized) { inner["id"] = .string(call.id) }
        inner["name"] = .string(call.name)
        if !call.arguments.trimmingASCIIWhitespace().isEmpty {
            inner["args"] = args(call.arguments, path: WirePath.key(path, "functionCall.args"), warnings: &warnings)
        }
        if let itemType = call.itemType {
            warnings.append(WireWarning(.lossyConversion, "`\(itemType)` sent as a functionCall", path: path))
        }
        var extra = call.extra
        let outer = extra.removeValue(forKey: GeminiDecode.partBagKey)
        appendExtra(extra, to: &inner, include: context.include, path: WirePath.key(path, "functionCall"), warnings: &warnings)
        var object = JSONObject()
        object["functionCall"] = .object(inner)
        if let signature { object["thoughtSignature"] = .string(signature) }
        if case .object(let outer)? = outer {
            appendExtra(outer, to: &object, include: context.include, path: path, warnings: &warnings)
        }
        return .object(object)
    }

    /// `true` if an id must not be sent to Gemini (see ``GeminiToolID``).
    static func omitsID(_ id: String, synthesized: Bool) -> Bool {
        synthesized || id.isEmpty || GeminiToolID.isSynthesized(id)
    }

    /// The `args` object for tool-call arguments. Gemini accepts only an
    /// object: text that is not a JSON object becomes `{}` with a warning,
    /// as for Anthropic's `input`.
    static func args(_ arguments: String, path: String, warnings: inout [WireWarning]) -> JSONValue {
        AnthropicEncode.toolInput(arguments, path: path, warnings: &warnings)
    }
}

extension WirePart {
    var isImage: Bool {
        if case .image = self { return true }
        return false
    }

    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}

// MARK: - Finish reasons and usage

enum GeminiFinish {
    /// Reply keys outside the candidate that describe how it finished;
    /// they live in ``WireResponse/choiceExtra`` / ``WireFinish/extra`` with
    /// the candidate's own keys, and are written at the top level.
    static let topLevelKeys: Set<String> = ["promptFeedback"]

    static func decode(_ raw: String, hasToolCalls: Bool) -> WireFinishReason {
        let unified: WireFinishReason.Unified = switch raw {
        case "STOP": hasToolCalls ? .toolCalls : .stop
        case "MAX_TOKENS": .length
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT",
             "IMAGE_RECITATION":
            .contentFilter
        case "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS": .error
        default: .other // LANGUAGE, OTHER, FINISH_REASON_UNSPECIFIED, NO_IMAGE, unknown
        }
        return WireFinishReason(unified, raw: raw)
    }

    /// A blocked prompt (`promptFeedback.blockReason` without candidates).
    static let blockedPrompt = WireFinishReason(.contentFilter)

    static func encode(_ reason: WireFinishReason?, sameProtocol: Bool) -> String {
        guard let reason else { return "STOP" }
        if sameProtocol, let raw = reason.raw { return raw }
        return switch reason.unified {
        case .stop, .toolCalls, .other: "STOP"
        case .length: "MAX_TOKENS"
        case .contentFilter: "SAFETY"
        case .error: "OTHER"
        }
    }

    /// `true` if a same-protocol reply had no candidate: a blocked prompt.
    static func isBlockedPrompt(_ extra: JSONObject, reason: WireFinishReason?, hasParts: Bool) -> Bool {
        !hasParts && reason == blockedPrompt && extra["promptFeedback"]?["blockReason"] != nil
    }
}

/// `usageMetadata` ↔ ``WireUsage``.
///
/// Gemini counts thoughts apart from the answer: `candidatesTokenCount`
/// excludes `thoughtsTokenCount`. The wire model counts reasoning inside
/// output, so ``WireUsage/outputTokens`` = candidates + thoughts and
/// ``WireUsage/reasoningTokens`` = thoughts; encoding subtracts again.
/// `promptTokenCount` already includes `cachedContentTokenCount`, as
/// ``WireUsage/inputTokens`` does. Detail arrays (`promptTokensDetails`…),
/// `toolUsePromptTokenCount` and `trafficType` stay in the bag.
enum GeminiUsage {
    static func decode(_ object: JSONObject, path: String) throws(WireDecodingError) -> WireUsage {
        var ignored: [WireWarning] = []
        var reader = FieldReader(object, path: path)
        var usage = WireUsage()
        usage.inputTokens = try reader.int("promptTokenCount")
        let candidates = try reader.int("candidatesTokenCount")
        usage.reasoningTokens = try reader.int("thoughtsTokenCount")
        usage.outputTokens = candidates.map { $0 + (usage.reasoningTokens ?? 0) }
        usage.cachedInputTokens = try reader.int("cachedContentTokenCount")
        usage.totalTokens = try reader.int("totalTokenCount")
        usage.extra = reader.remaining(warnings: &ignored)
        return usage
    }

    /// Encodes usage. Another protocol's usage gets `totalTokenCount`
    /// computed when it is missing.
    static func encode(_ usage: WireUsage, include: Bool) -> JSONValue {
        var object = JSONObject()
        if let value = usage.inputTokens { object["promptTokenCount"] = .number(JSONNumber(value)) }
        if let output = usage.outputTokens {
            object["candidatesTokenCount"] = .number(JSONNumber(max(output - (usage.reasoningTokens ?? 0), 0)))
        }
        if let value = usage.totalTokens ?? (include ? nil : sum(usage.inputTokens, usage.outputTokens)) {
            object["totalTokenCount"] = .number(JSONNumber(value))
        }
        if let value = usage.cachedInputTokens { object["cachedContentTokenCount"] = .number(JSONNumber(value)) }
        if let value = usage.reasoningTokens { object["thoughtsTokenCount"] = .number(JSONNumber(value)) }
        var ignored: [WireWarning] = []
        appendExtra(usage.extra, to: &object, include: include, path: "usageMetadata", warnings: &ignored)
        return .object(object)
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        return a + b
    }
}
