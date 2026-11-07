// The implementations behind ``ProfileTransform``. Each is a pure function
// on the wire model, tested on its own.

@_spi(Wire) public enum WireTransforms {
    /// The text of a synthesized result for a call that got none.
    public static let interruptedResult = "[The result of this tool call is unavailable: the turn was interrupted.]"
    /// The reasoning text given to a turn that must carry some but has none
    /// (a space: an empty string is left out by some relays, and rejected
    /// by DeepSeek's Responses API).
    public static let placeholderReasoning = " "

    static func isResult(_ part: WirePart) -> Bool {
        if case .toolResult = part { return true }
        return false
    }

    static func isCall(_ part: WirePart) -> Bool {
        if case .toolCall = part { return true }
        return false
    }

    // MARK: - developerToSystem

    public static func developerToSystem(_ request: inout WireRequest) {
        for i in request.messages.indices where request.messages[i].role == .developer {
            request.messages[i].role = .system
        }
    }

    // MARK: - pairToolCalls

    /// See ``ProfileTransform/pairToolCalls``.
    ///
    /// An exchange opens with a run of consecutive assistant messages (one
    /// model turn, which Responses splits into several items) and closes at
    /// the first message that is neither an assistant message nor a message
    /// carrying only tool results. Missing results are added where the
    /// exchange closes: inside a `user` message that carries results
    /// (Anthropic/Gemini style), else as new messages in the style the
    /// request uses (`tool` messages for Chat, role-less items for
    /// Responses, one `user` message otherwise).
    public static func pairToolCalls(_ request: inout WireRequest, warnings: inout [WireWarning]) {
        let style: WireRole = request.messages.last { $0.role != .assistant && $0.parts.contains(where: isResult) }?.role
            ?? (request.source == .chatCompletions ? .tool : request.source == .responses ? .item : .user)
        var out: [WireMessage] = []
        var pending: [WireToolCall] = []
        var answered: Set<String> = []
        var previousWasAssistant = false

        func missingResults() -> [WirePart] {
            let missing = pending.filter { !answered.contains($0.id) }
            for call in missing {
                answered.insert(call.id)
                warnings.append(WireWarning(.adjusted, "tool call `\(call.id)` had no result; sent an interrupted result", path: "messages"))
            }
            return missing.map { call in
                .toolResult(WireToolResult(
                    callID: call.id, callIDSynthesized: call.idSynthesized, name: call.name,
                    content: [.text(WireText(interruptedResult))], isError: true,
                    itemType: call.itemType == "custom_tool_call" ? "custom_tool_call_output" : nil,
                ))
            }
        }
        func close() {
            let parts = missingResults()
            if !parts.isEmpty {
                if style == .user {
                    out.append(WireMessage(role: .user, parts: parts))
                } else {
                    out += parts.map { WireMessage(role: style, parts: [$0]) }
                }
            }
            pending = []
            answered = []
        }

        for (i, message) in request.messages.enumerated() {
            if message.role == .assistant {
                if !previousWasAssistant { close() }
                for part in message.parts {
                    if case .toolCall(let call) = part { pending.append(call) }
                }
                out.append(message)
                previousWasAssistant = true
                continue
            }
            previousWasAssistant = false
            guard message.parts.contains(where: isResult) else {
                close()
                out.append(message)
                continue
            }
            var parts: [WirePart] = []
            var lastResult: Int?
            for (j, part) in message.parts.enumerated() {
                guard case .toolResult(let result) = part else {
                    parts.append(part)
                    continue
                }
                if pending.contains(where: { $0.id == result.callID }), !answered.contains(result.callID) {
                    answered.insert(result.callID)
                    parts.append(part)
                    lastResult = parts.count - 1
                } else {
                    warnings.append(WireWarning(
                        .adjusted, "tool result for `\(result.callID)` answers no open call; dropped",
                        path: "messages[\(i)].parts[\(j)]",
                    ))
                }
            }
            let next = request.messages.indices.contains(i + 1) ? request.messages[i + 1] : nil
            let continues = next.map { $0.role != .assistant && $0.parts.allSatisfy(isResult) && !$0.parts.isEmpty } ?? false
            let hasOther = parts.contains { !isResult($0) }
            let closes = hasOther || !continues
            if closes, message.role == .user {
                parts.insert(contentsOf: missingResults(), at: (lastResult ?? -1) + 1)
            }
            if !parts.isEmpty {
                var kept = message
                kept.parts = parts
                out.append(kept)
            }
            if closes { close() }
        }
        close()
        request.messages = out
    }

    // MARK: - stripForeignReasoning

    /// See ``ProfileTransform/stripForeignReasoning``.
    public static func stripForeignReasoning(_ request: inout WireRequest, trusted: Set<String>, warnings: inout [WireWarning]) {
        for i in request.messages.indices where request.messages[i].role == .assistant {
            let path = "messages[\(i)]"
            var parts: [WirePart] = []
            for part in request.messages[i].parts {
                guard case .reasoning(var reasoning) = part, let origin = reasoning.origin, !trusted.contains(origin) else {
                    parts.append(part)
                    continue
                }
                if reasoning.hasSignedData {
                    warnings.append(WireWarning(.droppedContent, "reasoning data from \(origin) stripped; text kept", path: path))
                }
                reasoning.signature = nil
                reasoning.encrypted = nil
                reasoning.itemID = nil
                reasoning.summaryIndex = nil
                reasoning.origin = nil
                if !reasoning.text.isEmpty { parts.append(.reasoning(reasoning)) }
            }
            if let details = request.messages[i].extra.removeValue(forKey: "reasoning_details") {
                warnings.append(WireWarning(.droppedField, "`reasoning_details` removed; its text kept as reasoning", path: path))
                let hasText = parts.contains { part in
                    if case .reasoning(let reasoning) = part { return !reasoning.text.isEmpty }
                    return false
                }
                let text = reasoningDetailsText(details)
                if !hasText, !text.isEmpty {
                    parts.insert(.reasoning(WireReasoning(text: text)), at: 0)
                }
            }
            request.messages[i].parts = parts
        }
    }

    /// The readable text of an OpenRouter-style `reasoning_details` list.
    static func reasoningDetailsText(_ value: JSONValue) -> String {
        guard case .array(let entries) = value else { return "" }
        var text = ""
        for entry in entries {
            switch entry["type"]?.stringValue {
            case "reasoning.text": text += entry["text"]?.stringValue ?? ""
            case "reasoning.summary": text += entry["summary"]?.stringValue ?? ""
            default: break
            }
        }
        return text
    }

    // MARK: - replayReasoningContent / ensureThinkingOnToolTurns

    /// Calls `body` for each run of consecutive assistant messages (one model
    /// turn), with whether the turn follows tool results.
    private static func forEachAssistantTurn(
        _ request: inout WireRequest,
        afterToolResets: (WireMessage) -> Bool?,
        _ body: (inout ArraySlice<WireMessage>, _ afterTool: Bool) -> Void,
    ) {
        var afterTool = false
        var i = 0
        while i < request.messages.count {
            let message = request.messages[i]
            guard message.role == .assistant else {
                if let value = afterToolResets(message) { afterTool = value }
                i += 1
                continue
            }
            var j = i
            while j < request.messages.count, request.messages[j].role == .assistant { j += 1 }
            body(&request.messages[i..<j], afterTool)
            i = j
        }
    }

    /// See ``ProfileTransform/replayReasoningContent``. A turn continues
    /// after a tool result until the next user message.
    public static func replayReasoningContent(_ request: inout WireRequest) {
        // The upstream reads `reasoning_content` only: another Chat vendor's
        // spelling (OpenRouter's `reasoning`) would go unread.
        for i in request.messages.indices where request.messages[i].role == .assistant {
            for p in request.messages[i].parts.indices {
                guard case .reasoning(var reasoning) = request.messages[i].parts[p], reasoning.sourceKey != nil else { continue }
                reasoning.sourceKey = nil
                request.messages[i].parts[p] = .reasoning(reasoning)
            }
        }
        forEachAssistantTurn(&request, afterToolResets: { message in
            if message.parts.contains(where: isResult) { return true }
            return message.role == .user ? false : nil
        }) { turn, afterTool in
            let calls = turn.contains { $0.parts.contains(where: isCall) }
            guard calls || afterTool else { return }
            ensureReasoning(in: &turn)
        }
    }

    /// Gives a turn reasoning text if it has none: fills the first empty
    /// reasoning part, else inserts one at the start.
    private static func ensureReasoning(in turn: inout ArraySlice<WireMessage>) {
        var firstEmpty: (Int, Int)?
        for m in turn.indices {
            for (p, part) in turn[m].parts.enumerated() {
                guard case .reasoning(let reasoning) = part else { continue }
                if !reasoning.text.isEmpty { return }
                if firstEmpty == nil { firstEmpty = (m, p) }
            }
        }
        if let (m, p) = firstEmpty, case .reasoning(var reasoning) = turn[m].parts[p] {
            reasoning.text = placeholderReasoning
            turn[m].parts[p] = .reasoning(reasoning)
        } else if let first = turn.indices.first {
            turn[first].parts.insert(.reasoning(WireReasoning(text: placeholderReasoning)), at: 0)
        }
    }

    /// See ``ProfileTransform/ensureThinkingOnToolTurns``. A turn "follows
    /// tool results" when the message before it carries tool results alone.
    /// Redacted reasoning (``WireReasoning/encrypted``) becomes a
    /// placeholder thinking block when the turn has no other thinking, and
    /// is removed otherwise.
    public static func ensureThinkingOnToolTurns(_ request: inout WireRequest) {
        forEachAssistantTurn(&request, afterToolResets: { message in
            !message.parts.isEmpty && message.parts.allSatisfy(isResult)
        }) { turn, afterTool in
            let plain = turn.contains { message in
                message.parts.contains { part in
                    if case .reasoning(let reasoning) = part { return reasoning.encrypted == nil }
                    return false
                }
            }
            var converted = plain
            for m in turn.indices {
                turn[m].parts = turn[m].parts.compactMap { part in
                    guard case .reasoning(let reasoning) = part, reasoning.encrypted != nil else { return part }
                    if converted { return nil }
                    converted = true
                    return .reasoning(WireReasoning(text: placeholderReasoning))
                }
            }
            let calls = turn.contains { $0.parts.contains(where: isCall) }
            let thinks = turn.contains { $0.parts.contains { if case .reasoning = $0 { true } else { false } } }
            if (calls || afterTool), !thinks, let first = turn.indices.first {
                turn[first].parts.insert(.reasoning(WireReasoning(text: placeholderReasoning)), at: 0)
            }
        }
    }

    // MARK: - flattenTextParts

    /// See ``ProfileTransform/flattenTextParts``: content made only of text
    /// parts without bags is joined with newlines into one part and marked
    /// ``WireContentForm/string``.
    public static func flattenTextParts(_ request: inout WireRequest, warnings: inout [WireWarning]) {
        let sameProtocol = request.source == .chatCompletions
        func flatten(_ parts: inout [WirePart], _ form: inout WireContentForm?) {
            var texts: [WireText] = []
            for part in parts {
                guard case .text(let text) = part, !(sameProtocol && !text.extra.isEmpty) else { return }
                texts.append(text)
            }
            guard var first = texts.first else { return }
            if texts.count > 1 {
                first.text = texts.map(\.text).joined(separator: "\n")
                parts = [.text(first)]
            }
            form = .string
        }
        if var parts = request.instructions {
            flatten(&parts, &request.instructionsForm)
            request.instructions = parts
        }
        for i in request.messages.indices {
            var message = request.messages[i]
            if !message.parts.contains(where: isResult) {
                flatten(&message.parts, &message.contentForm)
            }
            for p in message.parts.indices {
                guard case .toolResult(var result) = message.parts[p] else { continue }
                flatten(&result.content, &result.contentForm)
                message.parts[p] = .toolResult(result)
            }
            request.messages[i] = message
        }
    }

    // MARK: - mapReasoningEffort

    /// `effort` clamped to `levels`: kept if listed, else the next listed
    /// level above it, else the highest below. `nil` for `none` when `none`
    /// is not listed (no level means "no reasoning"). Unknown names are kept.
    public static func clampEffort(_ effort: String, to levels: [String]) -> String? {
        if levels.isEmpty || levels.contains(effort) { return effort }
        guard let rank = Profile.effortOrder.firstIndex(of: effort) else { return effort }
        if effort == "none" { return nil }
        let ranked = levels.compactMap { level in Profile.effortOrder.firstIndex(of: level).map { (level, $0) } }
        if let above = ranked.filter({ $0.1 > rank }).min(by: { $0.1 < $1.1 }) { return above.0 }
        return ranked.filter { $0.1 < rank }.max { $0.1 < $1.1 }?.0 ?? effort
    }

    /// The level whose budget is the smallest at least `budget`, else the
    /// largest; restricted to `levels` when given.
    static func effort(forBudget budget: Int, table: [String: Int], levels: [String]?) -> String? {
        let candidates = table.filter { levels?.contains($0.key) ?? true }
            .sorted { ($0.value, Profile.effortOrder.firstIndex(of: $0.key) ?? 0) < ($1.value, Profile.effortOrder.firstIndex(of: $1.key) ?? 0) }
        return (candidates.first { $0.value >= budget } ?? candidates.last)?.key
    }

    /// See ``ProfileTransform/mapReasoningEffort``.
    public static func mapReasoningEffort(_ request: inout WireRequest, profile: Profile, warnings: inout [WireWarning]) {
        guard var reasoning = request.reasoning else { return }
        let table = profile.effortBudgets ?? Profile.standardEffortBudgets
        let path = "reasoning"
        func clamp() {
            guard let effort = reasoning.effort, let levels = profile.effortLevels else { return }
            let clamped = clampEffort(effort, to: levels)
            guard clamped != effort else { return }
            if let clamped {
                warnings.append(WireWarning(.adjusted, "effort `\(effort)` sent as `\(clamped)`", path: path))
            } else {
                warnings.append(WireWarning(.adjusted, "effort `none` is not a level of this model; reasoning switched off", path: path))
                reasoning.enabled = false
            }
            reasoning.effort = clamped
        }
        switch profile.reasoningControl {
        case nil:
            clamp()
        case .uncontrolled?:
            warnings.append(WireWarning(.unsupportedByModel, "this model takes no reasoning settings", path: path))
            request.reasoning = nil
            return
        case .effort?, .thinkingLevel?:
            if reasoning.effort == nil, let budget = reasoning.budgetTokens {
                reasoning.budgetTokens = nil
                if budget <= 0 {
                    reasoning.enabled = false
                    if profile.effortLevels?.contains("none") == true { reasoning.effort = "none" }
                    warnings.append(WireWarning(.adjusted, "thinking budget 0 sent as reasoning off", path: path))
                } else if let level = effort(forBudget: budget, table: table, levels: profile.effortLevels) {
                    reasoning.effort = level
                    if reasoning.enabled == nil { reasoning.enabled = true }
                    warnings.append(WireWarning(.adjusted, "thinking budget \(budget) sent as effort `\(level)`", path: path))
                }
            }
            clamp()
        case .budget?:
            if let effort = reasoning.effort {
                let keepsEffort = profile.effortLevels.map { clampEffort(effort, to: $0) != nil } ?? false
                if reasoning.budgetTokens == nil {
                    if effort == "none" {
                        reasoning.enabled = false
                        warnings.append(WireWarning(.adjusted, "effort `none` sent as thinking off", path: path))
                    } else {
                        let key = clampEffort(effort, to: Array(table.keys)) ?? effort
                        if let budget = table[key] {
                            reasoning.budgetTokens = budget
                            if reasoning.enabled == nil { reasoning.enabled = true }
                            warnings.append(WireWarning(.adjusted, "effort `\(effort)` sent as thinking budget \(budget)", path: path))
                        }
                    }
                }
                if keepsEffort {
                    clamp()
                } else {
                    reasoning.effort = nil
                }
            }
        }
        request.reasoning = reasoning
    }

    // MARK: - mistralToolIDs

    /// Whether `id` is a Mistral tool call id: nine ASCII letters and digits.
    static func isMistralToolID(_ id: String) -> Bool {
        id.utf8.count == 9 && id.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }

    /// Nine base-62 digits of the 64-bit FNV-1a hash of `id` (and `attempt`,
    /// when retrying after a collision).
    static func mistralToolID(for id: String, attempt: Int) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var bytes = Array(id.utf8)
        if attempt > 0 { bytes += [0] + Array(String(attempt).utf8) }
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        var out: [UInt8] = []
        for _ in 0..<9 {
            out.append(digits[Int(hash % 62)])
            hash /= 62
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// See ``ProfileTransform/mistralToolIDs``.
    public static func mistralToolIDs(_ request: inout WireRequest) {
        // Ids in order of first appearance, calls before results.
        var order: [String] = []
        var seen: Set<String> = []
        for message in request.messages {
            for part in message.parts {
                if case .toolCall(let call) = part, seen.insert(call.id).inserted { order.append(call.id) }
            }
        }
        for message in request.messages {
            for part in message.parts {
                if case .toolResult(let result) = part, seen.insert(result.callID).inserted { order.append(result.callID) }
            }
        }
        // Valid ids keep theirs; the others take the first free hash.
        var taken = Set(order.filter(isMistralToolID))
        var mapping: [String: String] = [:]
        for id in order where !isMistralToolID(id) {
            var attempt = 0
            var candidate = mistralToolID(for: id, attempt: attempt)
            while taken.contains(candidate) {
                attempt += 1
                candidate = mistralToolID(for: id, attempt: attempt)
            }
            taken.insert(candidate)
            mapping[id] = candidate
        }
        guard !mapping.isEmpty else { return }
        for i in request.messages.indices {
            for j in request.messages[i].parts.indices {
                switch request.messages[i].parts[j] {
                case .toolCall(var call):
                    guard let id = mapping[call.id] else { continue }
                    call.id = id
                    request.messages[i].parts[j] = .toolCall(call)
                case .toolResult(var result):
                    guard let id = mapping[result.callID] else { continue }
                    result.callID = id
                    request.messages[i].parts[j] = .toolResult(result)
                default:
                    continue
                }
            }
        }
    }

    // MARK: - dropUnsupportedParams

    /// `true` when thinking is switched on (not by an effort alone).
    static func reasoningActive(_ request: WireRequest) -> Bool {
        guard let reasoning = request.reasoning, reasoning.enabled != false else { return false }
        return reasoning.enabled == true || (reasoning.budgetTokens ?? 0) > 0
    }

    /// See ``ProfileTransform/dropUnsupportedParams``.
    public static func dropUnsupportedParams(_ request: inout WireRequest, profile: Profile, warnings: inout [WireWarning]) {
        var unsupported = profile.unsupportedParameters ?? []
        if profile.supportsTemperature == false { unsupported.insert(.temperature) }
        if reasoningActive(request) { unsupported.formUnion(profile.unsupportedParametersWhileReasoning ?? []) }
        for parameter in SamplingParameter.allCases where unsupported.contains(parameter) {
            var present = false
            switch parameter {
            case .temperature: present = request.temperature != nil; request.temperature = nil
            case .topP: present = request.topP != nil; request.topP = nil
            case .topK: present = request.topK != nil; request.topK = nil
            case .frequencyPenalty: present = request.frequencyPenalty != nil; request.frequencyPenalty = nil
            case .presencePenalty: present = request.presencePenalty != nil; request.presencePenalty = nil
            case .seed: present = request.seed != nil; request.seed = nil
            case .stop: present = request.stop != nil; request.stop = nil
            case .candidateCount: present = request.candidateCount != nil; request.candidateCount = nil
            case .responseFormat: present = request.responseFormat != nil; request.responseFormat = nil
            case .user: present = request.user != nil; request.user = nil
            case .parallelToolCalls: present = request.parallelToolCalls == false; request.parallelToolCalls = nil
            }
            if present {
                warnings.append(WireWarning(.unsupportedByModel, "this model does not accept `\(parameter.rawValue)`", path: parameter.rawValue))
            }
        }
        if profile.supportsReasoning == false, request.reasoning != nil {
            request.reasoning = nil
            warnings.append(WireWarning(.unsupportedByModel, "this model does not reason", path: "reasoning"))
        }
        if profile.supportsTools == false, request.tools != nil || request.toolChoice != nil || request.parallelToolCalls != nil {
            request.tools = nil
            request.toolChoice = nil
            request.parallelToolCalls = nil
            warnings.append(WireWarning(.unsupportedByModel, "this model does not take tools", path: "tools"))
        }
        // Images are content, not a parameter: dropping one stays a lossy
        // `dropped_content`, escalated by a strict policy.
        if profile.supportsImages == false {
            func strip(_ parts: [WirePart], path: String) -> [WirePart] {
                parts.compactMap { part in
                    switch part {
                    case .image:
                        warnings.append(WireWarning(.droppedContent, "this model does not take images", path: path))
                        return nil
                    case .toolResult(var result):
                        result.content = strip(result.content, path: path)
                        return .toolResult(result)
                    default:
                        return part
                    }
                }
            }
            for i in request.messages.indices {
                request.messages[i].parts = strip(request.messages[i].parts, path: "messages[\(i)]")
            }
        }
    }

    // MARK: - customToolsToFunctions

    /// Whether a tool is a Responses `custom` tool; its name if so.
    static func customToolName(_ tool: WireTool) -> String? {
        guard case .opaque(let opaque) = tool, opaque.protocol == .responses,
              opaque.value["type"] == "custom", let name = opaque.value["name"]?.stringValue
        else { return nil }
        return name
    }

    /// See ``ProfileTransform/customToolsToFunctions``. Returns the names of
    /// the tools converted.
    ///
    /// A `custom` tool `{name, description, format}` becomes a function with
    /// parameters `{"input": string}` (a grammar format is quoted in the
    /// input's description); history `custom_tool_call`s get arguments
    /// `{"input": <raw input>}` and lose their item type, as do their
    /// outputs; a `{"type":"custom","name":…}` tool choice becomes a
    /// function choice.
    public static func customToolsToFunctions(_ request: inout WireRequest, warnings: inout [WireWarning]) -> Set<String> {
        var names: Set<String> = []
        if let tools = request.tools {
            request.tools = tools.map { tool in
                guard customToolName(tool) != nil, case .opaque(let opaque) = tool, let name = opaque.value["name"]?.stringValue else {
                    return tool
                }
                names.insert(name)
                var input: JSONObject = ["type": "string", "description": "The raw input for this tool."]
                if let format = opaque.value["format"], format["type"] == "grammar",
                   let definition = format["definition"]?.stringValue
                {
                    let syntax = format["syntax"]?.stringValue ?? "grammar"
                    input["description"] = .string("The raw input for this tool. It must follow this \(syntax) grammar:\n\(definition)")
                }
                let parameters: JSONValue = [
                    "type": "object",
                    "properties": ["input": .object(input)],
                    "required": ["input"],
                    "additionalProperties": false,
                ]
                warnings.append(WireWarning(.adjusted, "custom tool `\(name)` sent as a function tool", path: "tools"))
                return .function(WireFunctionTool(name: name, description: opaque.value["description"]?.stringValue, parameters: parameters))
            }
        }
        if case .opaque(let opaque)? = request.toolChoice, opaque.protocol == .responses,
           opaque.value["type"] == "custom", let name = opaque.value["name"]?.stringValue
        {
            request.toolChoice = .function(name)
        }
        for i in request.messages.indices {
            for p in request.messages[i].parts.indices {
                switch request.messages[i].parts[p] {
                case .toolCall(var call) where call.itemType == "custom_tool_call":
                    call.arguments = JSONValue.object(["input": .string(call.arguments)]).encoded().utf8String
                    call.itemType = nil
                    request.messages[i].parts[p] = .toolCall(call)
                case .toolResult(var result) where result.itemType == "custom_tool_call_output":
                    result.itemType = nil
                    request.messages[i].parts[p] = .toolResult(result)
                default:
                    break
                }
            }
        }
        return names
    }
}

extension [UInt8] {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}

/// The reply half of ``ProfileTransform/customToolsToFunctions``: turns calls
/// of converted tools back into `custom_tool_call`s whose input is the raw
/// text, so a Responses client sees the tool it declared.
///
/// It is reply-side state built from the request's transform outcome
/// (``WireTransformOutcome/customTools``); the upstream call applies it.
@_spi(Wire) public struct CustomToolReplyMapper: Sendable {
    public let names: Set<String>
    private var buffered: [String: String] = [:]

    public init(names: Set<String>) {
        self.names = names
    }

    public var isEmpty: Bool { names.isEmpty }

    /// The raw input inside `{"input": …}` arguments, or the arguments
    /// unchanged if they are not that shape.
    public static func rawInput(_ arguments: String) -> String {
        guard let value = try? JSONValue(parsing: Array(arguments.utf8)), case .string(let input)? = value["input"] else {
            return arguments
        }
        return input
    }

    private func mapped(_ call: WireToolCall) -> WireToolCall? {
        guard names.contains(call.name), call.itemType == nil else { return nil }
        var call = call
        call.itemType = "custom_tool_call"
        call.arguments = Self.rawInput(call.arguments)
        return call
    }

    public func map(_ response: WireResponse) -> WireResponse {
        guard !isEmpty else { return response }
        var response = response
        response.message.parts = response.message.parts.map { part in
            if case .toolCall(let call) = part, let custom = mapped(call) { return .toolCall(custom) }
            return part
        }
        return response
    }

    /// Maps one stream event. Argument deltas of converted calls are held
    /// until the call's input ends, then sent as one delta of raw input.
    public mutating func map(_ event: WireEvent) -> [WireEvent] {
        guard !isEmpty else { return [event] }
        switch event {
        case .toolInputStart(let id, var call) where names.contains(call.name) && call.itemType == nil:
            buffered[id] = ""
            call.itemType = "custom_tool_call"
            return [.toolInputStart(id: id, call: call)]
        case .toolInputDelta(let id, let delta) where buffered[id] != nil:
            buffered[id, default: ""] += delta
            return []
        case .toolInputEnd(let id) where buffered[id] != nil:
            let input = Self.rawInput(buffered[id] ?? "")
            buffered[id] = nil
            return input.isEmpty ? [event] : [.toolInputDelta(id: id, delta: input), event]
        case .toolCall(let id, let call):
            return [.toolCall(id: id, call: mapped(call) ?? call)]
        default:
            return [event]
        }
    }
}
