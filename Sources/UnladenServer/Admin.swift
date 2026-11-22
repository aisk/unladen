// The control panel's backend: the configuration file read and saved as a
// document, reloads (the panel's and SIGHUP's), and the status of accounts.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import Hummingbird
import Logging
import NIOConcurrencyHelpers
import NIOCore
@_spi(Wire) import UnladenCore

#if canImport(Glibc)
import Glibc
private let systemWrite = Glibc.write
#elseif canImport(Darwin)
import Darwin
private let systemWrite = Darwin.write
#endif

/// Loads, reloads and saves the configuration. Saves and reloads run one
/// at a time; a configuration that fails to load leaves the current one in
/// force.
final class ConfigManager: Sendable {
    /// The file reloads read and saves write; `nil`: flags and environment
    /// only, nothing to save.
    let path: String?
    let overrides: ConfigOverrides
    /// What the listener and the HTTP client were started with.
    let server: ServerSettings
    let gateway: Gateway
    let logger: Logger
    let environment: @Sendable (String) -> String?
    private let lock = NIOLock()

    init(
        path: String?, overrides: ConfigOverrides, server: ServerSettings, gateway: Gateway, logger: Logger,
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
    ) {
        self.path = path
        self.overrides = overrides
        self.server = server
        self.gateway = gateway
        self.logger = logger
        self.environment = environment
    }

    /// Reads the file again and serves it.
    @discardableResult
    func reload() -> Bool {
        lock.withLock { reloadLocked() }
    }

    private func reloadLocked() -> Bool {
        let loaded: LoadedConfiguration
        do {
            loaded = try ConfigLoader.load(path: path, overrides: overrides, environment: environment)
        } catch {
            logger.error("configuration not reloaded, the current one stays: \(error)")
            return false
        }
        gateway.replace(loaded.gateway)
        // A sign-in from the command line writes the file.
        gateway.signIns.load()
        logger.info("configuration reloaded from \(loaded.path ?? "flags and environment")")
        if loaded.server != server {
            logger.warning("listen and advanced.connect_timeout take effect after a restart")
        }
        for warning in loaded.warnings + exposure(loaded.gateway) { logger.warning("\(warning)") }
        for line in Summary.lines(loaded.gateway) { logger.info("\(line)") }
        return true
    }

    /// A configuration without clients, on an address others can reach;
    /// checked again on each reload, since the file can drop its clients.
    private func exposure(_ configuration: GatewayConfiguration) -> [String] {
        guard configuration.isOpen, !UnladenCommand.isLoopback(server.host) else { return [] }
        return ["clients: none is configured and the gateway listens on \(server.host): anyone who reaches it can use its accounts"]
    }

    /// The file as the panel edits it.
    func document() throws(ConfigError) -> ConfigDocument.Snapshot {
        try ConfigDocument.read(try readFile(), file: path ?? "config")
    }

    enum SaveOutcome: Sendable, Equatable {
        case saved(hash: String, warnings: [String])
        /// The file changed since the panel read it.
        case conflict(hash: String)
        case invalid(ConfigError)
    }

    /// Writes `document` over the file, when the file is still the one
    /// whose hash is `baseHash` (`nil`: whatever it holds now) and the
    /// result loads; then serves it.
    func save(_ document: JSONValue, baseHash: String?) -> SaveOutcome {
        lock.withLock {
            guard let path else {
                return .invalid(ConfigError(message: "the gateway runs without a configuration file; start it with --config to save"))
            }
            do throws(ConfigError) {
                let current = try ConfigDocument.read(try readFile(), file: path)
                if let baseHash, current.hash != baseHash { return .conflict(hash: current.hash) }
                let text = ConfigDocument.header + (try ConfigDocument.text(from: document, secrets: current.secrets))
                let loaded = try ConfigFile.parse(text, file: path, overrides: overrides, environment: environment)
                guard loaded.gateway.adminToken != nil else {
                    throw ConfigError(message: "panel.token is needed: without it the panel would lock itself out")
                }
                try Self.write(text, to: path)
                logger.info("configuration saved from the control panel")
                _ = reloadLocked()
                return .saved(hash: ConfigDocument.hash(text), warnings: loaded.warnings + exposure(loaded.gateway))
            } catch {
                return .invalid(error)
            }
        }
    }

    /// The configuration the file would give with `accounts` (as the
    /// panel edits them) in place of its own; nothing is written.
    func trying(accounts: JSONValue) throws(ConfigError) -> GatewayConfiguration {
        let current = try ConfigDocument.read(try readFile(), file: path ?? "config")
        var document = current.document.objectValue ?? JSONObject()
        document["accounts"] = accounts
        let text = try ConfigDocument.text(from: .object(document), secrets: current.secrets)
        return try ConfigFile.parse(text, file: path ?? "config", overrides: overrides, environment: environment).gateway
    }

    private func readFile() throws(ConfigError) -> String {
        guard let path, FileManager.default.fileExists(atPath: path) else { return "" }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ConfigError(message: "cannot read the configuration file \(path)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Replaces the file in one step (a new file renamed over it, through
    /// a symlink to its target), keeping its permissions; 0600 for a new one.
    static func write(_ text: String, to path: String) throws(ConfigError) {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let permissions = FileManager.default.permissions(atPath: target.path).map { mode_t($0 & 0o777) } ?? 0o600
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(getpid()).saving").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw ConfigError(message: "cannot write \(temporary): \(String(cString: strerror(errno)))")
        }
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { systemWrite(descriptor, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            written += count
        }
        let complete = written == bytes.count && fchmod(descriptor, permissions) == 0 && fsync(descriptor) == 0
        close(descriptor)
        guard complete, rename(temporary, target.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw ConfigError(message: "cannot write \(target.path): \(reason)")
        }
    }
}

// MARK: - Status

enum AdminStatus {
    /// Accounts with their state, what else is cooling down, the menu and
    /// the clients in force, as the panel shows them; no secret is included.
    static func json(gateway: Gateway, path: String?, server: ServerSettings) -> JSONValue {
        let configuration = gateway.configuration
        let health = gateway.health.snapshot()
        func remaining(_ scope: HealthScope) -> JSONValue {
            guard let until = health.cooldowns[scope], until > health.now else { return .null }
            let seconds = (until - health.now).components.seconds + 1
            return .number(JSONNumber(seconds))
        }

        let builtIn = ProviderRegistry.builtIn
        var accounts: [JSONValue] = []
        var cooling: [JSONValue] = []
        for id in configuration.registry.providers.keys.sorted() {
            guard let provider = configuration.registry[id] else { continue }
            if let pool = configuration.keyPools[id] {
                for key in pool.keys {
                    let scope = HealthScope.key(provider: id, keyName: key.name)
                    let state = health.disabled.contains(scope) ? "disabled" : (health.isCooling(scope) ? "cooling" : "ready")
                    var account: JSONObject = [
                        "name": .string(key.name),
                        "provider": .string(id),
                        "source": pool.fromEnvironment ? "environment" : "file",
                        "pool": .string(pool.strategy.rawValue),
                        "state": .string(state),
                        "cooling_seconds": remaining(scope),
                    ]
                    if key.signIn != nil {
                        account["sign_in"] = signInJSON(gateway.signIns.credentials(provider: id, account: key.name))
                    }
                    accounts.append(.object(account))
                }
            }
            // An account that defines its own provider without a key has no
            // key in a pool; the provider bears the account's name. A
            // built-in provider that needs no key, as it is, is no account.
            if configuration.keyPools[id]?.keys.isEmpty ?? true, provider != builtIn[id],
               provider.endpoints.contains(where: { configuration.goesWithoutKey(id, at: $0) })
            {
                accounts.append([
                    "name": .string(id),
                    "provider": .string(id),
                    "source": "file",
                    "pool": .string(KeyPool.Strategy.order.rawValue),
                    "state": "ready",
                    "cooling_seconds": .null,
                ])
            }
            for endpoint in provider.endpoints {
                let scope = HealthScope.endpoint(Candidate.endpointID(provider: id, endpoint))
                guard health.isCooling(scope) else { continue }
                cooling.append([
                    "provider": .string(id),
                    "what": .string("\(endpoint.apiProtocol.rawValue) endpoint unreachable"),
                    "cooling_seconds": remaining(scope),
                ])
            }
            for (scope, _) in health.cooldowns {
                switch scope {
                case .model(let endpoint, let model) where endpoint.hasPrefix(id + " "):
                    cooling.append(["provider": .string(id), "what": .string("\(model) failing"), "cooling_seconds": remaining(scope)])
                case .keyModel(id, let keyName, let model):
                    cooling.append([
                        "provider": .string(id), "what": .string("\(model) rate limited for \(keyName)"), "cooling_seconds": remaining(scope),
                    ])
                default: continue
                }
            }
        }
        /// No token is included.
        func signInJSON(_ credentials: SignInCredentials?) -> JSONValue {
            guard let credentials else { return ["state": "signed out"] }
            return [
                "state": credentials.lapsed == nil ? "signed in" : "lapsed",
                "user": .string(credentials.user),
                "plan": credentials.plan.map(JSONValue.string) ?? .null,
                "problem": credentials.lapsed.map(JSONValue.string) ?? .null,
            ]
        }
        let models: [JSONValue] = configuration.routes.all.map { route in
            ["name": .string(route.name), "targets": .array(route.targets.map { .string($0.model) })]
        }
        let clients: [JSONValue] = configuration.clientKeys.map { key in
            ["name": .string(key.name), "models": key.models.map { .array($0.map(JSONValue.string)) } ?? .null]
        } + configuration.disabledClients.map { name in ["name": .string(name), "disabled": true] }
        // Names asked for that still nothing serves.
        let planner = CandidatePlanner(configuration: configuration)
        let unserved: [JSONValue] = gateway.activity.unserved().filter { (try? planner.plan(for: $0.name)) == nil }.map { entry in
            [
                "name": .string(entry.name),
                "requests": .number(JSONNumber(entry.requests)),
                "programs": .array(entry.programs.map(JSONValue.string)),
                "clients": .array(entry.clients.map(JSONValue.string)),
                "last": .number(JSONNumber(entry.last)),
            ]
        }
        return [
            "unserved": .array(unserved),
            "config_path": path.map(JSONValue.string) ?? .null,
            "listen": .string("\(server.host):\(server.port)"),
            "accounts": .array(accounts),
            "cooling": .array(cooling),
            "models": .array(models),
            "clients": .array(clients),
            "presets": .array(ProviderRegistry.builtIn.providers.keys.sorted().map(JSONValue.string)),
            "keyless_presets": .array(
                ProviderRegistry.builtIn.providers.values.filter(\.servesWithoutKey).map(\.id).sorted().map(JSONValue.string),
            ),
            "providers": .array(configuration.registry.providers.keys.sorted().map(JSONValue.string)),
        ]
    }
}

// MARK: - What a name resolves to

enum AdminResolve {
    /// What `model` leads to for a client: the route that takes it and
    /// why, then each model tried, in order, with its accounts and how
    /// they are doing; or why it is refused. `client`: one of `clients`
    /// by name; `nil`: a client that may ask for anything.
    static func json(model: String, client: String?, gateway: Gateway) -> JSONValue {
        let configuration = gateway.configuration
        var access = ClientAccess.open
        if let client {
            guard let key = configuration.clientKeys.first(where: { $0.name == client }) else {
                return ["status": 403, "message": .string("client `\(client)` is not in force")]
            }
            access = .key(key)
        }
        let planner = CandidatePlanner(configuration: configuration)
        let plan: CandidatePlanner.Plan
        do {
            plan = try planner.plan(for: model, access: access)
        } catch {
            return ["status": .number(JSONNumber(error.status)), "message": .string(error.message)]
        }
        let via = switch plan.route {
        case nil: "direct"
        case "*"?: "rest"
        case let name?: name.contains("*") ? "pattern" : "exact"
        }
        let health = gateway.health.snapshot()
        let targets: [JSONValue] = plan.references.map { reference in
            var target: JSONObject = ["model": .string(reference)]
            do throws(PlanningError) {
                let candidates = try planner.candidates(
                    for: CandidatePlanner.Plan(references: [reference]), clientModel: model, clientProtocol: .chatCompletions,
                )
                target["accounts"] = .array(candidates.map { candidate in
                    let state = health.isDisabled(candidate) ? "disabled" : health.isCooling(candidate) ? "cooling" : "ready"
                    return ["name": .string(candidate.keyName), "state": .string(state)]
                })
            } catch {
                target["problem"] = .string(error.detail ?? error.message)
            }
            return .object(target)
        }
        return [
            "status": 200,
            "via": .string(via),
            "route": plan.route.map(JSONValue.string) ?? .null,
            "targets": .array(targets),
        ]
    }
}

// MARK: - Activity and usage

enum AdminActivity {
    static func json(_ activity: Activity) -> JSONValue {
        let snapshot = activity.snapshot()
        return [
            "now": .number(JSONNumber(LocalDay.nowMilliseconds())),
            "in_flight": .array(snapshot.inFlight.map(json)),
            "recent": .array(snapshot.recent.map(json)),
            "sessions": .array(snapshot.sessions.map(json)),
        ]
    }

    static func json(_ record: RequestRecord) -> JSONValue {
        var object = record.logged.objectValue ?? JSONObject()
        object["id"] = .number(JSONNumber(record.id))
        object["phase"] = .string(record.phase.rawValue)
        object["attempt_list"] = .array(record.attempts.map { attempt in
            [
                "provider": .string(attempt.provider), "account": .string(attempt.account), "model": .string(attempt.model),
                "outcome": .string(attempt.outcome), "ms": .number(JSONNumber(attempt.milliseconds)),
            ]
        })
        if !record.targets.isEmpty { object["targets"] = .array(record.targets.map(JSONValue.string)) }
        if let kept = record.kept {
            var value: JSONObject = [
                "reference": .string(kept.reference), "context": .number(JSONNumber(kept.context)),
                "limit": .number(JSONNumber(kept.limit)),
            ]
            if let reported = kept.reported { value["reported"] = .number(JSONNumber(reported)) }
            if kept.storedReply { value["stored_reply"] = true }
            object["kept"] = .object(value)
        }
        if !record.passedOver.isEmpty {
            object["passed_over"] = .array(record.passedOver.map { passed in
                var value: JSONObject = [
                    "reference": .string(passed.reference), "account": .string(passed.account), "why": .string(passed.why),
                ]
                if let seconds = passed.seconds { value["seconds"] = .number(JSONNumber(seconds)) }
                if let last = passed.last { value["last"] = .string(last) }
                return .object(value)
            })
        }
        if record.heldHeaders { object["held_headers"] = true }
        if !record.changes.isEmpty {
            object["changes"] = .array(record.changes.map { change in
                [
                    "code": .string(change.code), "path": .string(change.path), "side": .string(change.side),
                    "count": .number(JSONNumber(change.count)), "message": .string(change.message),
                ]
            })
        }
        return .object(object)
    }

    static func json(_ session: SessionSummary) -> JSONValue {
        [
            "id": .string(session.id),
            "program": .string(session.program),
            "client": session.client.map(JSONValue.string) ?? .null,
            "first": .number(JSONNumber(session.first)),
            "last": .number(JSONNumber(session.last)),
            "requests": .number(JSONNumber(session.requests)),
            "failures": .number(JSONNumber(session.failures)),
            "tokens": session.tokens.json,
            "accounts": .array(session.accounts.map(JSONValue.string)),
            "switches": .number(JSONNumber(session.switches)),
            "models": .array(session.models.map(JSONValue.string)),
            "last_model": .string(session.lastModel),
        ]
    }

    /// A session: its summary, its turns, where each of its conversations
    /// was last answered, and its requests still kept in memory.
    static func session(_ id: String, gateway: Gateway) -> JSONValue {
        var object: JSONObject = [
            "requests": .array(gateway.activity.requests(ofSession: id).map(json)),
        ]
        if let session = gateway.activity.session(id) {
            object["session"] = json(session)
            object["turns"] = .array(session.turns.map { turn in
                var value: JSONObject = ["t": .number(JSONNumber(turn.t)), "model": .string(turn.model)]
                if let subagent = turn.subagent { value["subagent"] = .string(subagent) }
                if let served = turn.served { value["served"] = .string(served) }
                if let account = turn.account { value["account"] = .string(account) }
                if let target = turn.target { value["target"] = .number(JSONNumber(target)) }
                if let tokens = turn.tokens { value["tokens"] = tokens.json }
                if turn.failed { value["failed"] = true }
                if turn.kept { value["kept"] = true }
                return .object(value)
            })
        }
        let now = ContinuousClock.now
        let wall = LocalDay.nowMilliseconds()
        func milliseconds(_ duration: Duration) -> Int64 {
            duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        }
        object["placements"] = .array(gateway.placements.placements(ofSession: id).map { subagent, model, placement in
            let at = wall - milliseconds(now - placement.at)
            var value: JSONObject = [
                "model": .string(model), "reference": .string(placement.reference),
                "at": .number(JSONNumber(at)), "cache_until": .number(JSONNumber(at + milliseconds(placement.lifetime))),
            ]
            if let subagent { value["subagent"] = .string(subagent) }
            if let input = placement.reportedInput { value["reported_input"] = .number(JSONNumber(input)) }
            return .object(value)
        })
        return .object(object)
    }

    /// Usage summed by account, client, program, model and route, and in
    /// all; and each grouping's tokens and requests over time: by hour for
    /// one day, else by day.
    static func usage(
        _ buckets: [UsageBucket.Key: UsageBucket], days: Int, now: Int64 = LocalDay.nowMilliseconds(),
    ) -> JSONValue {
        let groupings: [(String, (UsageBucket.Key) -> String)] = [
            ("accounts", { $0.provider.isEmpty ? "(none)" : $0.provider + "/" + ($0.account.isEmpty ? "-" : $0.account) }),
            ("clients", { $0.client.isEmpty ? "(no key)" : $0.client }),
            ("programs", \.program),
            ("models", \.model),
            ("routes", { $0.route.isEmpty ? "(none)" : $0.route }),
        ]
        // The time slots: hours of the day, or days oldest first.
        let slots: [Int] = days == 1
            ? Array(0..<24)
            : (0..<days).reversed().map { LocalDay(milliseconds: now - Int64($0) * 86_400_000).key }
        let slotIndex = Dictionary(slots.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
        func slot(_ key: UsageBucket.Key) -> Int? { slotIndex[days == 1 ? key.hour : key.day] }

        func sum(_ bucket: UsageBucket, into total: inout UsageBucket) {
            total.requests += bucket.requests
            total.failures += bucket.failures
            total.tokens += bucket.tokens
        }
        func row(_ name: String, _ sum: UsageBucket) -> JSONObject {
            ["name": .string(name), "requests": .number(JSONNumber(sum.requests)), "failures": .number(JSONNumber(sum.failures)),
             "tokens": sum.tokens.json]
        }
        func ordered(_ sums: [String: UsageBucket]) -> [(key: String, value: UsageBucket)] {
            sums.sorted { a, b in
                let (ta, tb) = (a.value.tokens.input + a.value.tokens.output, b.value.tokens.input + b.value.tokens.output)
                return ta != tb ? ta > tb : a.key < b.key
            }
        }

        var object: JSONObject = ["days": .number(JSONNumber(days))]
        var trend: JSONObject = ["slots": .array(slots.map { .number(JSONNumber($0)) })]
        for (grouping, name) in groupings {
            var sums: [String: UsageBucket] = [:]
            var series: [String: (tokens: [Int], requests: [Int])] = [:]
            for (key, bucket) in buckets {
                sum(bucket, into: &sums[name(key), default: UsageBucket()])
                guard let at = slot(key) else { continue }
                var line = series[name(key)] ?? (Array(repeating: 0, count: slots.count), Array(repeating: 0, count: slots.count))
                line.tokens[at] += bucket.tokens.input + bucket.tokens.output
                line.requests[at] += bucket.requests
                series[name(key)] = line
            }
            let rows = ordered(sums)
            object[grouping] = .array(rows.map { name, sum in
                var value = row(name, sum)
                if grouping == "routes" { for (key, detail) in routeDetail(name, buckets: buckets) { value[key] = detail } }
                return .object(value)
            })
            trend[grouping] = .array(rows.compactMap { name, _ in
                series[name].map { line in
                    ["name": .string(name), "tokens": .array(line.tokens.map { .number(JSONNumber($0)) }),
                     "requests": .array(line.requests.map { .number(JSONNumber($0)) })]
                }
            })
        }
        var total = UsageBucket()
        for bucket in buckets.values { sum(bucket, into: &total) }
        var totalRow = row("", total)
        totalRow["name"] = nil
        object["total"] = .object(totalRow)
        object["trend"] = .object(trend)
        return .object(object)
    }

    /// A route's targets, by their place, and how many requests fell back.
    private static func routeDetail(_ route: String, buckets: [UsageBucket.Key: UsageBucket]) -> JSONObject {
        let routeName = route == "(none)" ? "" : route
        // By place and model: a place may have held another model before
        // the route was changed.
        struct Place: Hashable { var position: Int; var model: String }
        var targets: [Place: UsageBucket] = [:]
        var fallbacks = 0
        var unknown = 0
        for (key, bucket) in buckets where key.route == routeName {
            if key.target > 1 { fallbacks += bucket.requests }
            if key.target == 0 { unknown += bucket.requests; continue }
            var sum = targets[Place(position: key.target, model: key.model)] ?? UsageBucket()
            sum.requests += bucket.requests
            sum.failures += bucket.failures
            sum.tokens += bucket.tokens
            targets[Place(position: key.target, model: key.model)] = sum
        }
        return [
            "fallbacks": .number(JSONNumber(fallbacks)),
            "unplaced": .number(JSONNumber(unknown)),
            "targets": .array(targets.sorted {
                $0.key.position != $1.key.position ? $0.key.position < $1.key.position : $0.value.requests > $1.value.requests
            }.map { place, sum in
                ["position": .number(JSONNumber(place.position)), "model": .string(place.model),
                 "requests": .number(JSONNumber(sum.requests)), "failures": .number(JSONNumber(sum.failures)),
                 "tokens": sum.tokens.json]
            }),
        ]
    }
}

// MARK: - Routes

/// `/` (sent on to `/admin`), `/admin` (the panel) and `/admin/api/*`,
/// open only with `panel.token` set; otherwise `/admin` says how to turn
/// the panel on, and the API answers 404.
func addAdminRoutes(to router: Router<GatewayRequestContext>, manager: ConfigManager) {
    let gateway = manager.gateway

    router.get("/") { _, _ in
        Response(status: .found, headers: [.location: "/admin", .cacheControl: "no-store"])
    }

    @Sendable func page(_ request: Request) -> Response {
        guard gateway.configuration.adminToken != nil else {
            let file = manager.path ?? "the configuration file (--config, or $XDG_CONFIG_HOME/unladen/config.jsonc)"
            let text = "The control panel is off. Set panel.token (16 characters or more) in \(file), then reload the gateway (SIGHUP) or restart it.\n"
            return Response(
                status: .notFound, headers: [.contentType: "text/plain; charset=utf-8", .cacheControl: "no-store"],
                body: ResponseBody(byteBuffer: ByteBuffer(string: text)),
            )
        }
        var headers: HTTPFields = [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"]
        headers[HTTPField.Name("x-frame-options")!] = "DENY"
        headers[HTTPField.Name("referrer-policy")!] = "no-referrer"
        headers[HTTPField.Name("content-security-policy")!] = AdminPage.contentSecurityPolicy
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: AdminPage.html)))
    }
    router.get("/admin") { request, _ in page(request) }

    router.get("/admin/api/status") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        return adminJSON(200, AdminStatus.json(gateway: gateway, path: manager.path, server: manager.server))
    }

    router.get("/admin/api/config") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        do throws(ConfigError) {
            let snapshot = try manager.document()
            return adminJSON(200, [
                "path": manager.path.map(JSONValue.string) ?? .null,
                "hash": .string(snapshot.hash),
                "document": snapshot.document,
            ])
        } catch {
            return adminError(500, error.description)
        }
    }

    router.put("/admin/api/config") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        var request = request
        let body: ByteBuffer
        do {
            body = try await request.collectBody(upTo: 4 << 20)
        } catch is NIOTooManyBytesError {
            return adminError(413, "the configuration is larger than 4 MiB")
        }
        // `overwrite` writes over whatever the file holds now: the panel's
        // answer to a conflict.
        let json = try? JSONValue(parsing: Array(body.readableBytesView))
        let overwrite = json?["overwrite"]?.boolValue == true
        let hash = json?["hash"]?.stringValue
        guard let document = json?["document"], document.objectValue != nil, overwrite || hash != nil else {
            return adminError(400, "expected {\"document\": {…}, \"hash\": \"…\"} or {\"document\": {…}, \"overwrite\": true}")
        }
        switch manager.save(document, baseHash: overwrite ? nil : hash) {
        case .saved(let hash, let warnings):
            return adminJSON(200, ["hash": .string(hash), "warnings": .array(warnings.map(JSONValue.string))])
        case .conflict(let hash):
            return adminJSON(409, ["error": "the file changed since it was loaded", "hash": .string(hash)])
        case .invalid(let error):
            return adminJSON(422, ["error": .string(error.message), "location": error.location.map(JSONValue.string) ?? .null])
        }
    }

    router.get("/admin/api/activity") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        return adminJSON(200, AdminActivity.json(gateway.activity))
    }

    router.get("/admin/api/sessions/:id") { request, context in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        let id = context.parameters.get("id") ?? ""
        return adminJSON(200, AdminActivity.session(id, gateway: gateway))
    }

    router.get("/admin/api/usage") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        let days = request.uri.queryParameters.get("days").flatMap { Int($0) }.map { min(max($0, 1), Activity.usageDays) } ?? 1
        return adminJSON(200, AdminActivity.usage(gateway.activity.usage(days: days), days: days))
    }

    /// Accounts' plan allowances; `?refresh=1` reads them again.
    router.get("/admin/api/quotas") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        let refresh = request.uri.queryParameters.get("refresh") == "1"
        let quotas = await gateway.quotas.read(gateway: gateway, refresh: refresh)
        return adminJSON(200, ["accounts": .array(quotas.map(\.json))])
    }

    /// The models a provider lists, for the panel to offer:
    /// `{"provider": …}`, with the accounts in force, or with
    /// `"accounts": {…}` in place of them, such as one being added. Kept
    /// by ``ModelCatalog``, so asking again does not ask the provider.
    router.post("/admin/api/models") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        var request = request
        let body = try? await request.collectBody(upTo: 1 << 20)
        let json = body.flatMap { try? JSONValue(parsing: Array($0.readableBytesView)) }
        guard let provider = json?["provider"]?.stringValue, !provider.isEmpty else {
            return adminError(400, "expected {\"provider\": \"…\"}, and optionally \"accounts\": {…}")
        }
        var configuration = gateway.configuration
        if let accounts = json?["accounts"] {
            do throws(ConfigError) {
                configuration = try manager.trying(accounts: accounts)
            } catch {
                return adminError(422, error.message)
            }
        }
        let names = await gateway.models.names(of: provider, gateway: gateway, configuration: configuration)
        return adminJSON(200, ["models": .array(names.map(JSONValue.string))])
    }

    /// What a model name leads to: `{"model": …}`, and optionally
    /// `"client": …` to ask as one of the clients.
    router.post("/admin/api/resolve") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        var request = request
        let body = try? await request.collectBody(upTo: 1 << 20)
        let json = body.flatMap { try? JSONValue(parsing: Array($0.readableBytesView)) }
        guard let model = json?["model"]?.stringValue?.trimmingBlanks(), !model.isEmpty else {
            return adminError(400, "expected {\"model\": \"…\"}, and optionally \"client\": \"…\"")
        }
        return adminJSON(200, AdminResolve.json(model: model, client: json?["client"]?.stringValue, gateway: gateway))
    }

    /// Drops a name from those asked for that nothing serves: `{"name": …}`.
    router.post("/admin/api/unserved/forget") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        var request = request
        let body = try? await request.collectBody(upTo: 1 << 20)
        let json = body.flatMap { try? JSONValue(parsing: Array($0.readableBytesView)) }
        guard let name = json?["name"]?.stringValue else { return adminError(400, "expected {\"name\": \"…\"}") }
        gateway.activity.forgetUnserved(name)
        return adminJSON(200, ["forgotten": true])
    }

    router.post("/admin/api/reload") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        return manager.reload() ? adminJSON(200, ["reloaded": true]) : adminError(422, "the file does not load; see the log")
    }

    /// Clears what is recorded against one key: its cooldowns (its own and
    /// its models'), its 401 count, and its being disabled.
    router.post("/admin/api/keys/reset") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        var request = request
        guard let body = try? await request.collectBody(upTo: 64 << 10),
              let json = try? JSONValue(parsing: Array(body.readableBytesView)),
              let provider = json["provider"]?.stringValue, let key = json["key"]?.stringValue
        else { return adminError(400, "expected {\"provider\": \"…\", \"key\": \"…\"}") }
        gateway.health.forget { $0.concerns(provider: provider, keyName: key) }
        return adminJSON(200, ["reset": true])
    }

    addSignInRoutes(to: router, gateway: gateway)
}

/// Signing accounts in (``SignIns``): start gives the address to open,
/// finish takes the address the browser ended on.
private func addSignInRoutes(to router: Router<GatewayRequestContext>, gateway: Gateway) {
    @Sendable func body(_ request: Request) async -> JSONValue? {
        var request = request
        guard let body = try? await request.collectBody(upTo: 64 << 10) else { return nil }
        return try? JSONValue(parsing: Array(body.readableBytesView))
    }
    /// The account named in `json`, of a provider whose accounts sign
    /// in. It need not be in the configuration yet: the panel signs an
    /// account in while adding it, before it is saved.
    @Sendable func account(_ json: JSONValue?) -> (provider: String, account: String)? {
        guard let provider = json?["provider"]?.stringValue, let account = json?["account"]?.stringValue,
              SignInKind.of(provider: provider) != nil,
              !account.isEmpty, !account.hasPrefix("@"), !account.contains("/"), !account.contains("*")
        else { return nil }
        return (provider, account)
    }

    router.post("/admin/api/sign-in/start") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        guard let (provider, name) = account(await body(request)) else {
            return adminError(400, "expected {\"provider\": \"…\", \"account\": \"…\"} naming an account of a provider that signs in")
        }
        do throws(SignInError) {
            let started = try gateway.signIns.start(provider: provider, account: name)
            return adminJSON(200, ["id": .string(started.id), "url": .string(started.url), "redirect": .string(started.redirect)])
        } catch {
            return adminError(422, error.message)
        }
    }

    router.post("/admin/api/sign-in/finish") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        let json = await body(request)
        guard let id = json?["id"]?.stringValue, let callback = json?["callback"]?.stringValue else {
            return adminError(400, "expected {\"id\": \"…\", \"callback\": \"…\"}")
        }
        do throws(SignInError) {
            let (provider, name, credentials) = try await gateway.signIns.finish(id: id, callback: callback, transport: gateway.transport)
            gateway.health.forget { $0.concerns(provider: provider, keyName: name) }
            return adminJSON(200, ["user": .string(credentials.user), "plan": credentials.plan.map(JSONValue.string) ?? .null])
        } catch {
            return adminError(422, error.message)
        }
    }

    router.post("/admin/api/sign-in/forget") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        guard let (provider, name) = account(await body(request)) else {
            return adminError(400, "expected {\"provider\": \"…\", \"account\": \"…\"} naming an account that signs in")
        }
        do throws(SignInError) {
            try gateway.signIns.forget(provider: provider, account: name)
            return adminJSON(200, ["forgotten": true])
        } catch {
            return adminError(422, error.message)
        }
    }
}

/// `nil` when the request carries the admin token.
private func adminDenied(_ request: Request, gateway: Gateway) -> Response? {
    guard let token = gateway.configuration.adminToken else { return adminError(404, "not found") }
    var presented: String?
    if let authorization = request.headers[.authorization] {
        let parts = authorization.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[0].lowercased() == "bearer" { presented = parts[1].trimmingBlanks() }
    }
    guard let presented, constantTimeEqual(presented, token) else { return adminError(401, "invalid or missing admin token") }
    return nil
}

private func adminJSON(_ status: Int, _ json: JSONValue) -> Response {
    Response(
        status: HTTPResponse.Status(code: status),
        headers: [.contentType: "application/json", .cacheControl: "no-store"],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: json.encoded())),
    )
}

private func adminError(_ status: Int, _ message: String) -> Response {
    adminJSON(status, ["error": .string(message)])
}
