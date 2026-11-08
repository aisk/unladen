// What the gateway serves: requests in flight, the recent ones with each
// attempt, sessions, and token usage by account, client, program and model. Usage is
// appended to a log of one JSON object per line and read back at start
// (UsageLog); the rest lives in memory.
// See docs/server-config-design.md ("用量与活动").

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import NIOConcurrencyHelpers
@_spi(Wire) import UnladenCore

#if canImport(Glibc)
import Glibc
private let systemWrite = Glibc.write
#elseif canImport(Darwin)
import Darwin
private let systemWrite = Darwin.write
#endif

/// Token counts of replies, as their upstreams report them. `input`
/// includes the cached tokens, read or written.
struct TokenCounts: Sendable, Hashable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var reasoning = 0

    init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    /// `nil` when the reply reported no usage.
    init?(_ usage: WireUsage?) {
        guard let usage, usage.inputTokens != nil || usage.outputTokens != nil else { return nil }
        self.init(
            input: usage.inputTokens ?? 0, output: usage.outputTokens ?? 0, cacheRead: usage.cachedInputTokens ?? 0,
            cacheWrite: usage.cacheWriteTokens ?? 0, reasoning: usage.reasoningTokens ?? 0,
        )
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite += rhs.cacheWrite
        lhs.reasoning += rhs.reasoning
    }

    var json: JSONValue {
        [
            "input": .number(JSONNumber(input)), "output": .number(JSONNumber(output)),
            "cache_read": .number(JSONNumber(cacheRead)), "cache_write": .number(JSONNumber(cacheWrite)),
            "reasoning": .number(JSONNumber(reasoning)),
        ]
    }
}

// MARK: - Who and which conversation

/// Who sent a request, and the conversation it is part of.
struct RequestOrigin: Sendable, Hashable {
    /// The program, from its User-Agent (`Claude Code`, `Codex`).
    var program: String
    /// The client (of `clients`) whose key it presented; `nil` when the
    /// gateway asks for no key.
    var client: String?
    /// The conversation: the id the client sends, else a hash of how the
    /// conversation opens, which every later turn repeats.
    var session: String?
    /// A Claude Code subagent's id; its turns share their session's id.
    var subagent: String?

    /// Headers clients name their session in, in the order they are read
    /// (Claude Code, Codex, OpenCode and others; magpie reads the same).
    static let sessionHeaders = [
        "x-claude-code-session-id", "session_id", "session-id", "x-session-id", "x-opencode-session",
        "x-session-affinity", "x-conversation-id",
    ]

    init(program: String, client: String? = nil, session: String? = nil, subagent: String? = nil) {
        self.program = program
        self.client = client
        self.session = session
        self.subagent = subagent
    }

    init(headers: HTTPFields, request: WireRequest?, access: ClientAccess) {
        program = Self.program(userAgent: headers[.userAgent], originator: headers[HTTPField.Name("originator")!])
        if case .key(let key) = access { client = key.name }
        session = Self.session(headers: headers, request: request)
        subagent = headers[HTTPField.Name("x-claude-code-agent-id")!].map { String($0.prefix(128)) }
    }

    static func program(userAgent: String?, originator: String? = nil) -> String {
        for value in [originator, userAgent].compactMap({ $0?.trimmingBlanks().lowercased() }) where !value.isEmpty {
            if value.hasPrefix("claude-cli") || value.hasPrefix("claude code") { return "Claude Code" }
            if value.hasPrefix("codex") { return "Codex" }
            if value.hasPrefix("opencode") { return "OpenCode" }
            if value.hasPrefix("geminicli") || value.hasPrefix("gemini-cli") { return "Gemini CLI" }
        }
        guard let userAgent = userAgent?.trimmingBlanks(), !userAgent.isEmpty else { return "unknown" }
        let name = userAgent.prefix { $0 != "/" && $0 != " " }
        return String(name.prefix(40))
    }

    static func session(headers: HTTPFields, request: WireRequest?) -> String? {
        for name in sessionHeaders {
            if let value = headers[HTTPField.Name(name)!]?.trimmingBlanks(), !value.isEmpty { return String(value.prefix(128)) }
        }
        guard let request else { return nil }
        if let key = request.promptCacheKey?.trimmingBlanks(), !key.isEmpty { return String(key.prefix(128)) }
        if let user = request.user, let session = claudeCodeSession(user) { return session }
        return openingHash(request)
    }

    /// The session in Claude Code's `metadata.user_id`: a JSON object with
    /// `session_id`, or `user_…_account_…_session_<uuid>`.
    static func claudeCodeSession(_ user: String) -> String? {
        if user.hasPrefix("{"), let value = try? JSONValue(parsing: user), let id = value["session_id"]?.stringValue, !id.isEmpty {
            return String(id.prefix(128))
        }
        if let range = user.ranges(of: "_session_").last {
            let id = user[range.upperBound...]
            if !id.isEmpty { return String(id.prefix(128)) }
        }
        return nil
    }

    /// `h-` and a hash of the instructions and the first user message.
    static func openingHash(_ request: WireRequest) -> String? {
        request.openingFingerprint.map { "h-" + $0 }
    }
}

// MARK: - Records

/// One request: who sent it, what it asked for, each attempt and how it
/// ended.
struct RequestRecord: Sendable {
    struct Attempt: Sendable, Hashable {
        var provider: String
        var account: String
        var model: String
        /// `ok`, or why the next candidate was tried.
        var outcome: String
        var milliseconds: Int
    }

    enum Phase: String, Sendable {
        /// Waiting for an upstream's first content.
        case waiting
        /// Forwarding a stream.
        case streaming
        case done
    }

    var id: UInt64 = 0
    /// Unix time in milliseconds.
    var started: Int64
    var origin: RequestOrigin
    var clientProtocol: String
    /// The model name the client asked for.
    var model: String
    var stream = false
    var phase = Phase.waiting
    var attempts: [Attempt] = []
    /// The candidate that answered.
    var provider: String?
    var account: String?
    var served: String?
    var status: Int?
    var note: String?
    var firstContentMilliseconds: Int?
    var milliseconds: Int?
    var tokens: TokenCounts?
    /// Warnings about what the request or its reply lost on the way.
    var warnings = 0
    /// It ended in an error: an error status, or a stream that broke off.
    var failed = false

    /// As the usage log keeps it: no attempts beyond their count.
    var logged: JSONValue {
        var object: JSONObject = [
            "t": .number(JSONNumber(started)),
            "program": .string(origin.program),
            "protocol": .string(clientProtocol),
            "model": .string(model),
            "stream": .bool(stream),
            "status": .number(JSONNumber(status ?? 0)),
            "attempts": .number(JSONNumber(attempts.count)),
        ]
        if failed { object["failed"] = true }
        if let value = origin.client { object["client"] = .string(value) }
        if let value = origin.session { object["session"] = .string(value) }
        if let value = origin.subagent { object["subagent"] = .string(value) }
        if let value = provider { object["provider"] = .string(value) }
        if let value = account { object["account"] = .string(value) }
        if let value = served { object["served"] = .string(value) }
        if let value = firstContentMilliseconds { object["first_content_ms"] = .number(JSONNumber(value)) }
        if let value = milliseconds { object["ms"] = .number(JSONNumber(value)) }
        if warnings > 0 { object["warnings"] = .number(JSONNumber(warnings)) }
        if let value = note { object["note"] = .string(String(value.prefix(300))) }
        if let tokens { object["tokens"] = tokens.json }
        return .object(object)
    }

    /// The request's line in the gateway's log: protocol, model → what
    /// served it, status, time, warnings, the attempts when there was more
    /// than one or none answered, and the note. No bodies.
    var logLine: String {
        var text = "\(clientProtocol)\(stream ? " stream" : "") \(model) → \(served ?? attempts.last?.model ?? "-")"
        text += " status=\(status ?? 0) \(milliseconds ?? 0)ms warnings=\(warnings)"
        if attempts.count > 1 || (served == nil && !attempts.isEmpty) {
            text += " tried=[" + attempts.map { "\($0.provider)/\($0.account) \($0.outcome)" }.joined(separator: ", ") + "]"
        }
        if let note { text += " (\(note.prefix(300)))" }
        return text
    }

    init(started: Int64, origin: RequestOrigin, clientProtocol: String, model: String, stream: Bool) {
        self.started = started
        self.origin = origin
        self.clientProtocol = clientProtocol
        self.model = model
        self.stream = stream
    }

    /// A line of the usage log; `nil` when it is not one.
    init?(logged value: JSONValue) {
        guard let started = value["t"]?.numberValue?.int, let program = value["program"]?.stringValue,
              let model = value["model"]?.stringValue
        else { return nil }
        self.started = started.int64
        origin = RequestOrigin(
            program: program, client: value["client"]?.stringValue, session: value["session"]?.stringValue,
            subagent: value["subagent"]?.stringValue,
        )
        clientProtocol = value["protocol"]?.stringValue ?? ""
        self.model = model
        stream = value["stream"]?.boolValue ?? false
        phase = .done
        provider = value["provider"]?.stringValue
        account = value["account"]?.stringValue
        served = value["served"]?.stringValue
        status = value["status"]?.numberValue?.int
        note = value["note"]?.stringValue
        failed = value["failed"]?.boolValue ?? ((status ?? 0) >= 400)
        firstContentMilliseconds = value["first_content_ms"]?.numberValue?.int
        milliseconds = value["ms"]?.numberValue?.int
        warnings = value["warnings"]?.numberValue?.int ?? 0
        if let tokens = value["tokens"] {
            func count(_ key: String) -> Int { tokens[key]?.numberValue?.int ?? 0 }
            self.tokens = TokenCounts(
                input: count("input"), output: count("output"), cacheRead: count("cache_read"),
                cacheWrite: count("cache_write"), reasoning: count("reasoning"),
            )
        }
    }
}

private extension Int {
    var int64: Int64 { Int64(self) }
}

/// A conversation, summed over its requests.
struct SessionSummary: Sendable {
    var id: String
    var program: String
    var client: String?
    var first: Int64
    var last: Int64
    var requests = 0
    var failures = 0
    var tokens = TokenCounts()
    /// `provider/account` in the order they first answered.
    var accounts: [String] = []
    /// How often the answering account changed from one request to the
    /// next: each change starts the prompt cache afresh.
    var switches = 0
    var lastAccount: String?
    /// The model names asked for, in order.
    var models: [String] = []
    var lastModel: String

    mutating func add(_ record: RequestRecord) {
        requests += 1
        last = max(last, record.started)
        if record.failed { failures += 1 }
        if let tokens = record.tokens { self.tokens += tokens }
        if !models.contains(record.model) { models.append(record.model) }
        lastModel = record.model
        if record.served != nil, let provider = record.provider, let account = record.account {
            let name = provider + "/" + account
            if !accounts.contains(name) { accounts.append(name) }
            if let lastAccount, lastAccount != name { switches += 1 }
            lastAccount = name
        }
    }
}

/// Usage summed by day and by what served it.
struct UsageBucket: Sendable {
    struct Key: Hashable, Sendable {
        /// `yyyymmdd`, local time.
        var day: Int
        var provider: String
        var account: String
        /// The client's name; empty when the gateway asks for no key.
        var client: String
        var program: String
        /// What served it, `provider/model`; the name asked for when
        /// nothing did.
        var model: String
    }

    var requests = 0
    var failures = 0
    var tokens = TokenCounts()
}

// MARK: - The log

/// The usage log: `usage-YYYY-MM.jsonl` in `directory`, one request per
/// line, appended as requests end; private to the user (0600).
struct UsageLog: Sendable {
    var directory: String

    /// `$XDG_STATE_HOME/unladen`, or `~/.local/state/unladen`.
    static func defaultDirectory(environment: (String) -> String?) -> String? {
        if let state = environment("XDG_STATE_HOME"), !state.isEmpty { return state + "/unladen" }
        if let home = environment("HOME"), !home.isEmpty { return home + "/.local/state/unladen" }
        return nil
    }

    func path(month: Int) -> String {
        "\(directory)/usage-\(month / 100)-\(month % 100 < 10 ? "0" : "")\(month % 100).jsonl"
    }

    /// Appends `record`; a failure to write is reported once per call and
    /// otherwise ignored, so serving never stops for it.
    func append(_ record: RequestRecord) -> String? {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = path(month: LocalDay(milliseconds: record.started).month)
        let descriptor = open(file, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return "cannot write the usage log \(file): \(String(cString: strerror(errno)))" }
        defer { close(descriptor) }
        let bytes = record.logged.encoded() + [0x0A]
        let written = bytes.withUnsafeBytes { systemWrite(descriptor, $0.baseAddress, $0.count) }
        return written == bytes.count ? nil : "cannot write the usage log \(file)"
    }

    /// The records since `since` (Unix milliseconds), oldest first.
    func load(since: Int64) -> [RequestRecord] {
        var months: [Int] = []
        var day = LocalDay(milliseconds: since)
        let now = LocalDay(milliseconds: LocalDay.nowMilliseconds())
        while true {
            if !months.contains(day.month) { months.append(day.month) }
            if day.month >= now.month { break }
            day = LocalDay(milliseconds: day.milliseconds + 28 * 86_400_000)
        }
        if !months.contains(now.month) { months.append(now.month) }
        var records: [RequestRecord] = []
        for month in months {
            guard let data = FileManager.default.contents(atPath: path(month: month)) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let value = try? JSONValue(parsing: line), let record = RequestRecord(logged: value),
                      record.started >= since
                else { continue }
                records.append(record)
            }
        }
        return records.sorted { $0.started < $1.started }
    }
}

/// A local calendar day.
struct LocalDay: Sendable, Hashable {
    var year: Int
    var month0: Int
    var day: Int
    var milliseconds: Int64

    init(milliseconds: Int64) {
        var seconds = time_t(milliseconds / 1000)
        var parts = tm()
        localtime_r(&seconds, &parts)
        year = Int(parts.tm_year) + 1900
        month0 = Int(parts.tm_mon)
        day = Int(parts.tm_mday)
        self.milliseconds = milliseconds
    }

    /// `yyyymmdd`.
    var key: Int { year * 10000 + (month0 + 1) * 100 + day }
    /// `yyyymm`.
    var month: Int { year * 100 + month0 + 1 }

    static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - Activity

/// Requests in flight, recent requests, sessions and usage. Safe to use from
/// any task; records reach the usage log when their request ends.
final class Activity: Sendable {
    /// How many ended requests are kept with their attempts.
    static let recentLimit = 200
    /// How many sessions are kept, and for how long since their last request.
    static let sessionLimit = 300
    static let sessionDays = 7
    /// How far back usage is kept in memory.
    static let usageDays = 31

    private struct State {
        var next: UInt64 = 0
        var inFlight: [UInt64: RequestRecord] = [:]
        var recent: [RequestRecord] = []
        var sessions: [String: SessionSummary] = [:]
        var buckets: [UsageBucket.Key: UsageBucket] = [:]
        var logError: String?
    }

    private let state = NIOLockedValueBox(State())
    let log: UsageLog?
    /// Told when the usage log cannot be written (once until it can again).
    let report: @Sendable (String) -> Void

    init(log: UsageLog? = nil, report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
        self.report = report
    }

    /// Reads the usage log back: usage of the last ``usageDays`` days and
    /// sessions of the last ``sessionDays``.
    func restore(now: Int64 = LocalDay.nowMilliseconds()) {
        guard let log else { return }
        let records = log.load(since: now - Int64(Self.usageDays) * 86_400_000)
        let sessionsSince = now - Int64(Self.sessionDays) * 86_400_000
        state.withLockedValue { state in
            for record in records {
                Self.count(record, in: &state.buckets)
                if record.started >= sessionsSince { Self.add(record, to: &state.sessions) }
            }
            Self.trimSessions(&state.sessions)
        }
    }

    /// Starts a request's record; its line goes to `log` when it ends.
    func begin(_ record: RequestRecord, log: RequestLog = .silent) -> RequestTracker {
        let id = state.withLockedValue { state -> UInt64 in
            state.next += 1
            var record = record
            record.id = state.next
            state.inFlight[state.next] = record
            return state.next
        }
        return RequestTracker(activity: self, id: id, start: ContinuousClock.now, log: log)
    }

    func update(_ id: UInt64, _ change: (inout RequestRecord) -> Void) {
        state.withLockedValue { state in
            if state.inFlight[id] != nil { change(&state.inFlight[id]!) }
        }
    }

    @discardableResult
    fileprivate func end(_ id: UInt64, _ change: (inout RequestRecord) -> Void) -> RequestRecord? {
        let record = state.withLockedValue { state -> RequestRecord? in
            guard var record = state.inFlight.removeValue(forKey: id) else { return nil }
            change(&record)
            record.phase = .done
            state.recent.append(record)
            if state.recent.count > Self.recentLimit { state.recent.removeFirst(state.recent.count - Self.recentLimit) }
            Self.count(record, in: &state.buckets)
            Self.add(record, to: &state.sessions)
            Self.trimSessions(&state.sessions)
            return record
        }
        guard let record, let log else { return record }
        let error = log.append(record)
        let tell = state.withLockedValue { state -> Bool in
            defer { state.logError = error }
            return error != nil && state.logError == nil
        }
        if tell, let error { report(error) }
        return record
    }

    private static func count(_ record: RequestRecord, in buckets: inout [UsageBucket.Key: UsageBucket]) {
        let key = UsageBucket.Key(
            day: LocalDay(milliseconds: record.started).key, provider: record.provider ?? "", account: record.account ?? "",
            client: record.origin.client ?? "", program: record.origin.program, model: record.served ?? record.model,
        )
        var bucket = buckets[key] ?? UsageBucket()
        bucket.requests += 1
        if record.failed { bucket.failures += 1 }
        if let tokens = record.tokens { bucket.tokens += tokens }
        buckets[key] = bucket
    }

    private static func add(_ record: RequestRecord, to sessions: inout [String: SessionSummary]) {
        guard let id = record.origin.session else { return }
        var session = sessions[id] ?? SessionSummary(
            id: id, program: record.origin.program, client: record.origin.client, first: record.started, last: record.started,
            lastModel: record.model,
        )
        session.add(record)
        sessions[id] = session
    }

    private static func trimSessions(_ sessions: inout [String: SessionSummary]) {
        guard sessions.count > sessionLimit else { return }
        let kept = sessions.values.sorted { $0.last > $1.last }.prefix(sessionLimit)
        sessions = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
    }

    // MARK: Reading

    struct Snapshot: Sendable {
        var inFlight: [RequestRecord]
        var recent: [RequestRecord]
        var sessions: [SessionSummary]
    }

    /// In flight (oldest first), recent (newest first), sessions (latest
    /// first); `limit` caps the recent requests.
    func snapshot(limit: Int = 100) -> Snapshot {
        state.withLockedValue { state in
            Snapshot(
                inFlight: state.inFlight.values.sorted { $0.id < $1.id },
                recent: Array(state.recent.reversed().prefix(limit)),
                sessions: state.sessions.values.sorted { $0.last > $1.last },
            )
        }
    }

    /// Requests of a session, newest first, from those still kept in memory.
    func requests(ofSession id: String) -> [RequestRecord] {
        state.withLockedValue { state in
            (state.recent + state.inFlight.values.sorted { $0.id < $1.id }).filter { $0.origin.session == id }.reversed()
        }
    }

    /// Usage over the last `days` days, today included.
    func usage(days: Int, now: Int64 = LocalDay.nowMilliseconds()) -> [UsageBucket.Key: UsageBucket] {
        let first = LocalDay(milliseconds: now - Int64(max(days, 1) - 1) * 86_400_000).key
        return state.withLockedValue { state in state.buckets.filter { $0.key.day >= first } }
    }
}

/// One request's handle on its record.
final class RequestTracker: Sendable {
    let activity: Activity
    let id: UInt64
    let start: ContinuousClock.Instant
    let log: RequestLog

    fileprivate init(activity: Activity, id: UInt64, start: ContinuousClock.Instant, log: RequestLog) {
        self.activity = activity
        self.id = id
        self.start = start
        self.log = log
    }

    var elapsedMilliseconds: Int { Self.milliseconds(since: start) }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Notes an attempt of `candidate` that started at `since`.
    func tried(_ candidate: Candidate, outcome: String, since: ContinuousClock.Instant) {
        let milliseconds = Self.milliseconds(since: since)
        let attempt = RequestRecord.Attempt(
            provider: candidate.target.provider, account: candidate.keyName, model: candidate.reference, outcome: outcome,
            milliseconds: milliseconds,
        )
        activity.update(id) { $0.attempts.append(attempt) }
    }

    /// `candidate` answered; a stream goes on.
    func serving(_ candidate: Candidate, streaming: Bool) {
        let elapsed = elapsedMilliseconds
        activity.update(id) { record in
            record.provider = candidate.target.provider
            record.account = candidate.keyName.isEmpty ? nil : candidate.keyName
            record.served = candidate.reference
            record.firstContentMilliseconds = elapsed
            if streaming { record.phase = .streaming }
        }
    }

    /// The request ended: its record is kept and its line logged.
    /// `failed` defaults to an error status.
    func finish(status: Int, note: String? = nil, tokens: TokenCounts? = nil, warnings: Int = 0, failed: Bool? = nil) {
        let elapsed = elapsedMilliseconds
        let record = activity.end(id) { record in
            record.status = status
            record.failed = failed ?? (status >= 400)
            record.note = note
            record.tokens = tokens
            record.warnings = warnings
            record.milliseconds = elapsed
            // A request no account served is counted against the last one tried.
            if record.provider == nil, let last = record.attempts.last {
                record.provider = last.provider
                record.account = last.account
            }
        }
        if let record { log.emit(record.logLine) }
    }
}
