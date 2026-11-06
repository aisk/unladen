import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

/// Layer A: real recorded bodies through the codec of their protocol.
///
/// - A reply decodes, says what the recording says (``ReplySummary`` against
///   the importer's independently extracted facts), and warns only about
///   lossless bags unless the case expects more.
/// - A complete reply re-encoded in its own protocol is the recorded JSON
///   (keys order aside); a stream re-encoded passes the protocol's stream
///   check and decodes to the same events.
/// - A recorded request (vendor traffic or a client sample) decodes and
///   re-encodes in its own protocol to the recorded JSON.
@Suite struct CodecReplayTests {
    @Test(arguments: Recording.replies)
    func replyDecodesAsRecorded(_ recording: Recording) throws {
        let reply = try recording.decodeReply()
        let facts = try #require(recording.facts)
        var byCheck: [String: [String]] = [:]
        for (check, problem) in ReplySummary(reply.response, errors: reply.streamErrors).differences(from: facts) {
            byCheck[check, default: []].append(problem)
        }
        for check in ["facts.text", "facts.reasoning", "facts.refusal", "facts.signedReasoning", "facts.toolCalls", "facts.finish", "facts.usage", "facts.error"] {
            expectNoProblems(byCheck[check] ?? [], recording, check: check)
        }
        expectNoProblems(lossyWarnings(reply.warnings, allowing: recording.expectedWarnings), recording, check: "decodeWarnings")
        if let events = reply.events {
            expectNoProblems(checkEventSequence(events), recording, check: "eventSequence")
        }
    }

    @Test(arguments: Recording.completeReplies)
    func completeReplyRoundTrips(_ recording: Recording) throws {
        let original = try #require(recording.responseJSON)
        let decoded = try Codecs.parseResponse(recording.responseBytes ?? [], as: recording.wire, origin: Codecs.origin(recording.wire))
        let encoded = Codecs.encodeResponse(decoded.value, as: recording.wire)
        var problems = encoded.warnings.map { "encode warning: \($0)" }
        problems += jsonDifferences(encoded.json, original)
        expectNoProblems(problems, recording, check: "roundTrip")
        // Encoding is deterministic.
        #expect(Codecs.encodeResponse(decoded.value, as: recording.wire).body == encoded.body)
    }

    @Test(arguments: Recording.streamedReplies)
    func streamReencodesStably(_ recording: Recording) throws {
        let reply = try recording.decodeReply()
        let events = try #require(reply.events)
        let (elements, warnings) = Codecs.encodeStream(events, as: recording.wire)
        var problems = warnings.map { "encode warning: \($0)" }
        problems += Codecs.checkStream(elements, as: recording.wire)
        let (again, _) = try Codecs.decodeStream(elements, as: recording.wire, origin: Codecs.origin(recording.wire))
        // The reply the events describe must survive; their exact order
        // need not (an encoder that writes one block at a time serializes
        // interleaved blocks, Chat ends calls implicitly, keepalives move).
        let before = WireResponseAccumulator(events), after = WireResponseAccumulator(again)
        problems += replyDifferences(after.response, before.response)
        if after.errors.map(\.message) != before.errors.map(\.message) {
            problems.append("stream errors: \(after.errors.map(\.message)) vs \(before.errors.map(\.message))")
        }
        expectNoProblems(problems, recording, check: "streamRoundTrip")
    }

    @Test(arguments: Recording.requests)
    func requestRoundTrips(_ recording: Recording) throws {
        let original = try #require(recording.requestJSON)
        let decoded = try Codecs.parseRequest(
            recording.requestBytes ?? [], as: recording.wire,
            model: recording.model ?? "replay-model", stream: recording.isStream,
        )
        var problems = lossyWarnings(decoded.warnings, allowing: recording.expectedWarnings).map { "decode warning: \($0)" }
        let encoded = Codecs.buildRequest(decoded.value, as: recording.wire)
        problems += encoded.warnings.map { "encode warning: \($0)" }
        problems += jsonDifferences(encoded.json, original).filter { !Self.isWrittenBack($0, recording.wire) }
        expectNoProblems(problems, recording, check: "requestRoundTrip")
    }

    /// A Responses input message always gets `"type": "message"` back (the
    /// codec writes it on purpose, see ``ResponsesCodec``; the API takes
    /// messages with or without it).
    static func isWrittenBack(_ difference: String, _ wire: WireProtocol) -> Bool {
        wire == .responses && difference.hasPrefix("$.input[") && difference.hasSuffix(#"].type: "message" vs absent"#)
    }
}

/// Differences between two replies' content, finish and usage, one line each.
func replyDifferences(_ ours: WireResponse, _ theirs: WireResponse) -> [String] {
    var out: [String] = []
    let a = ours.message.parts, b = theirs.message.parts
    if a.count != b.count { out.append("\(a.count) parts vs \(b.count)") }
    for i in 0..<min(a.count, b.count) where a[i] != b[i] {
        out.append("part \(i): \("\(a[i])".prefix(300)) vs \("\(b[i])".prefix(300))")
    }
    if ours.finishReason != theirs.finishReason { out.append("finish: \(String(describing: ours.finishReason)) vs \(String(describing: theirs.finishReason))") }
    if ours.usage != theirs.usage { out.append("usage: \(String(describing: ours.usage)) vs \(String(describing: theirs.usage))") }
    return out
}

/// Structural differences between two JSON values (object key order
/// ignored), as `path: ours vs theirs` lines; at most 20.
func jsonDifferences(_ ours: JSONValue, _ theirs: JSONValue, path: String = "$", ignoring: Set<String> = []) -> [String] {
    var out: [String] = []
    func walk(_ a: JSONValue?, _ b: JSONValue?, _ path: String) {
        guard out.count < 20, !ignoring.contains(path) else { return }
        switch (a, b) {
        case (.object(let x)?, .object(let y)?):
            for key in Set(x.keys).union(y.keys).sorted() { walk(x[key], y[key], "\(path).\(key)") }
        case (.array(let x)?, .array(let y)?):
            if x.count != y.count { out.append("\(path): \(x.count) items vs \(y.count)") }
            for i in 0..<min(x.count, y.count) { walk(x[i], y[i], "\(path)[\(i)]") }
        case (let x, let y):
            if x != y {
                // Numbers compare by value (1.0 == 1).
                if let p = x?.numberValue, let q = y?.numberValue, p.double == q.double { return }
                out.append("\(path): \(x.map { "\($0)".prefix(120) } ?? "absent") vs \(y.map { "\($0)".prefix(120) } ?? "absent")")
            }
        }
    }
    walk(ours, theirs, path)
    return out
}
