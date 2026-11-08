// One request through the gateway: decode → candidates → fallback loop →
// re-encode for the client (complete or streamed).

import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
@_spi(Wire) import UnladenCore

/// Writes the request's one log line.
struct RequestLog: Sendable {
    var emit: @Sendable (String) -> Void

    static let silent = RequestLog { _ in }
}

/// The protocol-translating core, shared by the four ingress routes.
struct Gateway: Sendable {
    let store: ConfigurationStore
    var transport: any HTTPTransport
    var strategy: any RoutingStrategy = KeyPoolOrdering()
    var health = HealthStore()
    var heldStreams = HeldStreams()
    /// Requests in flight and ended, sessions and usage.
    var activity = Activity()

    init(configuration: GatewayConfiguration, transport: any HTTPTransport) {
        self.store = ConfigurationStore(configuration)
        self.transport = transport
    }

    /// The current configuration. A request reads it once, at its start,
    /// and keeps that snapshot to its end; setting it (a reload) affects
    /// the requests that start afterwards.
    var configuration: GatewayConfiguration {
        get { store.current }
        nonmutating set { replace(newValue) }
    }

    /// Installs `configuration` for the requests that start from now on.
    /// Health stays with each key's name, except for keys whose secret
    /// changed: they start afresh. Keys disabled after repeated 401s get
    /// another chance.
    func replace(_ configuration: GatewayConfiguration) {
        let old = store.replace(configuration)
        var changed: Set<HealthScope> = []
        for (provider, pool) in old.keyPools {
            let now = configuration.keyPools[provider]?.keys ?? []
            for key in pool.keys where now.contains(where: { $0.name == key.name && $0.secret != key.secret }) {
                changed.insert(.key(provider: provider, keyName: key.name))
            }
        }
        if !changed.isEmpty { health.forget { changed.contains($0) } }
        health.enableDisabledKeys()
    }

    // MARK: Handling

    /// Serves one client request of `clientProtocol`.
    ///
    /// The upstream work runs under `monitor`: a client that disconnects
    /// cancels it, before the response head as well as during a stream.
    /// The monitor is uninstalled when the response is complete.
    func handle(
        _ clientProtocol: WireProtocol,
        body: [UInt8],
        geminiPath: (model: String, stream: Bool)? = nil,
        headers: HTTPFields,
        access: ClientAccess = .open,
        configuration snapshot: GatewayConfiguration? = nil,
        monitor: DisconnectMonitor,
        log: RequestLog,
    ) async -> Response {
        let configuration = snapshot ?? self.configuration
        let start = ContinuousClock.now
        var line = LogLine(clientProtocol: clientProtocol, start: start)
        let parsed = Result { () throws(WireDecodingError) in
            try ClientCodec.parseRequest(clientProtocol, body: body, geminiPath: geminiPath)
        }
        let tracker = activity.begin(RequestRecord(
            started: LocalDay.nowMilliseconds(),
            origin: RequestOrigin(headers: headers, request: try? parsed.get().value, access: access),
            clientProtocol: clientProtocol.rawValue, model: (try? parsed.get().value.model) ?? geminiPath?.model ?? "?",
            stream: (try? parsed.get().value.stream) == true || geminiPath?.stream == true,
        ))
        func fail(_ status: Int, _ message: String, detail: String? = nil, warnings: [WireWarning] = []) -> Response {
            monitor.uninstall()
            line.status = status
            line.warnings = warnings.count
            line.note = detail ?? message
            log.emit(line.text)
            tracker.finish(status: status, note: detail ?? message)
            return Self.errorResponse(clientProtocol, status: status, message: message, warnings: warnings)
        }

        let decoded: WireDecoded<WireRequest>
        switch parsed {
        case .success(let value): decoded = value
        case .failure(let error): return fail(400, "invalid request: \(error)")
        }
        let request = decoded.value
        let stream = request.stream == true
        line.clientModel = request.model
        line.stream = stream

        let candidates: [Candidate]
        do {
            candidates = try CandidatePlanner(configuration: configuration)
                .candidates(for: request.model, clientProtocol: clientProtocol, access: access)
        } catch {
            return fail(error.status, error.message, detail: error.detail, warnings: decoded.warnings)
        }
        let ordered = strategy.order(
            candidates, context: RoutingContext(clientProtocol: clientProtocol, stream: stream), health: health.snapshot(),
        )
        if ordered.isEmpty {
            return fail(
                503, "no upstream is available for model `\(request.model)`",
                detail: "every key is disabled after repeated 401s; reload the configuration to try them again",
                warnings: decoded.warnings,
            )
        }

        let settled = Settled<AttemptOutcome>()
        let work = Task {
            do {
                let outcome = try await monitor.run {
                    try await self.attempt(
                        request, decodeWarnings: decoded.warnings, candidates: ordered, stream: stream, clientHeaders: headers,
                        strict: configuration.strict, headTimeout: configuration.headTimeout, log: log, tracker: tracker,
                    )
                }
                settled.set(.success(outcome))
            } catch {
                settled.set(.failure(error))
            }
        }
        let result: Result<AttemptOutcome, any Error>
        if stream, clientProtocol.toleratesComments, let hold = heldStreams.headersAfter {
            // A stream still without content after `hold` gets its 200 and
            // SSE comments while the attempts go on (magpie's keepHeldAfter):
            // a comment is no event, so whichever candidate answers goes on
            // in the same response.
            guard let done = await settled.wait(upTo: hold) else {
                return heldStream(settled, work, clientProtocol: clientProtocol, request: request, decodeWarnings: decoded.warnings,
                                  configuration: configuration, monitor: monitor, line: line, log: log, tracker: tracker)
            }
            result = done
        } else {
            result = await settled.wait()
        }
        let outcome: AttemptOutcome
        switch result {
        case .success(let value): outcome = value
        case .failure: return fail(499, "client disconnected", warnings: decoded.warnings)
        }

        switch outcome {
        case .failure(let failure):
            let response = failureResponse(failure, clientProtocol: clientProtocol, warnings: decoded.warnings)
            monitor.uninstall()
            line.status = response.status.code
            Self.note(failure, decodeWarnings: decoded.warnings, on: &line)
            log.emit(line.text)
            tracker.finish(status: response.status.code, note: line.note)
            return response

        case .reply(let served):
            let candidate = served.candidate
            line.candidate = candidate.reference
            let warnings = served.requestWarnings + served.responseWarnings
            let defaults = ReplyDefaults(clientProtocol: clientProtocol, model: request.model, candidate: candidate)
            var fields = HTTPFields()
            fields[Self.modelHeader] = candidate.reference
            switch served.body {
            case .response(let response):
                monitor.uninstall()
                let encoded = ClientCodec.encodeResponse(response, for: clientProtocol, defaults: defaults)
                let responseWarnings = WireWarning.merged(decoded: served.responseWarnings, encoded: encoded.warnings)
                let all = served.requestWarnings + responseWarnings
                for warning in all { log.emit("warning: \(warning)") }
                fields[.contentType] = "application/json"
                if !all.isEmpty {
                    fields[WarningHeader.name] = WarningHeader.value(request: served.requestWarnings, response: responseWarnings)
                }
                line.status = 200
                line.warnings = all.count
                log.emit(line.text)
                tracker.serving(candidate, streaming: false)
                tracker.finish(status: 200, tokens: TokenCounts(response.usage))
                return Response(status: .ok, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: encoded.body)))

            case .events(let events):
                fields[.contentType] = "text/event-stream"
                fields[.cacheControl] = "no-cache"
                if !warnings.isEmpty {
                    fields[WarningHeader.name] = WarningHeader.value(request: served.requestWarnings, response: served.responseWarnings)
                }
                let finalLine = line
                tracker.serving(candidate, streaming: true)
                return Response(status: .ok, headers: fields, body: ResponseBody { writer in
                    defer { monitor.uninstall() }
                    try await self.forward(
                        served, events, clientProtocol: clientProtocol, request: request, configuration: configuration,
                        monitor: monitor, writer: &writer, line: finalLine, log: log, tracker: tracker,
                    )
                })
            }
        }
    }

    /// When a held stream gets its headers, and how often it then hears a
    /// comment; `nil` turns holding with comments off.
    struct HeldStreams: Sendable {
        var headersAfter: Duration? = .seconds(3)
        var commentEvery: Duration = .seconds(5)
    }

    /// The response of a stream whose attempts outlast
    /// ``HeldStreams/headersAfter``: a 200 now, SSE comments every
    /// ``HeldStreams/commentEvery`` until a candidate answers, then its
    /// reply; or, when none does, the failure as the stream's error event,
    /// since a status can no longer be said. `x-unladen-model` is not
    /// known when the headers go; the log line has it.
    func heldStream(
        _ settled: Settled<AttemptOutcome>,
        _ work: Task<Void, Never>,
        clientProtocol: WireProtocol,
        request: WireRequest,
        decodeWarnings: [WireWarning],
        configuration: GatewayConfiguration,
        monitor: DisconnectMonitor,
        line: LogLine,
        log: RequestLog,
        tracker: RequestTracker,
    ) -> Response {
        let fields: HTTPFields = [.contentType: "text/event-stream", .cacheControl: "no-cache"]
        let every = heldStreams.commentEvery
        return Response(status: .ok, headers: fields, body: ResponseBody { writer in
            defer { monitor.uninstall() }
            var line = line
            line.note = "headers sent before the first content"
            var result: Result<AttemptOutcome, any Error>?
            do {
                while result == nil {
                    try await writer.write(Self.frames([.comment("keepalive")]))
                    result = await settled.wait(upTo: every)
                }
            } catch {
                // The client left while it was kept waiting.
                work.cancel()
                line.status = 499
                line.note = "client disconnected while held"
                log.emit(line.text)
                tracker.finish(status: 499, note: line.note)
                return
            }
            switch result! {
            case .failure:
                line.status = 499
                line.note = "client disconnected while held"
                log.emit(line.text)
                tracker.finish(status: 499, note: line.note)
            case .success(.failure(let failure)):
                var encoder = ClientStreamEncoder(
                    for: clientProtocol, defaults: ReplyDefaults(clientProtocol: clientProtocol, model: request.model, candidate: nil),
                    includeUsage: false,
                )
                let (status, error) = Self.streamError(failure)
                line.status = status
                Self.note(failure, decodeWarnings: decodeWarnings, on: &line)
                line.note = "(in the stream) " + (line.note ?? "")
                log.emit(line.text)
                tracker.finish(status: status, note: line.note)
                try await writer.write(Self.frames(encoder.encode(.error(error)) + encoder.finish()))
                try await writer.finish(nil)
            case .success(.reply(let served)):
                line.candidate = served.candidate.reference
                guard case .events(let events) = served.body else {
                    // A stream request is always answered with events.
                    tracker.finish(status: 200)
                    try await writer.finish(nil)
                    return
                }
                tracker.serving(served.candidate, streaming: true)
                try await self.forward(
                    served, events, clientProtocol: clientProtocol, request: request, configuration: configuration,
                    monitor: monitor, writer: &writer, line: line, log: log, tracker: tracker,
                )
            }
        })
    }

    /// Streams a primed reply to `writer`, whose headers are sent: the
    /// warnings first as a comment where the protocol takes one, then the
    /// events. Logs the request and cools an upstream that broke off.
    @concurrent func forward(
        _ served: Served,
        _ events: PrimedEvents,
        clientProtocol: WireProtocol,
        request: WireRequest,
        configuration: GatewayConfiguration,
        monitor: DisconnectMonitor,
        writer: inout any ResponseBodyWriter,
        line: LogLine,
        log: RequestLog,
        tracker: RequestTracker? = nil,
    ) async throws {
        let candidate = served.candidate
        var line = line
        line.candidate = candidate.reference
        line.status = 200
        let warnings = served.requestWarnings + served.responseWarnings
        for warning in warnings { log.emit("warning: \(warning)") }
        let header = WarningHeader.value(request: served.requestWarnings, response: served.responseWarnings)
        let leading: [SSEElement] = !warnings.isEmpty && clientProtocol.toleratesComments
            ? [.comment("unladen-warnings: \(header)")]
            : []
        var encoder = ClientStreamEncoder(
            for: clientProtocol,
            defaults: ReplyDefaults(clientProtocol: clientProtocol, model: request.model, candidate: candidate),
            includeUsage: request.streamOptions?.includeUsage ?? false,
        )
        var summary = StreamSummary()
        do {
            summary = try await Self.pump(
                events, encoder: &encoder, leading: leading, keepalive: configuration.keepaliveInterval,
                idleTimeout: configuration.idleTimeout, monitor: monitor, writer: &writer,
            )
        } catch {
            summary.disconnected = true
        }
        // An upstream that breaks off mid-stream cools down; a client that
        // leaves says nothing about it.
        if summary.failure != nil, !summary.disconnected {
            health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown)
        }
        for warning in summary.warnings { log.emit("warning: \(warning)") }
        line.warnings = warnings.count + summary.warnings.count
        if summary.disconnected {
            line.note = "client disconnected mid-stream"
        } else if let failure = summary.failure {
            line.note = "upstream stream failed: \(failure)"
        }
        log.emit(line.text)
        tracker?.finish(
            status: summary.disconnected ? 499 : 200, note: line.note, tokens: TokenCounts(summary.usage),
            failed: summary.failure != nil && !summary.disconnected,
        )
        if !summary.disconnected { try await writer.finish(nil) }
    }

    /// What the log line says of a failed request.
    static func note(_ failure: AttemptFailure, decodeWarnings: [WireWarning], on line: inout LogLine) {
        line.candidate = failure.candidate?.reference
        line.warnings = decodeWarnings.count
        switch failure {
        case .upstream(_, let error):
            line.note = "upstream \(error.status.code): \(redactingSecrets(ErrorShape.upstreamMessage(error.body)))"
        case .gateway(_, let message, _):
            line.note = message
        case .strict(let warnings):
            line.warnings += warnings.count
        }
    }

    /// A failure told as a stream's error event, once its headers are out:
    /// the status it stands for, and a type and code clients act on
    /// (Codex compacts on `context_length_exceeded` and waits on
    /// `server_is_overloaded`; a plain server error it retries at once).
    static func streamError(_ failure: AttemptFailure) -> (status: Int, error: WireStreamError) {
        let status: Int
        let message: String
        switch failure {
        case .upstream(let candidate, let error) where credentialStatuses.contains(error.status.code):
            status = 502
            message = "upstream rejected the gateway's credentials for \(candidate.reference)"
        case .upstream(_, let error):
            status = error.status.code
            message = ErrorShape.upstreamMessage(error.body)
        case .gateway(let code, let text, _):
            status = code
            message = text
        case .strict(let lossy):
            status = 400
            message = "strict mode: the request cannot be carried exactly: \(WarningHeader.summary(lossy))"
        }
        let lower = message.lowercased()
        let (type, code): (String, String)
        if ["context_length_exceeded", "context length", "prompt is too long", "too many tokens", "maximum context"]
            .contains(where: lower.contains)
        {
            (type, code) = ("invalid_request_error", "context_length_exceeded")
        } else if status == 429 {
            (type, code) = ("rate_limit_error", "rate_limit_exceeded")
        } else if status == 529 || status == 503 || lower.contains("overloaded") {
            (type, code) = ("overloaded_error", "server_is_overloaded")
        } else if (400..<500).contains(status) {
            (type, code) = ("invalid_request_error", "invalid_request_error")
        } else {
            (type, code) = ("api_error", "server_error")
        }
        return (status, WireStreamError(message: message, type: type, code: code))
    }

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

    /// No content within the head timeout.
    struct HeadTimeout: Error {}

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
    func attempt(
        _ request: WireRequest,
        decodeWarnings: [WireWarning] = [],
        candidates: [Candidate],
        stream: Bool,
        clientHeaders: HTTPFields,
        strict: Bool = false,
        headTimeout: Duration? = nil,
        log: RequestLog = .silent,
        tracker: RequestTracker? = nil,
    ) async throws -> AttemptOutcome {
        var last: AttemptFailure?
        var strictWarnings: [WireWarning]?
        var unreachable: Set<String> = []
        // Upstream Chat streams report usage only when asked; the client's
        // own encoder still follows what the client asked for.
        var request = request
        if stream { request.streamOptions = WireStreamOptions(includeUsage: true, extra: request.streamOptions?.extra ?? [:]) }
        for candidate in candidates where !unreachable.contains(candidate.endpointID) {
            try Task.checkCancellation()
            let began = ContinuousClock.now
            var outcome = "skipped"
            defer { tracker?.tried(candidate, outcome: outcome, since: began) }
            let call = UpstreamCall(target: candidate.target, apiKey: candidate.apiKey, transport: transport)
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
                let (reply, primed) = try await Self.within(headTimeout) { () async throws -> (UpstreamReply, PrimeOutcome?) in
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
                    health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown)
                    last = .gateway(status: 502, message: "\(candidate.reference) failed before any content: \(message)", candidate: candidate)
                    outcome = "failed before any content: \(message)"
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
            } catch is HeadTimeout {
                // Slow but alive: no cooldown.
                let limit = headTimeout.map { " within \($0)" } ?? ""
                last = .gateway(status: 504, message: "\(candidate.reference) sent no content\(limit)", candidate: candidate)
                outcome = "no content\(limit)"
            } catch let error as UpstreamError {
                switch error {
                case .http(let http):
                    let status = http.status.code
                    outcome = "\(status)"
                    guard Self.isRetryable(status) else { return .failure(.upstream(candidate, http)) }
                    recordFailure(status: status, retryAfter: http.retryAfter, of: candidate, log: log)
                    last = .upstream(candidate, http)
                case .decoding(let decoding, _):
                    health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown)
                    last = .gateway(status: 502, message: "\(candidate.reference) sent a reply that cannot be decoded: \(decoding)", candidate: candidate)
                    outcome = "reply cannot be decoded"
                case .stream(let streamError):
                    health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown)
                    last = .gateway(status: 502, message: "\(candidate.reference) failed: \(streamError.message)", candidate: candidate)
                    outcome = "error: \(streamError.message)"
                case .invalidBaseURL(let url):
                    last = .gateway(status: 500, message: "invalid base URL \(url)", candidate: candidate)
                    outcome = "invalid base URL"
                }
            } catch let error as HTTPResponseBodyTooLargeError {
                health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown)
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
                health.recordFailure(candidate.endpointScope, base: HealthStore.failureCooldown)
                unreachable.insert(candidate.endpointID)
                last = .gateway(status: 502, message: "\(candidate.reference) is unreachable: \(error)", candidate: candidate)
            }
        }
        if let last { return .failure(last) }
        if let strictWarnings { return .failure(.strict(strictWarnings)) }
        return .failure(.gateway(status: 503, message: "no upstream available", candidate: nil))
    }

    /// Records an upstream error status against what it is about: the key
    /// (refused, out of credit, rate limited) or the model at its address.
    func recordFailure(status: Int, retryAfter: String?, of candidate: Candidate, log: RequestLog) {
        let key = candidate.keyScope ?? candidate.modelScope
        switch status {
        case 401:
            if let scope = candidate.keyScope, health.recordUnauthorized(scope) {
                log.emit(
                    "key \(candidate.keyName) of \(candidate.target.provider) is disabled after \(HealthStore.unauthorizedLimit) "
                        + "refusals in a row (401); reload the configuration to use it again",
                )
            }
            health.recordFailure(key, base: HealthStore.maxCooldown)
        case 402: health.recordFailure(key, base: HealthStore.paymentCooldown)
        case 403: health.recordFailure(key, base: HealthStore.maxCooldown)
        case 429: health.recordFailure(key, base: HealthStore.rateLimitCooldown, retryAfter: HealthStore.retryAfter(retryAfter))
        case 404: health.recordFailure(candidate.modelScope, base: HealthStore.maxCooldown)
        default:
            health.recordFailure(candidate.modelScope, base: HealthStore.failureCooldown, retryAfter: HealthStore.retryAfter(retryAfter))
        }
    }

    // MARK: First content

    enum PrimeOutcome: Sendable {
        case ready(PrimedEvents)
        case failed(String)
    }

    /// Reads `events` up to the first event worth sending (content, or the
    /// finish of an empty reply): an error event, a stream that ends or
    /// breaks off before it, is a failure.
    static func prime(_ events: UpstreamEventStream) async throws -> PrimeOutcome {
        var iterator = events.makeAsyncIterator()
        var buffered: [WireEvent] = []
        do {
            while let event = try await iterator.next() {
                if case .error(let error) = event { return .failed(error.message) }
                buffered.append(event)
                if event.startsTheReply { return .ready(PrimedEvents(buffered: buffered, iterator: iterator)) }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return .failed("the stream broke off: \(error)")
        }
        return .failed("the stream ended without content")
    }

    /// `operation`, or ``HeadTimeout`` when it takes longer than `limit`
    /// (the operation is then cancelled).
    static func within<T: Sendable>(_ limit: Duration?, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let limit else { return try await operation() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw HeadTimeout() }
            return value
        }
    }

    // MARK: Errors

    static let modelHeader = HTTPField.Name("x-unladen-model")!

    /// Upstream headers forwarded with a same-protocol error.
    static let forwardedErrorHeaders: [String] = [
        "retry-after", "request-id", "x-request-id", "x-goog-request-id", "openai-request-id",
    ]

    /// Upstream statuses that mean the gateway's own key was refused.
    static let credentialStatuses: Set<Int> = [401, 402, 403]

    /// The client's response for a request no candidate served.
    ///
    /// An upstream 401/402/403 is about the gateway's key, not the
    /// client's: the client gets a 502 with a gateway message, never the
    /// upstream's body (which can quote part of the key).
    func failureResponse(_ failure: AttemptFailure, clientProtocol: WireProtocol, warnings: [WireWarning]) -> Response {
        switch failure {
        case .upstream(let candidate, let error) where Self.credentialStatuses.contains(error.status.code):
            var response = Self.errorResponse(
                clientProtocol, status: 502,
                message: "upstream rejected the gateway's credentials for \(candidate.reference)", warnings: warnings,
            )
            response.headers[Self.modelHeader] = candidate.reference
            return response
        case .upstream(let candidate, let error):
            var fields = HTTPFields()
            for name in Self.forwardedErrorHeaders {
                if let field = HTTPField.Name(name), let value = error.headerFields[field] { fields[field] = value }
            }
            for field in error.headerFields where field.name.canonicalName.hasPrefix("x-ratelimit-")
                || field.name.canonicalName.hasPrefix("anthropic-ratelimit-")
            {
                fields.append(field)
            }
            fields[Self.modelHeader] = candidate.reference
            if !warnings.isEmpty { fields[WarningHeader.name] = WarningHeader.value(request: warnings) }
            let body: [UInt8]
            if candidate.upstreamProtocol == clientProtocol {
                // Same protocol: the upstream's error, verbatim.
                fields[.contentType] = error.headerFields[.contentType] ?? "application/json"
                body = error.body
            } else {
                fields[.contentType] = "application/json"
                body = ErrorShape.body(for: clientProtocol, status: error.status.code, message: ErrorShape.upstreamMessage(error.body))
            }
            return Response(status: error.status, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: body)))
        case .gateway(let status, let message, _):
            return Self.errorResponse(clientProtocol, status: status, message: message, warnings: warnings)
        case .strict(let lossy):
            return Self.errorResponse(
                clientProtocol, status: 400,
                message: "strict mode: the request cannot be carried exactly: \(WarningHeader.summary(lossy))", warnings: lossy,
            )
        }
    }

    static func errorResponse(_ clientProtocol: WireProtocol, status: Int, message: String, warnings: [WireWarning] = []) -> Response {
        var fields: HTTPFields = [.contentType: "application/json"]
        if !warnings.isEmpty { fields[WarningHeader.name] = WarningHeader.value(request: warnings) }
        return Response(
            status: HTTPResponse.Status(code: status),
            headers: fields,
            body: ResponseBody(byteBuffer: ByteBuffer(bytes: ErrorShape.body(for: clientProtocol, status: status, message: message))),
        )
    }

    // MARK: Streaming

    struct StreamSummary: Sendable {
        var warnings: [WireWarning] = []
        var failure: String?
        var disconnected = false
        /// The usage the stream reported last.
        var usage: WireUsage?
    }

    enum PumpSignal: Sendable {
        case event(WireEvent)
        case end([WireWarning])
        case failed(String, [WireWarning])
        case tick
        case stopped
    }

    /// Pipes upstream events through the client's encoder to `writer`,
    /// one write (and flush) per encoded batch.
    ///
    /// Three sources feed one queue: the upstream reader task, a ticker
    /// task for keepalives, and the disconnect monitor. The writer (this
    /// task) is the only consumer; leaving the loop, for any reason,
    /// cancels the reader, which cancels the upstream request. A keepalive is sent when no event has
    /// been written for `keepalive`. An upstream that fails mid-stream, or
    /// sends nothing (not even a ping) for `idleTimeout`, is reported with
    /// the client encoder's error rendering; there is no fallback once the
    /// response has started.
    @concurrent static func pump(
        _ events: PrimedEvents,
        encoder: inout ClientStreamEncoder,
        leading: [SSEElement],
        keepalive: Duration,
        idleTimeout: Duration? = nil,
        monitor: DisconnectMonitor,
        writer: inout any ResponseBodyWriter,
    ) async throws -> StreamSummary {
        let (signals, continuation) = AsyncStream<PumpSignal>.makeStream()
        let token = monitor.onDisconnect { continuation.yield(.stopped) }
        defer {
            monitor.remove(token)
            continuation.finish()
        }
        var summary = StreamSummary()
        let reader = Task {
            for event in events.buffered { continuation.yield(.event(event)) }
            var iterator = events.iterator
            do {
                while let event = try await iterator.next() {
                    continuation.yield(.event(event))
                }
                continuation.yield(.end(iterator.warnings))
            } catch {
                if Task.isCancelled || error is CancellationError {
                    continuation.yield(.stopped)
                } else {
                    continuation.yield(.failed(String(describing: error), iterator.warnings))
                }
            }
        }
        let ticker = Task {
            let tick = min(keepalive, idleTimeout ?? keepalive) / 4
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                continuation.yield(.tick)
            }
        }
        defer {
            reader.cancel()
            ticker.cancel()
        }

        var lastEvent = ContinuousClock.now
        var lastUpstream = ContinuousClock.now
        if !leading.isEmpty { try await writer.write(Self.frames(leading)) }
        loop: for await signal in signals {
            var out: [SSEElement] = []
            var done = false
            switch signal {
            case .event(let event):
                lastUpstream = .now
                switch event {
                case .finish(let finish) where finish.usage != nil: summary.usage = finish.usage
                case .responseMetadata(let metadata) where metadata.usage != nil && summary.usage == nil: summary.usage = metadata.usage
                default: break
                }
                out = encoder.encode(event)
            case .end(let warnings):
                summary.warnings += warnings
                out = encoder.finish()
                done = true
            case .failed(let message, let warnings):
                summary.warnings += warnings
                summary.failure = message
                out = encoder.encode(.error(WireStreamError(message: "upstream stream failed: \(message)"))) + encoder.finish()
                done = true
            case .tick:
                if let idleTimeout, ContinuousClock.now - lastUpstream >= idleTimeout {
                    summary.failure = "no upstream event for \(idleTimeout)"
                    out = encoder.encode(.error(WireStreamError(message: "upstream stream stalled: \(summary.failure!)"))) + encoder.finish()
                    done = true
                } else if ContinuousClock.now - lastEvent >= keepalive {
                    out = encoder.keepalive()
                    lastEvent = .now
                }
            case .stopped:
                summary.disconnected = true
                break loop
            }
            if !out.isEmpty {
                try await writer.write(Self.frames(out))
                if out.contains(where: { if case .event = $0 { true } else { false } }) { lastEvent = .now }
            }
            if done { break loop }
        }
        summary.warnings += encoder.warnings
        return summary
    }

    /// SSE bytes of `elements`, for one write.
    static func frames(_ elements: [SSEElement]) -> ByteBuffer {
        var bytes: [UInt8] = []
        for element in elements { SSEWriter.encode(element, into: &bytes) }
        return ByteBuffer(bytes: bytes)
    }

    // MARK: Redaction

    /// `text` with anything that looks like an API key replaced by
    /// `[redacted]`, for logging upstream error messages: words with a
    /// vendor key prefix (`sk-`, `AIza`, `xai-`…), masked keys (`****`), and
    /// long runs of letters and digits.
    static func redactingSecrets(_ text: String) -> String {
        let separators: Set<Character> = [" ", "\t", "\n", "\r", "\"", "'", "`", ",", ";", "(", ")", "[", "]", "{", "}", "<", ">", "="]
        var out = ""
        var word = ""
        func flush() {
            var core = Substring(word)
            var trailing = ""
            while let last = core.last, [".", ":", "!", "?"].contains(last) {
                trailing = String(last) + trailing
                core = core.dropLast()
            }
            out += (isSecret(core) ? "[redacted]" : String(core)) + trailing
            word = ""
        }
        for character in text {
            if separators.contains(character) {
                flush()
                out.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return out
    }

    static let keyPrefixes = ["sk-", "sk_", "pk-", "rk-", "AIza", "xai-", "gsk_", "key-", "ya29."]

    static func isSecret(_ word: Substring) -> Bool {
        guard word.count >= 8 else { return false }
        if keyPrefixes.contains(where: { word.hasPrefix($0) }) { return true }
        if word.contains("***") || word.contains("…") { return true }
        let keyish = word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return keyish && word.count >= 32 && word.contains(where: \.isNumber) && word.contains(where: \.isLetter)
    }
}

/// The `x-unladen-warnings` header: a count and the warnings, compact,
/// ASCII, truncated. Each is labelled `request:` (decoding the client's
/// request, transforming and encoding it for the upstream) or `response:`
/// (decoding the upstream's reply, encoding it for the client).
enum WarningHeader {
    static let name = HTTPField.Name("x-unladen-warnings")!
    static let limit = 1024

    static func summary(_ warnings: [WireWarning]) -> String {
        warnings.map(\.description).joined(separator: "; ")
    }

    static func value(request: [WireWarning], response: [WireWarning] = []) -> String {
        let labelled = request.map { "request: \($0)" } + response.map { "response: \($0)" }
        var text = "\(labelled.count): " + labelled.joined(separator: "; ")
        text = String(text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F ? Character($0) : "?" })
        if text.utf8.count > limit {
            text = String(text.prefix(limit - 3)) + "..."
        }
        return text
    }
}

/// The request's log line: client protocol, model → candidate, status,
/// duration, warnings count. No bodies.
struct LogLine: Sendable {
    var clientProtocol: WireProtocol
    var start: ContinuousClock.Instant
    var clientModel = "?"
    var candidate: String?
    var stream = false
    var status = 0
    var warnings = 0
    var note: String?

    var text: String {
        let elapsed = ContinuousClock.now - start
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        var text = "\(clientProtocol.displayName)\(stream ? " stream" : "") \(clientModel) → \(candidate ?? "-") status=\(status) \(ms)ms warnings=\(warnings)"
        if let note { text += " (\(note.prefix(300)))" }
        return text
    }
}

/// An upstream stream read up to its first content: the events read so far,
/// and the iterator for the rest.
///
/// One task at a time uses it: the attempt that primes it, then the pump's
/// reader, which takes the iterator over.
final class PrimedEvents: @unchecked Sendable {
    let buffered: [WireEvent]
    let iterator: UpstreamEventStream.Iterator

    init(buffered: [WireEvent], iterator: UpstreamEventStream.Iterator) {
        self.buffered = buffered
        self.iterator = iterator
    }
}

extension WireEvent {
    /// Whether the client can be sent the reply from this event on:
    /// content, or the finish of a reply without any.
    var startsTheReply: Bool {
        switch self {
        case .textStart, .textDelta, .textEnd, .reasoningStart, .reasoningDelta, .reasoningSignatureDelta, .reasoningEnd,
             .refusalStart, .refusalDelta, .refusalEnd, .toolInputStart, .toolInputDelta, .toolInputEnd, .toolCall, .opaque,
             .finish:
            true
        case .responseMetadata, .ping, .error:
            false
        }
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
