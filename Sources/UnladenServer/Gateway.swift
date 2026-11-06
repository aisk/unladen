// One request through the gateway: decode → candidates → fallback loop →
// re-encode for the client (complete or streamed).

import HTTPTypes
import Hummingbird
import NIOCore
@_spi(Wire) import UnladenCore

/// Writes the request's one log line.
struct RequestLog: Sendable {
    var emit: @Sendable (String) -> Void

    static let silent = RequestLog { _ in }
}

/// The protocol-translating core, shared by the four ingress routes.
struct Gateway: Sendable {
    var configuration: GatewayConfiguration
    var transport: any HTTPTransport
    var strategy: any RoutingStrategy = OrderedKeyRotation()
    var health = HealthStore()

    init(configuration: GatewayConfiguration, transport: any HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    var planner: CandidatePlanner { CandidatePlanner(configuration: configuration) }

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
        monitor: DisconnectMonitor,
        log: RequestLog,
    ) async -> Response {
        let start = ContinuousClock.now
        var line = LogLine(clientProtocol: clientProtocol, start: start)
        func fail(_ status: Int, _ message: String, warnings: [WireWarning] = []) -> Response {
            monitor.uninstall()
            line.status = status
            line.warnings = warnings.count
            line.note = message
            log.emit(line.text)
            return Self.errorResponse(clientProtocol, status: status, message: message, warnings: warnings)
        }

        let decoded: WireDecoded<WireRequest>
        do {
            decoded = try ClientCodec.parseRequest(clientProtocol, body: body, geminiPath: geminiPath)
        } catch {
            return fail(400, "invalid request: \(error)")
        }
        let request = decoded.value
        let stream = request.stream == true
        line.clientModel = request.model
        line.stream = stream
        if configuration.strict, !decoded.warnings.isEmpty {
            return fail(400, "strict mode: the request cannot be carried exactly: \(WarningHeader.summary(decoded.warnings))", warnings: decoded.warnings)
        }

        let candidates: [Candidate]
        do {
            candidates = try planner.candidates(for: request.model, clientProtocol: clientProtocol)
        } catch {
            return fail(error.status, error.message, warnings: decoded.warnings)
        }
        let ordered = strategy.order(
            candidates, context: RoutingContext(clientProtocol: clientProtocol, stream: stream), health: health.snapshot(),
        )

        let outcome: AttemptOutcome
        do {
            outcome = try await monitor.run {
                try await self.attempt(request, candidates: ordered, stream: stream, clientHeaders: headers)
            }
        } catch {
            return fail(499, "client disconnected", warnings: decoded.warnings)
        }

        switch outcome {
        case .failure(let failure):
            line.candidate = failure.candidate?.reference
            let response = failureResponse(failure, clientProtocol: clientProtocol, warnings: decoded.warnings)
            monitor.uninstall()
            line.status = response.status.code
            line.warnings = decoded.warnings.count
            if case .upstream(_, let error) = failure { line.note = "upstream: \(ErrorShape.upstreamMessage(error.body))" }
            if case .gateway(_, let message, _) = failure { line.note = message }
            if case .strict(let warnings) = failure { line.warnings += warnings.count }
            log.emit(line.text)
            return response

        case .reply(let candidate, let reply):
            line.candidate = candidate.reference
            let warnings = decoded.warnings + reply.warnings
            let defaults = ReplyDefaults(clientProtocol: clientProtocol, model: request.model, candidate: candidate)
            var fields = HTTPFields()
            fields[Self.modelHeader] = candidate.reference
            switch reply.body {
            case .response(let response):
                monitor.uninstall()
                let encoded = ClientCodec.encodeResponse(response, for: clientProtocol, defaults: defaults)
                let all = warnings + encoded.warnings
                for warning in all { log.emit("warning: \(warning)") }
                fields[.contentType] = "application/json"
                if !all.isEmpty { fields[WarningHeader.name] = WarningHeader.value(all) }
                line.status = 200
                line.warnings = all.count
                log.emit(line.text)
                return Response(status: .ok, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: encoded.body)))

            case .events(let events):
                for warning in warnings { log.emit("warning: \(warning)") }
                fields[.contentType] = "text/event-stream"
                fields[.cacheControl] = "no-cache"
                if !warnings.isEmpty { fields[WarningHeader.name] = WarningHeader.value(warnings) }
                let leading: [SSEElement] = !warnings.isEmpty && clientProtocol.toleratesComments
                    ? [.comment("unladen-warnings: \(WarningHeader.value(warnings))")]
                    : []
                let encoder = ClientStreamEncoder(
                    for: clientProtocol, defaults: defaults, includeUsage: request.streamOptions?.includeUsage ?? false,
                )
                let interval = configuration.keepaliveInterval
                let finalLine = line
                let requestWarnings = warnings.count
                return Response(status: .ok, headers: fields, body: ResponseBody { writer in
                    defer { monitor.uninstall() }
                    var line = finalLine
                    line.status = 200
                    var summary = StreamSummary()
                    var encoder = encoder
                    do {
                        summary = try await Self.pump(
                            events, encoder: &encoder, leading: leading, keepalive: interval, monitor: monitor, writer: &writer,
                        )
                    } catch {
                        summary.disconnected = true
                    }
                    for warning in summary.warnings { log.emit("warning: \(warning)") }
                    line.warnings = requestWarnings + summary.warnings.count
                    if summary.disconnected {
                        line.note = "client disconnected mid-stream"
                    } else if let failure = summary.failure {
                        line.note = "upstream stream failed: \(failure)"
                    }
                    log.emit(line.text)
                    if !summary.disconnected { try await writer.finish(nil) }
                })
            }
        }
    }

    // MARK: Fallback loop

    enum AttemptOutcome: Sendable {
        case reply(Candidate, UpstreamReply)
        case failure(AttemptFailure)
    }

    enum AttemptFailure: Sendable {
        /// A non-2xx upstream reply that ends the request (or the last one).
        case upstream(Candidate, UpstreamHTTPError)
        /// A failure without an upstream reply to forward.
        case gateway(status: Int, message: String, candidate: Candidate?)
        /// `--strict`: every candidate's request carried warnings.
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
    /// server errors, timeouts and key problems (another key or provider
    /// may work). Other 4xx are the request's fault and end it.
    static func isRetryable(_ status: Int) -> Bool {
        switch status {
        case 401, 402, 403, 408, 409, 425, 429: true
        case 500..<600: true
        default: false
        }
    }

    /// Tries `candidates` in order until one returns a 2xx head. Each gets
    /// its own copy of `request` (value semantics), transformed and encoded
    /// for its endpoint.
    func attempt(_ request: WireRequest, candidates: [Candidate], stream: Bool, clientHeaders: HTTPFields) async throws -> AttemptOutcome {
        var last: AttemptFailure?
        var strictWarnings: [WireWarning]?
        for candidate in candidates {
            try Task.checkCancellation()
            let call = UpstreamCall(target: candidate.target, apiKey: candidate.apiKey, transport: transport)
            let prepared: UpstreamRequest
            do {
                prepared = try call.prepare(request, stream: stream, clientHeaders: clientHeaders)
            } catch {
                last = .gateway(status: 500, message: "cannot call \(candidate.reference): \(error)", candidate: candidate)
                continue
            }
            if configuration.strict, !prepared.warnings.isEmpty {
                strictWarnings = strictWarnings ?? prepared.warnings
                continue
            }
            do {
                let reply = try await call.send(prepared, stream: stream)
                health.recordSuccess(candidate.healthKey)
                return .reply(candidate, reply)
            } catch let error as UpstreamError {
                switch error {
                case .http(let http):
                    let status = http.status.code
                    guard Self.isRetryable(status) else { return .failure(.upstream(candidate, http)) }
                    let cooldown: Duration = [401, 402, 403].contains(status)
                        ? HealthStore.maxCooldown
                        : HealthStore.cooldown(status: status, retryAfter: http.retryAfter)
                    health.recordFailure(candidate.healthKey, cooldown: cooldown)
                    last = .upstream(candidate, http)
                case .decoding(let decoding, _):
                    health.recordFailure(candidate.healthKey, cooldown: HealthStore.failureCooldown)
                    last = .gateway(status: 502, message: "\(candidate.reference) sent a reply that cannot be decoded: \(decoding)", candidate: candidate)
                case .stream(let streamError):
                    health.recordFailure(candidate.healthKey, cooldown: HealthStore.failureCooldown)
                    last = .gateway(status: 502, message: "\(candidate.reference) failed: \(streamError.message)", candidate: candidate)
                case .invalidBaseURL(let url):
                    last = .gateway(status: 500, message: "invalid base URL \(url)", candidate: candidate)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                health.recordFailure(candidate.healthKey, cooldown: HealthStore.failureCooldown)
                last = .gateway(status: 502, message: "\(candidate.reference) is unreachable: \(error)", candidate: candidate)
            }
        }
        if let last { return .failure(last) }
        if let strictWarnings { return .failure(.strict(strictWarnings)) }
        return .failure(.gateway(status: 503, message: "no upstream available", candidate: nil))
    }

    // MARK: Errors

    static let modelHeader = HTTPField.Name("x-unladen-model")!

    /// Upstream headers forwarded with a same-protocol error.
    static let forwardedErrorHeaders: [String] = [
        "retry-after", "request-id", "x-request-id", "x-goog-request-id", "openai-request-id",
    ]

    func failureResponse(_ failure: AttemptFailure, clientProtocol: WireProtocol, warnings: [WireWarning]) -> Response {
        switch failure {
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
            if !warnings.isEmpty { fields[WarningHeader.name] = WarningHeader.value(warnings) }
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
        case .strict(let more):
            let all = warnings + more
            return Self.errorResponse(
                clientProtocol, status: 400,
                message: "strict mode: the request cannot be carried exactly: \(WarningHeader.summary(all))", warnings: all,
            )
        }
    }

    static func errorResponse(_ clientProtocol: WireProtocol, status: Int, message: String, warnings: [WireWarning] = []) -> Response {
        var fields: HTTPFields = [.contentType: "application/json"]
        if !warnings.isEmpty { fields[WarningHeader.name] = WarningHeader.value(warnings) }
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
    /// been written for `keepalive`. An upstream that fails mid-stream is
    /// reported with the client encoder's error rendering; there is no
    /// fallback once the response has started.
    @concurrent static func pump(
        _ events: UpstreamEventStream,
        encoder: inout ClientStreamEncoder,
        leading: [SSEElement],
        keepalive: Duration,
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
            var iterator = events.makeAsyncIterator()
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
            let tick = keepalive / 4
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
        if !leading.isEmpty { try await writer.write(Self.frames(leading)) }
        loop: for await signal in signals {
            var out: [SSEElement] = []
            switch signal {
            case .event(let event):
                out = encoder.encode(event)
            case .end(let warnings):
                summary.warnings += warnings
                out = encoder.finish()
            case .failed(let message, let warnings):
                summary.warnings += warnings
                summary.failure = message
                out = encoder.encode(.error(WireStreamError(message: "upstream stream failed: \(message)"))) + encoder.finish()
            case .tick:
                if ContinuousClock.now - lastEvent >= keepalive {
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
            switch signal {
            case .end, .failed: break loop
            default: continue
            }
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
}

/// The `x-unladen-warnings` header: a count and the warnings, compact,
/// ASCII, truncated.
enum WarningHeader {
    static let name = HTTPField.Name("x-unladen-warnings")!
    static let limit = 1024

    static func summary(_ warnings: [WireWarning]) -> String {
        warnings.map(\.description).joined(separator: "; ")
    }

    static func value(_ warnings: [WireWarning]) -> String {
        var text = "\(warnings.count): " + summary(warnings)
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
