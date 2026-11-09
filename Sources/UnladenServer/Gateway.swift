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
    /// The tokens of accounts that sign in.
    var signIns = SignIns()
    /// Providers' model lists, for `GET /v1/models`.
    var models = ModelCatalog()
    /// Accounts' plan allowances, for the panel.
    var quotas = QuotaReader()

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
    /// changed, which start afresh, and keys that are gone, which are
    /// forgotten. Keys disabled after repeated 401s get another chance.
    func replace(_ configuration: GatewayConfiguration) {
        let old = store.replace(configuration)
        var changed: Set<HealthScope> = []
        for (provider, pool) in old.keyPools {
            let now = configuration.keyPools[provider]?.keys ?? []
            for key in pool.keys where !now.contains(where: { $0.name == key.name && $0.secret == key.secret }) {
                changed.insert(.key(provider: provider, keyName: key.name))
            }
        }
        if !changed.isEmpty { health.forget { changed.contains($0) } }
        health.enableDisabledKeys()
        models.forget()
        quotas.forget()
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
        let parsed = Result { () throws(WireDecodingError) in
            try ClientCodec.parseRequest(clientProtocol, body: body, geminiPath: geminiPath)
        }
        let origin = RequestOrigin(headers: headers, request: try? parsed.get().value, access: access)
        let tracker = activity.begin(RequestRecord(
            started: LocalDay.nowMilliseconds(),
            origin: origin,
            clientProtocol: clientProtocol.displayName, model: (try? parsed.get().value.model) ?? geminiPath?.model ?? "?",
            stream: (try? parsed.get().value.stream) == true || geminiPath?.stream == true,
        ), log: log)
        func fail(_ status: Int, _ message: String, detail: String? = nil, warnings: [WireWarning] = []) -> Response {
            monitor.uninstall()
            tracker.finish(status: status, note: detail ?? message, warnings: warnings.count)
            return Self.errorResponse(clientProtocol, status: status, message: message, warnings: warnings)
        }

        let decoded: WireDecoded<WireRequest>
        switch parsed {
        case .success(let value): decoded = value
        case .failure(let error): return fail(400, "invalid request: \(error)")
        }
        let request = decoded.value
        let stream = request.stream == true

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
                        request, decodeWarnings: decoded.warnings, candidates: ordered, stream: stream, clientHeaders: headers, session: origin.session,
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
            // SSE comments while the attempts go on:
            // a comment is no event, so whichever candidate answers goes on
            // in the same response.
            guard let done = await settled.wait(upTo: hold) else {
                return heldStream(settled, work, clientProtocol: clientProtocol, request: request, decodeWarnings: decoded.warnings,
                                  configuration: configuration, monitor: monitor, log: log, tracker: tracker)
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
            let (note, warnings) = Self.note(failure, decodeWarnings: decoded.warnings)
            tracker.finish(status: response.status.code, note: note, warnings: warnings)
            return response

        case .reply(let served):
            let candidate = served.candidate
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
                tracker.serving(candidate, streaming: false)
                tracker.finish(status: 200, tokens: TokenCounts(response.usage), warnings: all.count)
                return Response(status: .ok, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: encoded.body)))

            case .events(let events):
                fields[.contentType] = "text/event-stream"
                fields[.cacheControl] = "no-cache"
                if !warnings.isEmpty {
                    fields[WarningHeader.name] = WarningHeader.value(request: served.requestWarnings, response: served.responseWarnings)
                }
                tracker.serving(candidate, streaming: true)
                return Response(status: .ok, headers: fields, body: ResponseBody { writer in
                    defer { monitor.uninstall() }
                    try await self.forward(
                        served, events, clientProtocol: clientProtocol, request: request, configuration: configuration,
                        monitor: monitor, writer: &writer, log: log, tracker: tracker,
                    )
                })
            }
        }
    }
}
