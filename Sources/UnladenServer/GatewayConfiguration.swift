// What one gateway instance serves: upstream providers and their key pools,
// routes from client model names to upstream models, and the keys clients
// present. Built from the configuration file (ConfigFile.swift), command
// line flags and environment variables; see docs/server-config-design.md.

import NIOConcurrencyHelpers
@_spi(Wire) import UnladenCore

/// The configuration in force, replaced whole on a reload.
final class ConfigurationStore: Sendable {
    private let box: NIOLockedValueBox<GatewayConfiguration>

    init(_ configuration: GatewayConfiguration) {
        box = NIOLockedValueBox(configuration)
    }

    var current: GatewayConfiguration { box.withLockedValue { $0 } }

    /// Installs `configuration`; returns the one it replaces.
    @discardableResult
    func replace(_ configuration: GatewayConfiguration) -> GatewayConfiguration {
        box.withLockedValue { current in
            let old = current
            current = configuration
            return old
        }
    }
}

/// Settings of one gateway instance, validated. Immutable once built.
struct GatewayConfiguration: Sendable {
    /// Skip candidates the request cannot be carried to exactly (lossy
    /// warnings; kept unknown fields, `adjusted` rewrites, parameters the
    /// model's Profile declares unsupported and cache hints do not count:
    /// ``WireWarning/isEscalatedWhenStrict``), and answer 400 when no
    /// candidate is left, instead of forwarding with an
    /// `x-unladen-warnings` header.
    var strict = false
    /// How long a streaming client may go without an event before it is
    /// sent a keepalive.
    var keepaliveInterval: Duration = .seconds(15)
    /// Largest request body accepted.
    var maxRequestBytes = 64 << 20
    /// How long one upstream may take to its first content (a complete
    /// reply, when the client does not stream) before the next key is
    /// tried; `nil`: no limit.
    var headTimeout: Duration? = .seconds(300)
    /// How long a stream may go without an upstream event, once it is
    /// being forwarded, before it is ended with an error; `nil`: no limit.
    var idleTimeout: Duration? = .seconds(300)
    var registry = ProviderRegistry.builtIn
    /// Upstream keys by provider id.
    var keyPools: [String: KeyPool] = [:]
    var routes = RouteTable()
    /// Keys clients must present; none: clients are not authenticated.
    var clientKeys: [ClientKey] = []
}

// MARK: - Key pools

/// One upstream API key.
struct UpstreamKey: Sendable, Hashable {
    /// Stable identity: health is recorded under it, so reordering keys
    /// does not move it to another key. A hash of the key when unnamed.
    var name: String
    var secret: String

    init(name: String? = nil, secret: String) {
        self.name = name ?? Self.fingerprint(secret)
        self.secret = secret
    }

    /// `key-` and 8 hex digits of the key's FNV-1a hash: names an unnamed
    /// key in logs without showing it.
    static func fingerprint(_ secret: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in secret.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash >> 32, radix: 16)
        return "key-" + String(repeating: "0", count: 8 - hex.count) + hex
    }
}

/// A provider's keys, all equivalent: the next is used when one fails.
struct KeyPool: Sendable, Hashable {
    enum Strategy: String, Sendable, Hashable {
        /// In order; the next only when the one before fails or cools.
        /// Keeps a conversation on one account, so prompt caches hold.
        case order
        /// Each request starts at the next key.
        case rotate
    }

    var keys: [UpstreamKey]
    var strategy: Strategy = .order
}

/// Where upstream API keys come from when the configuration file gives a
/// provider none: one environment variable per provider, a comma-separated
/// list for several keys.
///
/// `UNLADEN_<PROVIDER>_API_KEY` (provider id upper-cased, other characters
/// than letters and digits as `_`) is read first; then the provider's
/// customary variable from its preset (`Provider.apiKeyEnvironmentVariables`).
enum UpstreamKeys {
    static func gatewayVariable(for provider: String) -> String {
        let name = provider.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
        return "UNLADEN_\(name)_API_KEY"
    }

    /// The variables read for `provider`, in order.
    static func variables(for provider: String, in registry: ProviderRegistry) -> [String] {
        [gatewayVariable(for: provider)] + (registry.providers[provider]?.apiKeyEnvironmentVariables ?? [])
    }

    /// Keys for `provider` found in `environment`.
    static func load(for provider: String, in registry: ProviderRegistry, environment: (String) -> String?) -> [UpstreamKey] {
        for variable in variables(for: provider, in: registry) {
            guard let value = environment(variable) else { continue }
            let list = split(value)
            if !list.isEmpty { return list.map { UpstreamKey(secret: $0) } }
        }
        return []
    }

    /// Splits a comma-separated list, trimming blanks and dropping
    /// duplicates.
    static func split(_ value: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for part in value.split(separator: ",") {
            let key = part.trimmingBlanks()
            if !key.isEmpty, seen.insert(key).inserted { result.append(key) }
        }
        return result
    }
}

// MARK: - Routes

/// One upstream model of a route.
struct RouteTarget: Sendable, Hashable {
    /// `provider/model`; `$model` stands for the client's model name.
    var model: String

    /// The reference for a client model name.
    func reference(for clientModel: String) -> String {
        model.replacing("$model", with: clientModel)
    }
}

/// A client model name (or glob of names) and the upstream models that
/// serve it, in order. The first version has one target per route; the
/// candidate planner already walks a list.
struct Route: Sendable, Hashable {
    var name: String
    var targets: [RouteTarget]

    var isPattern: Bool { name.contains("*") }
}

/// The routes, indexed for resolution: exact names, then patterns (most
/// specific first), then `*`.
struct RouteTable: Sendable, Hashable {
    private(set) var exact: [String: Route] = [:]
    private(set) var patterns: [Route] = []
    private(set) var catchAll: Route?

    init(_ routes: [Route] = []) {
        for route in routes { add(route) }
    }

    /// Adds `route`, replacing one of the same name.
    mutating func add(_ route: Route) {
        if route.name == "*" {
            catchAll = route
        } else if route.isPattern {
            patterns.removeAll { $0.name.lowercased() == route.name.lowercased() }
            patterns.append(route)
            // More literal characters is more specific; ties by name, so
            // the order does not depend on the file's.
            patterns.sort { a, b in
                let (la, lb) = (a.name.count { $0 != "*" }, b.name.count { $0 != "*" })
                return la != lb ? la > lb : a.name < b.name
            }
        } else {
            exact[route.name.lowercased()] = route
        }
    }

    var all: [Route] {
        exact.values.sorted { $0.name < $1.name } + patterns + (catchAll.map { [$0] } ?? [])
    }

    var isEmpty: Bool { exact.isEmpty && patterns.isEmpty && catchAll == nil }

    /// The route an exact name or a pattern gives `model` (not `*`).
    func named(_ model: String) -> Route? {
        let key = model.lowercased()
        if let route = exact[key] { return route }
        return patterns.first { Glob.matches($0.name, key) }
    }
}

/// `*`-only globs, case-insensitive.
enum Glob {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var (pi, ti) = (0, 0)
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

// MARK: - Client keys

/// A key a client presents, and what it may use.
struct ClientKey: Sendable, Hashable {
    var name: String
    var secret: String
    /// Globs over route names; `nil`: every route.
    var routes: [String]?
    /// Globs over `provider/model` references a client may name directly.
    var passthrough: [String] = []

    func mayUse(_ route: Route) -> Bool {
        routes.map { globs in globs.contains { Glob.matches($0, route.name) } } ?? true
    }

    func mayPassThrough(_ reference: String) -> Bool {
        passthrough.contains { Glob.matches($0, reference) }
    }
}

/// Who a request comes from.
enum ClientAccess: Sendable, Hashable {
    /// No client keys are configured.
    case open
    case key(ClientKey)

    func mayUse(_ route: Route) -> Bool {
        switch self {
        case .open: true
        case .key(let key): key.mayUse(route)
        }
    }

    func mayPassThrough(_ reference: String) -> Bool {
        switch self {
        case .open: true
        case .key(let key): key.mayPassThrough(reference)
        }
    }
}

extension StringProtocol {
    /// Without leading and trailing spaces, tabs and line breaks.
    func trimmingBlanks() -> String {
        let characters: Set<Character> = [" ", "\t", "\r", "\n", "\r\n"]
        var slice = Substring(self)
        while let first = slice.first, characters.contains(first) { slice.removeFirst() }
        while let last = slice.last, characters.contains(last) { slice.removeLast() }
        return String(slice)
    }
}
