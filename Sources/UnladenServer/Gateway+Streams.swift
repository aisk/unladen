// Streamed replies: holding a stream with comments until a candidate
// answers, then pumping its events to the client.

import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
@_spi(Wire) import UnladenCore

extension Gateway {
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
        log: RequestLog,
        tracker: RequestTracker,
    ) -> Response {
        let fields: HTTPFields = [.contentType: "text/event-stream", .cacheControl: "no-cache"]
        let every = heldStreams.commentEvery
        return Response(status: .ok, headers: fields, body: ResponseBody { writer in
            defer { monitor.uninstall() }
            var result: Result<AttemptOutcome, any Error>?
            do {
                while result == nil {
                    try await writer.write(Self.frames([.comment("keepalive")]))
                    result = await settled.wait(upTo: every)
                }
            } catch {
                // The client left while it was kept waiting.
                work.cancel()
                tracker.finish(status: 499, note: "client disconnected while held")
                return
            }
            switch result! {
            case .failure:
                tracker.finish(status: 499, note: "client disconnected while held")
            case .success(.failure(let failure)):
                var encoder = ClientStreamEncoder(
                    for: clientProtocol, defaults: ReplyDefaults(clientProtocol: clientProtocol, model: request.model, candidate: nil),
                    includeUsage: false,
                )
                let (status, error) = Self.streamError(failure)
                let (note, warnings) = Self.note(failure, decodeWarnings: decodeWarnings)
                tracker.finish(status: status, note: "(in the stream) " + (note ?? ""), warnings: warnings)
                try await writer.write(Self.frames(encoder.encode(.error(error)) + encoder.finish()))
                try await writer.finish(nil)
            case .success(.reply(let served)):
                guard case .events(let events) = served.body else {
                    // A stream request is always answered with events.
                    tracker.finish(status: 200)
                    try await writer.finish(nil)
                    return
                }
                tracker.serving(served.candidate, streaming: true)
                try await self.forward(
                    served, events, clientProtocol: clientProtocol, request: request, configuration: configuration,
                    monitor: monitor, writer: &writer, log: log, tracker: tracker,
                    note: "headers sent before the first content",
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
        log: RequestLog,
        tracker: RequestTracker,
        note: String? = nil,
    ) async throws {
        let candidate = served.candidate
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
        var note = note
        if summary.disconnected {
            note = "client disconnected mid-stream"
        } else if let failure = summary.failure {
            note = "upstream stream failed: \(failure)"
        }
        tracker.finish(
            status: summary.disconnected ? 499 : 200, note: note, tokens: TokenCounts(summary.usage),
            warnings: warnings.count + summary.warnings.count, failed: summary.failure != nil && !summary.disconnected,
        )
        if !summary.disconnected, !summary.closedAfterEnd { try await writer.finish(nil) }
    }

    /// What the record says of a failed request: its note and its
    /// warnings count.
    static func note(_ failure: AttemptFailure, decodeWarnings: [WireWarning]) -> (String?, Int) {
        switch failure {
        case .upstream(_, let error):
            ("upstream \(error.status.code): \(redactingSecrets(ErrorShape.upstreamMessage(error.body)))", decodeWarnings.count)
        case .gateway(_, let message, _):
            (message, decodeWarnings.count)
        case .strict(let warnings):
            (nil, decodeWarnings.count + warnings.count)
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

    // MARK: Streaming

    struct StreamSummary: Sendable {
        var warnings: [WireWarning] = []
        var failure: String?
        var disconnected = false
        /// The client was sent its stream's end (the finish event), so
        /// its leaving after that is no disconnect.
        var ended = false
        /// The client closed its connection after the stream's end.
        var closedAfterEnd = false
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
                // Chat clients close on `[DONE]`, which goes with the
                // finish event, while the upstream may still be ending.
                if summary.ended { summary.closedAfterEnd = true } else { summary.disconnected = true }
                break loop
            }
            if !out.isEmpty {
                try await writer.write(Self.frames(out))
                if out.contains(where: { if case .event = $0 { true } else { false } }) { lastEvent = .now }
            }
            if case .event(.finish) = signal { summary.ended = true }
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
