// The fallback loop: each candidate in turn, up to its first content.

import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
@_spi(Wire) import UnladenCore

extension Gateway {
    // MARK: Fallback loop

    enum AttemptOutcome: Sendable {
        case reply(Served)
        case failure(AttemptFailure)
    }

    /// The candidate that answered, and the warnings of its exchange.
    struct Served: Sendable {
        var candidate: Candidate
        var body: ServedBody
        /// Decoding the client's request plus transforming and encoding it
        /// for this candidate, merged (``WireWarning/merged(decoded:encoded:)``).
        var requestWarnings: [WireWarning]
        /// Decoding the upstream's reply (complete replies; a stream's are
        /// reported at its end).
        var responseWarnings: [WireWarning]
    }

    enum ServedBody: Sendable {
        case response(WireResponse)
        /// Read up to its first content; the rest is still to come.
        case events(PrimedEvents)
    }

    enum AttemptFailure: Sendable {
        /// A non-2xx upstream reply that ends the request (or the last one).
        case upstream(Candidate, UpstreamHTTPError)
        /// A failure without an upstream reply to forward.
        case gateway(status: Int, message: String, candidate: Candidate?)
        /// `--strict`: every candidate would have lost part of the request;
        /// the first candidate's lossy warnings.
        case strict([WireWarning])

        var candidate: Candidate? {
            switch self {
            case .upstream(let candidate, _): candidate
            case .gateway(_, _, let candidate): candidate
            case .strict: nil
            }
        }
    }

    /// The pauses before the last candidate is tried again, one per try.
    static let retryPauses: [Duration] = [.seconds(1), .seconds(2)]
    /// The longest wait an upstream may ask for before the last candidate
    /// is tried again.
    static let longestRetryWait: Duration = .seconds(10)
    /// What ``prime(_:)`` says of a stream that ends before any content.
    static let endedWithoutContent = "the stream ended without content"
    /// How a decoder's error for a stream cut short before its end begins.
    static let endedEarlyPrefix = "upstream stream ended early"

    /// Statuses after which the next candidate is tried: rate limits,
    /// server errors, timeouts, key problems and a model the key cannot
    /// reach (another key may work). Other 4xx are the request's fault and
    /// end it.
    static func isRetryable(_ status: Int) -> Bool {
        switch status {
        case 401, 402, 403, 404, 408, 409, 425, 429: true
        case 500..<600: true
        default: false
        }
    }

    /// Tries `candidates` in order until one answers: a complete reply, or
    /// a stream that reached its first content. Anything that goes wrong
    /// before that (an error status, an error event, a stream that ends
    /// empty or breaks off, `headTimeout`) moves on to the next candidate,
    /// since nothing has reached the client yet. Each candidate gets its
    /// own copy of `request` (value semantics), transformed and encoded for
    /// its endpoint.
    ///
    /// With `strict`, a candidate whose request would lose something
    /// (``WireWarning/isEscalatedWhenStrict``, judged on the decoding
    /// warnings and its own transform and encoding warnings) is skipped
    /// without being called.
    ///
    /// Failures are recorded against their scope (``HealthScope``). An
    /// unreachable address is not tried again with the request's other
    /// keys.
    ///
    /// The last candidate left is tried again, up to ``retryPauses``'s
    /// count of times, when it fails in a way that may pass: a 5xx, a
    /// connection failure, a stream that ends without content, or a 429
    /// whose wait is short. It goes after the pause ``retryPauses`` gives,
    /// or the wait the upstream asks for, up to ``longestRetryWait`` (a
    /// longer one ends the request).
    func attempt(
        _ request: WireRequest,
        decodeWarnings: [WireWarning] = [],
        candidates: [Candidate],
        stream: Bool,
        clientHeaders: HTTPFields,
        session: String? = nil,
        strict: Bool = false,
        headTimeout: Duration? = nil,
        log: RequestLog = .silent,
        tracker: RequestTracker,
    ) async throws -> AttemptOutcome {
        var last: AttemptFailure?
        var strictWarnings: [WireWarning]?
        var unreachable: Set<String> = []
        var remaining = candidates[...]
        // Sign-in tokens OpenAI turned away: the account is tried once more
        // with a refreshed one.
        var rejected: [String: String] = [:]
        var retries = 0
        var pending: Duration?
        /// Puts `candidate` back to be tried again after a pause, when
        /// nothing else would be tried.
        func tryAgain(_ candidate: Candidate, wait: Duration? = nil) {
            guard retries < Self.retryPauses.count, remaining.allSatisfy({ unreachable.contains($0.endpointID) }) else { return }
            let wait = wait ?? Self.retryPauses[retries]
            guard wait <= Self.longestRetryWait else { return }
            retries += 1
            pending = wait
            unreachable.remove(candidate.endpointID)
            remaining.insert(candidate, at: remaining.startIndex)
        }
        while let candidate = remaining.popFirst() {
            if let wait = pending {
                pending = nil
                try await self.pause(wait)
            }
            try Task.checkCancellation()
            let began = ContinuousClock.now
            var outcome = "skipped"
            defer { tracker.tried(candidate, outcome: outcome, since: began) }
            if unreachable.contains(candidate.endpointID) {
                outcome = "skipped: endpoint unreachable"
                continue
            }
            var apiKey = candidate.apiKey
            if candidate.signIn != nil {
                do {
                    apiKey = try await signIns.token(
                        provider: candidate.target.provider, account: candidate.keyName, transport: transport,
                        rejected: rejected[SignIns.key(candidate.target.provider, candidate.keyName)],
                    )
                } catch {
                    if Task.isCancelled {
                        outcome = "cancelled"
                        throw CancellationError()
                    }
                    // Not signed in stays so until someone signs in; a
                    // failed refresh may pass.
                    if !error.needsSignIn, let scope = candidate.keyScope {
                        health.recordFailure(scope, base: HealthStore.failureCooldown, reason: "token refresh failed")
                    }
                    last = .gateway(status: error.needsSignIn ? 401 : 502, message: error.message, candidate: candidate)
                    outcome = error.needsSignIn ? "not signed in" : "token refresh failed"
                    continue
                }
            }
            let call = UpstreamCall(
                target: candidate.target, apiKey: apiKey,
                transport: upstreamTransport(signIn: candidate.signIn, provider: candidate.target.provider, account: candidate.keyName),
                session: session,
            )
            let prepared: UpstreamRequest
            do {
                prepared = try call.prepare(request, stream: stream, clientHeaders: clientHeaders)
            } catch {
                last = .gateway(status: 500, message: "cannot call \(candidate.reference): \(error)", candidate: candidate)
                outcome = "cannot call: \(error)"
                continue
            }
            let requestWarnings = WireWarning.merged(decoded: decodeWarnings, encoded: prepared.warnings)
            if strict {
                let lossy = requestWarnings.filter(\.isEscalatedWhenStrict)
                if !lossy.isEmpty {
                    strictWarnings = strictWarnings ?? lossy
                    outcome = "skipped: would lose part of the request (strict)"
                    continue
                }
            }
            do {
                let (reply, primed) = try await within(headTimeout) { () async throws -> (UpstreamReply, PrimeOutcome?) in
                    let reply = try await call.send(prepared, stream: stream)
                    guard case .events(let events) = reply.body else { return (reply, nil) }
                    return (reply, try await Self.prime(events))
                }
                let body: ServedBody
                switch (reply.body, primed) {
                case (.response(let response), _):
                    body = .response(response)
                case (.events, .ready(let events)?):
                    body = .events(events)
                case (.events, .failed(let message)?):
                    health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown, reason: "failed before any content")
                    last = .gateway(status: 502, message: "\(candidate.reference) failed before any content: \(message)", candidate: candidate)
                    outcome = "failed before any content: \(message)"
                    if message == Self.endedWithoutContent || message.hasPrefix(Self.endedEarlyPrefix) { tryAgain(candidate) }
                    continue
                case (.events, nil):
                    continue // not reached: an event stream is always primed
                }
                health.recordSuccess(candidate)
                outcome = "ok"
                return .reply(Served(
                    candidate: candidate, body: body, requestWarnings: requestWarnings,
                    responseWarnings: Array(reply.warnings.dropFirst(prepared.warnings.count)),
                ))
            } catch is TimedOut {
                // Slow but alive: no cooldown.
                let limit = headTimeout.map { " within \($0)" } ?? ""
                last = .gateway(status: 504, message: "\(candidate.reference) sent no content\(limit)", candidate: candidate)
                outcome = "no content\(limit)"
            } catch let error as UpstreamError {
                switch error {
                case .http(let http):
                    let status = http.status.code
                    outcome = "\(status)"
                    if status == 401, candidate.signIn != nil, rejected[SignIns.key(candidate.target.provider, candidate.keyName)] == nil, let apiKey {
                        rejected[SignIns.key(candidate.target.provider, candidate.keyName)] = apiKey
                        remaining.insert(candidate, at: remaining.startIndex)
                        last = .upstream(candidate, http)
                        outcome = "401: trying again with a refreshed token"
                        continue
                    }
                    guard Self.isRetryable(status) else { return .failure(.upstream(candidate, http)) }
                    recordFailure(http, of: candidate, log: log)
                    last = .upstream(candidate, http)
                    if status >= 500 {
                        tryAgain(candidate, wait: HealthStore.retryAfter(http.retryAfter))
                    } else if status == 429, let wait = HealthStore.retryAfter(http.headerFields) {
                        tryAgain(candidate, wait: wait)
                    }
                case .decoding(let decoding, _):
                    health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown, reason: "reply cannot be decoded")
                    last = .gateway(status: 502, message: "\(candidate.reference) sent a reply that cannot be decoded: \(decoding)", candidate: candidate)
                    outcome = "reply cannot be decoded"
                case .stream(let streamError):
                    health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown, reason: "failed before any content")
                    last = .gateway(status: 502, message: "\(candidate.reference) failed: \(streamError.message)", candidate: candidate)
                    outcome = "error: \(streamError.message)"
                case .invalidBaseURL(let url):
                    last = .gateway(status: 500, message: "invalid base URL \(url)", candidate: candidate)
                    outcome = "invalid base URL"
                }
            } catch let error as HTTPResponseBodyTooLargeError {
                health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown, reason: "reply too large")
                last = .gateway(
                    status: 502, message: "\(candidate.reference) sent a reply larger than \(error.maxBytes) bytes", candidate: candidate,
                )
                outcome = "reply too large"
            } catch {
                if Task.isCancelled || error is CancellationError {
                    outcome = "cancelled"
                    throw CancellationError()
                }
                outcome = "unreachable"
                health.recordFailure(candidate.endpointScope, base: HealthStore.failureCooldown, reason: "unreachable")
                unreachable.insert(candidate.endpointID)
                last = .gateway(status: 502, message: "\(candidate.reference) is unreachable: \(error)", candidate: candidate)
                tryAgain(candidate)
            }
        }
        if let last { return .failure(last) }
        if let strictWarnings { return .failure(.strict(strictWarnings)) }
        return .failure(.gateway(status: 503, message: "no upstream available", candidate: nil))
    }

    /// The transport to an account's upstream: Code Assist's envelope for
    /// an Antigravity account, the plain one otherwise.
    func upstreamTransport(signIn: SignInKind?, provider: String, account: String) -> any HTTPTransport {
        guard signIn == .antigravity else { return transport }
        // Without a project Code Assist answers with an error, which is reported.
        let project = signIns.credentials(provider: provider, account: account)?.project ?? ""
        return CodeAssistTransport(base: transport, project: project)
    }

    /// Records an upstream error status against what it is about: the key
    /// (refused, out of credit, suspended, rate limited), the model through
    /// the key (a rate limit whose message names the model), or the model
    /// at its address.
    func recordFailure(_ http: UpstreamHTTPError, of candidate: Candidate, log: RequestLog) {
        let status = http.status.code
        // A rate limit's reset headers say when it lifts; other errors
        // carry them too, about limits that are not the matter.
        let retryAfter = status == 429 ? HealthStore.retryAfter(http.headerFields) : HealthStore.retryAfter(http.retryAfter)
        let key = candidate.keyScope ?? candidate.modelScope
        let reason = "\(status)"
        switch status {
        case 403 where Self.saysSuspended(http.body):
            health.recordFailure(key, base: HealthStore.suspendedCooldown, reason: "403: suspended")
        case 429 where Self.names(http.body, model: candidate.target.model):
            let scope = candidate.keyModelScope ?? key
            health.recordFailure(scope, base: HealthStore.rateLimitCooldown, retryAfter: retryAfter, reason: reason)
        case 401:
            if let scope = candidate.keyScope, health.recordUnauthorized(scope) {
                log.emit(
                    "key \(candidate.keyName) of \(candidate.target.provider) is disabled after \(HealthStore.unauthorizedLimit) "
                        + "refusals in a row (401); reload the configuration to use it again",
                )
            }
            health.recordFailure(key, base: HealthStore.maxCooldown, reason: reason)
        case 402: health.recordFailure(key, base: HealthStore.paymentCooldown, reason: reason)
        case 403: health.recordFailure(key, base: HealthStore.maxCooldown, reason: reason)
        case 429: health.recordFailure(key, base: HealthStore.rateLimitCooldown, retryAfter: retryAfter, reason: reason)
        case 404: health.recordFailure(candidate.modelScope, base: HealthStore.maxCooldown, reason: reason)
        default:
            health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown, retryAfter: retryAfter, reason: reason)
        }
    }

    /// Whether an error body says the account is disabled or suspended for
    /// breaking the terms of service ("This service has been disabled in
    /// this account for violation of Terms of Service").
    static func saysSuspended(_ body: [UInt8]) -> Bool {
        let text = String(decoding: body, as: UTF8.self).lowercased()
        guard text.contains("disabled") || text.contains("suspended") else { return false }
        return text.contains("terms of service") || text.contains("terms of use")
    }

    /// Whether an error body names `model` as a word of its own: providers
    /// that count rate limits per model say which ("Rate limit reached for
    /// model `llama-3.3-70b-versatile` … tokens per day", "… for gpt-4o in
    /// organization …", "Quota exceeded for metric … model: gemini-2.5-pro").
    static func names(_ body: [UInt8], model: String) -> Bool {
        let model = Array(model.lowercased().utf8)
        guard !model.isEmpty else { return false }
        let text = Array(String(decoding: body, as: UTF8.self).lowercased().utf8)
        func isAlphanumeric(_ index: Int) -> Bool {
            guard text.indices.contains(index) else { return false }
            return (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(text[index]) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(text[index])
        }
        // Part of the same id: letters, digits, `-`, `_`, and a dot that
        // more of the id follows (not a sentence's end).
        func continuesID(_ index: Int) -> Bool {
            guard text.indices.contains(index) else { return false }
            switch text[index] {
            case UInt8(ascii: "-"), UInt8(ascii: "_"): return true
            case UInt8(ascii: "."): return isAlphanumeric(index + 1)
            default: return isAlphanumeric(index)
            }
        }
        var start = 0
        while start + model.count <= text.count {
            if text[start..<start + model.count].elementsEqual(model), !continuesID(start - 1), !continuesID(start + model.count) {
                return true
            }
            start += 1
        }
        return false
    }

    // MARK: First content

    enum PrimeOutcome: Sendable {
        case ready(PrimedEvents)
        case failed(String)
    }

    /// Reads `events` up to the first event worth sending (content, or the
    /// finish of an empty reply): an error event, a stream that ends or
    /// breaks off before it, is a failure. So is a finish without a reason
    /// before any content (a Chat stream of a role chunk and `[DONE]`): an
    /// empty reply the upstream meant says why it stopped.
    static func prime(_ events: UpstreamEventStream) async throws -> PrimeOutcome {
        var iterator = events.makeAsyncIterator()
        var buffered: [WireEvent] = []
        do {
            while let event = try await iterator.next() {
                if case .error(let error) = event { return .failed(error.message) }
                if case .finish(let finish) = event, finish.reason == nil { return .failed(Self.endedWithoutContent) }
                buffered.append(event)
                if event.startsTheReply { return .ready(PrimedEvents(buffered: buffered, iterator: iterator)) }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return .failed("the stream broke off: \(error)")
        }
        return .failed(Self.endedWithoutContent)
    }
}

/// An operation that took longer than its limit.
struct TimedOut: Error, CustomStringConvertible {
    var limit: Duration
    var description: String { "no answer within \(limit)" }
}

/// `operation`, or ``TimedOut`` when it takes longer than `limit` (the
/// operation is then cancelled).
func within<T: Sendable>(_ limit: Duration?, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard let limit else { return try await operation() }
    return try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw TimedOut(limit: limit) }
        return value
    }
}

/// A result that comes later, waited for with or without a limit: unlike
/// a task's `value`, a wait that runs out returns at once.
final class Settled<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, any Error>?
        var next = 0
        var waiters: [Int: CheckedContinuation<Result<T, any Error>?, Never>] = [:]
    }

    private let state = NIOLockedValueBox(State())

    init() {}

    /// Sets the result once and wakes every waiter.
    func set(_ result: Result<T, any Error>) {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Result<T, any Error>?, Never>] in
            guard state.result == nil else { return [] }
            state.result = result
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: result) }
    }

    /// The result.
    func wait() async -> Result<T, any Error> {
        // Without a limit the wait only ends with the result.
        await wait(upTo: nil)!
    }

    /// The result, or `nil` when it has not come within `limit`.
    func wait(upTo limit: Duration?) async -> Result<T, any Error>? {
        await withCheckedContinuation { continuation in
            let (ready, id) = state.withLockedValue { state -> (Result<T, any Error>?, Int) in
                if let result = state.result { return (result, -1) }
                let id = state.next
                state.next += 1
                state.waiters[id] = continuation
                return (nil, id)
            }
            if let ready {
                continuation.resume(returning: ready)
                return
            }
            guard let limit else { return }
            Task {
                try? await Task.sleep(for: limit)
                let expired = self.state.withLockedValue { $0.waiters.removeValue(forKey: id) }
                expired?.resume(returning: nil)
            }
        }
    }
}
