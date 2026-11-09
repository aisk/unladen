// The control panel's backend: the configuration file read and saved as a
// document, reloads (the panel's and SIGHUP's), and the status of accounts.
// See docs/server-config-design.md ("控制面板").

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
    /// whose hash is `baseHash` and the result loads; then serves it.
    func save(_ document: JSONValue, baseHash: String) -> SaveOutcome {
        lock.withLock {
            guard let path else {
                return .invalid(ConfigError(message: "the gateway runs without a configuration file; start it with --config to save"))
            }
            do throws(ConfigError) {
                let current = try ConfigDocument.read(try readFile(), file: path)
                guard current.hash == baseHash else { return .conflict(hash: current.hash) }
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
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let permissions = (attributes?[.posixPermissions] as? Int).map { mode_t($0 & 0o777) } ?? 0o600
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
    static func json(gateway: Gateway, path: String?) -> JSONValue {
        let configuration = gateway.configuration
        let health = gateway.health.snapshot()
        func remaining(_ scope: HealthScope) -> JSONValue {
            guard let until = health.cooldowns[scope], until > health.now else { return .null }
            let seconds = (until - health.now).components.seconds + 1
            return .number(JSONNumber(seconds))
        }

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
            for endpoint in provider.endpoints {
                let scope = HealthScope.endpoint("\(id) \(endpoint.apiProtocol.rawValue) \(endpoint.baseURL)")
                guard health.isCooling(scope) else { continue }
                cooling.append([
                    "provider": .string(id),
                    "what": .string("\(endpoint.apiProtocol.rawValue) endpoint unreachable"),
                    "cooling_seconds": remaining(scope),
                ])
            }
            for (scope, _) in health.cooldowns {
                guard case .model(let endpoint, let model) = scope, endpoint.hasPrefix(id + " ") else { continue }
                cooling.append(["provider": .string(id), "what": .string("\(model) failing"), "cooling_seconds": remaining(scope)])
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
        return [
            "config_path": path.map(JSONValue.string) ?? .null,
            "accounts": .array(accounts),
            "cooling": .array(cooling),
            "models": .array(models),
            "clients": .array(clients),
            "presets": .array(ProviderRegistry.builtIn.providers.keys.sorted().map(JSONValue.string)),
            "providers": .array(configuration.registry.providers.keys.sorted().map(JSONValue.string)),
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

    /// Usage summed by account, client, program and model, and in all.
    static func usage(_ buckets: [UsageBucket.Key: UsageBucket], days: Int) -> JSONValue {
        func group(_ key: (UsageBucket.Key) -> String) -> JSONValue {
            var sums: [String: UsageBucket] = [:]
            for (bucketKey, bucket) in buckets {
                var sum = sums[key(bucketKey)] ?? UsageBucket()
                sum.requests += bucket.requests
                sum.failures += bucket.failures
                sum.tokens += bucket.tokens
                sums[key(bucketKey)] = sum
            }
            let rows = sums.sorted { a, b in
                let (ta, tb) = (a.value.tokens.input + a.value.tokens.output, b.value.tokens.input + b.value.tokens.output)
                return ta != tb ? ta > tb : a.key < b.key
            }
            return .array(rows.map { name, sum in
                ["name": .string(name), "requests": .number(JSONNumber(sum.requests)), "failures": .number(JSONNumber(sum.failures)),
                 "tokens": sum.tokens.json]
            })
        }
        var total = UsageBucket()
        for bucket in buckets.values {
            total.requests += bucket.requests
            total.failures += bucket.failures
            total.tokens += bucket.tokens
        }
        return [
            "days": .number(JSONNumber(days)),
            "total": ["requests": .number(JSONNumber(total.requests)), "failures": .number(JSONNumber(total.failures)), "tokens": total.tokens.json],
            "accounts": group { $0.provider.isEmpty ? "(none)" : $0.provider + "/" + ($0.account.isEmpty ? "-" : $0.account) },
            "clients": group { $0.client.isEmpty ? "(no key)" : $0.client },
            "programs": group(\.program),
            "models": group(\.model),
        ]
    }
}

// MARK: - Routes

/// `/admin` (the panel) and `/admin/api/*`, open only with
/// `panel.token` set; 404 otherwise, as though they did not exist.
func addAdminRoutes(to router: Router<GatewayRequestContext>, manager: ConfigManager) {
    let gateway = manager.gateway

    @Sendable func page(_ request: Request) -> Response {
        guard gateway.configuration.adminToken != nil else { return adminError(404, "not found") }
        var headers: HTTPFields = [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"]
        headers[HTTPField.Name("x-frame-options")!] = "DENY"
        headers[HTTPField.Name("referrer-policy")!] = "no-referrer"
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(string: AdminPage.html)))
    }
    router.get("/admin") { request, _ in page(request) }

    router.get("/admin/api/status") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        return adminJSON(200, AdminStatus.json(gateway: gateway, path: manager.path))
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
        guard let body = try? await request.collectBody(upTo: 4 << 20),
              let json = try? JSONValue(parsing: Array(body.readableBytesView)),
              let document = json["document"], document.objectValue != nil,
              let hash = json["hash"]?.stringValue
        else { return adminError(400, "expected {\"document\": {…}, \"hash\": \"…\"}") }
        switch manager.save(document, baseHash: hash) {
        case .saved(let hash, let warnings):
            return adminJSON(200, ["hash": .string(hash), "warnings": .array(warnings.map(JSONValue.string))])
        case .conflict(let hash):
            return adminJSON(409, ["error": "the file changed since it was loaded; reload it and redo the change", "hash": .string(hash)])
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
        return adminJSON(200, ["requests": .array(gateway.activity.requests(ofSession: id).map(AdminActivity.json))])
    }

    router.get("/admin/api/usage") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        let days = request.uri.queryParameters.get("days").flatMap { Int($0) }.map { min(max($0, 1), Activity.usageDays) } ?? 1
        return adminJSON(200, AdminActivity.usage(gateway.activity.usage(days: days), days: days))
    }

    router.post("/admin/api/reload") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        return manager.reload() ? adminJSON(200, ["reloaded": true]) : adminError(422, "the file does not load; see the log")
    }

    /// Clears what is recorded against one key: its cooldown, its 401
    /// count, and its being disabled.
    router.post("/admin/api/keys/reset") { request, _ in
        if let denied = adminDenied(request, gateway: gateway) { return denied }
        var request = request
        guard let body = try? await request.collectBody(upTo: 64 << 10),
              let json = try? JSONValue(parsing: Array(body.readableBytesView)),
              let provider = json["provider"]?.stringValue, let key = json["key"]?.stringValue
        else { return adminError(400, "expected {\"provider\": \"…\", \"key\": \"…\"}") }
        let scope = HealthScope.key(provider: provider, keyName: key)
        gateway.health.forget { $0 == scope }
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
            return adminJSON(200, ["id": .string(started.id), "url": .string(started.url)])
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
            let scope = HealthScope.key(provider: provider, keyName: name)
            gateway.health.forget { $0 == scope }
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
