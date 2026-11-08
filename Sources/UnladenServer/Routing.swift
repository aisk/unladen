// Candidates, routing strategy and health.
//
// A request is routed to an ordered candidate list (model × key); the
// fallback loop only tries candidates in that order. A `RoutingStrategy`
// orders them from the request context and each candidate's health. The
// first version routes each name to one model; its provider's key pool
// supplies the candidates (docs/server-config-design.md).

import NIOConcurrencyHelpers
@_spi(Wire) import UnladenCore

/// One way to serve a request: a resolved model and the key to call it with.
struct Candidate: Sendable, Hashable {
    /// The model reference, `provider/model`.
    var reference: String
    var target: ResolvedModel
    /// `nil` for endpoints without authentication.
    var apiKey: String?
    /// The key's stable name (``UpstreamKey/name``); `""` without a key.
    var keyName: String
    /// How the provider's keys take turns.
    var poolStrategy: KeyPool.Strategy = .order

    var upstreamProtocol: WireProtocol { target.endpoint.apiProtocol.wire }

    /// The upstream address this candidate calls.
    var endpointID: String {
        "\(target.provider) \(target.endpoint.apiProtocol.rawValue) \(target.endpoint.baseURL)"
    }

    /// Its key, when it has one.
    var keyScope: HealthScope? {
        keyName.isEmpty ? nil : .key(provider: target.provider, keyName: keyName)
    }

    var endpointScope: HealthScope { .endpoint(endpointID) }
    var modelScope: HealthScope { .model(endpoint: endpointID, model: target.model) }

    /// Every scope whose cooldown keeps this candidate back.
    var scopes: [HealthScope] { (keyScope.map { [$0] } ?? []) + [endpointScope, modelScope] }
}

/// What a failure is recorded against: the narrowest thing it says is
/// wrong (docs/server-config-design.md, "健康状态").
enum HealthScope: Hashable, Sendable {
    /// An upstream key: refused (401/402/403) or rate limited (429).
    case key(provider: String, keyName: String)
    /// An upstream address: unreachable, for every key and model.
    case endpoint(String)
    /// A model at an address: server errors, 404, broken replies.
    case model(endpoint: String, model: String)
}


/// What a strategy may look at besides the candidates.
struct RoutingContext: Sendable {
    var clientProtocol: WireProtocol
    var stream: Bool
}

/// Orders a request's candidates. Implementations may keep state (the
/// rotation counter); new policies (weights, affinity) are new
/// conformances, the fallback loop does not change.
protocol RoutingStrategy: Sendable {
    /// - Parameter candidates: in route order, keys in key-pool order.
    func order(_ candidates: [Candidate], context: RoutingContext, health: HealthSnapshot) -> [Candidate]
}

/// Route order; within a model, keys in pool order, or from a
/// round-robin offset per provider for `rotate` pools; candidates cooling
/// down go last (still tried, in the same order, when nothing else is
/// left); disabled keys are left out.
final class KeyPoolOrdering: RoutingStrategy {
    private let counters = NIOLockedValueBox<[String: Int]>([:])

    init() {}

    func order(_ candidates: [Candidate], context: RoutingContext, health: HealthSnapshot) -> [Candidate] {
        // Group consecutive candidates of one model; rotate rotating pools.
        var groups: [[Candidate]] = []
        for candidate in candidates {
            if let last = groups.last?.last, last.reference == candidate.reference {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        var ordered: [Candidate] = []
        for group in groups where !group.isEmpty {
            guard group[0].poolStrategy == .rotate, group.count > 1 else {
                ordered += group
                continue
            }
            let provider = group[0].target.provider
            let offset = counters.withLockedValue { counters -> Int in
                let value = counters[provider, default: 0]
                counters[provider] = value &+ 1
                return value
            }
            let start = offset % group.count
            ordered += group[start...] + group[..<start]
        }
        let usable = ordered.filter { !health.isDisabled($0) }
        let ready = usable.filter { !health.isCooling($0) }
        let cooling = usable.filter { health.isCooling($0) }
        return ready + cooling
    }
}

/// Health at one instant.
struct HealthSnapshot: Sendable {
    var now: ContinuousClock.Instant
    var cooldowns: [HealthScope: ContinuousClock.Instant]
    var disabled: Set<HealthScope> = []

    func isCooling(_ scope: HealthScope) -> Bool {
        guard let until = cooldowns[scope] else { return false }
        return until > now
    }

    func isCooling(_ candidate: Candidate) -> Bool {
        candidate.scopes.contains { isCooling($0) }
    }

    /// A key refused again and again: not tried until the configuration
    /// is reloaded.
    func isDisabled(_ candidate: Candidate) -> Bool {
        candidate.keyScope.map { disabled.contains($0) } ?? false
    }
}

/// In-memory health: cooldowns that grow while failures repeat, and keys
/// disabled after repeated 401s.
final class HealthStore: Sendable {
    struct Entry: Sendable {
        var until: ContinuousClock.Instant
        /// Failures since the last success, for the doubling.
        var failures: Int
    }

    struct State: Sendable {
        var entries: [HealthScope: Entry] = [:]
        var unauthorized: [HealthScope: Int] = [:]
        var disabled: Set<HealthScope> = []
    }

    private let state = NIOLockedValueBox(State())

    /// First cooldown after a 5xx, a broken reply or a connection failure.
    static let failureCooldown: Duration = .seconds(10)
    /// First cooldown after a 429 without a usable `Retry-After`.
    static let rateLimitCooldown: Duration = .seconds(30)
    /// Longest cooldown a doubling reaches, and the cap on `Retry-After`.
    static let maxCooldown: Duration = .seconds(300)
    /// After a 402 (out of credit): the key will not recover soon.
    static let paymentCooldown: Duration = .seconds(1800)
    /// Consecutive 401s after which a key is disabled.
    static let unauthorizedLimit = 2

    init() {}

    func snapshot() -> HealthSnapshot {
        let now = ContinuousClock.now
        return state.withLockedValue { state in
            HealthSnapshot(
                now: now,
                cooldowns: state.entries.filter { $0.value.until > now }.mapValues(\.until),
                disabled: state.disabled,
            )
        }
    }

    /// Cools `scope`: `base` for a first failure, doubled for each one
    /// after it (up to ``maxCooldown``, or `base` when longer); a
    /// `retryAfter` the upstream sent replaces the doubling.
    func recordFailure(_ scope: HealthScope, base: Duration, retryAfter: Duration? = nil) {
        let now = ContinuousClock.now
        state.withLockedValue { state in
            var entry = state.entries[scope] ?? Entry(until: now, failures: 0)
            // A failure long after the last one starts the doubling afresh.
            if entry.until + Self.maxCooldown < now { entry.failures = 0 }
            entry.failures += 1
            let cap = max(base, Self.maxCooldown)
            let cooldown: Duration
            if let retryAfter {
                cooldown = min(retryAfter, cap)
            } else {
                cooldown = min(base * (1 << min(entry.failures - 1, 16)), cap)
            }
            entry.until = max(entry.until, now + cooldown)
            state.entries[scope] = entry
        }
    }

    /// Notes a 401 for `key`; true when this one disables it.
    func recordUnauthorized(_ key: HealthScope) -> Bool {
        state.withLockedValue { state in
            let count = state.unauthorized[key, default: 0] + 1
            state.unauthorized[key] = count
            return count >= Self.unauthorizedLimit && state.disabled.insert(key).inserted
        }
    }

    /// Clears what `candidate` answering disproves.
    func recordSuccess(_ candidate: Candidate) {
        state.withLockedValue { state in
            for scope in candidate.scopes { state.entries.removeValue(forKey: scope) }
            if let key = candidate.keyScope { state.unauthorized.removeValue(forKey: key) }
        }
    }

    /// Drops everything recorded against the scopes `matching` selects.
    func forget(_ matching: (HealthScope) -> Bool) {
        state.withLockedValue { state in
            state.entries = state.entries.filter { !matching($0.key) }
            state.unauthorized = state.unauthorized.filter { !matching($0.key) }
            state.disabled = state.disabled.filter { !matching($0) }
        }
    }

    /// Gives every disabled key another chance (a reload).
    func enableDisabledKeys() {
        state.withLockedValue { state in
            for key in state.disabled { state.unauthorized.removeValue(forKey: key) }
            state.disabled = []
        }
    }

    /// A `Retry-After` in seconds (HTTP dates are not parsed).
    static func retryAfter(_ value: String?) -> Duration? {
        guard let value, let seconds = Int(value.trimmingBlanks()), seconds >= 0 else { return nil }
        return .seconds(seconds)
    }
}


/// Why a request has no candidate.
struct PlanningError: Error, Sendable {
    var status: Int
    /// What the client is told.
    var message: String
    /// What the log is told, when it may say more than the client.
    var detail: String?
}

/// Builds a request's candidate list in route order.
///
/// Name resolution (docs/server-config-design.md): the client's model
/// name (without Gemini's `models/`) is looked up as a route name, exact
/// then patterns; else, as a `provider/model` reference of a known
/// provider, it is passed through; else the `*` route serves it. Each
/// model is resolved preferring the client's protocol, so a provider that
/// speaks it is called without translation.
struct CandidatePlanner: Sendable {
    var configuration: GatewayConfiguration

    /// The model references to try for `clientModel`, in order.
    func references(for clientModel: String, access: ClientAccess = .open) throws(PlanningError) -> [String] {
        let name = clientModel.hasPrefix("models/") ? String(clientModel.dropFirst(7)) : clientModel
        let routes = configuration.routes
        if let route = routes.named(name) {
            guard access.mayUse(route) else { throw Self.notAllowed(clientModel) }
            return route.targets.map { $0.reference(for: name) }
        }
        if let (provider, _) = try? ProviderRegistry.parse(name), configuration.registry[provider] != nil {
            guard access.mayPassThrough(name) else { throw Self.notAllowed(clientModel) }
            do {
                _ = try configuration.registry.resolve(name)
            } catch {
                if case .invalidModelID(_, let reason) = error { throw Self.invalidModel(name, reason) }
            }
            return [name]
        }
        if let route = routes.catchAll {
            guard access.mayUse(route) else { throw Self.notAllowed(clientModel) }
            return route.targets.map { $0.reference(for: name) }
        }
        throw PlanningError(status: 404, message: "model `\(clientModel)` is not served by this gateway")
    }

    func candidates(for clientModel: String, clientProtocol: WireProtocol, access: ClientAccess = .open) throws(PlanningError) -> [Candidate] {
        let references = try references(for: clientModel, access: access)
        var candidates: [Candidate] = []
        var missingKeys: [String] = []
        var unresolved: [String] = []
        for reference in references {
            let target: ResolvedModel
            do {
                target = try configuration.registry.resolve(reference, preferring: APIProtocol(clientProtocol))
            } catch {
                if case .invalidModelID(_, let reason) = error { throw Self.invalidModel(reference, reason) }
                unresolved.append("\(reference): \(error)")
                continue
            }
            if target.endpoint.auth == .none {
                candidates.append(Candidate(reference: reference, target: target, apiKey: nil, keyName: ""))
                continue
            }
            let pool = configuration.keyPools[target.provider]
            let keys = pool?.keys ?? []
            if keys.isEmpty { missingKeys.append(target.provider) }
            for key in keys {
                candidates.append(Candidate(
                    reference: reference, target: target, apiKey: key.secret, keyName: key.name,
                    poolStrategy: pool?.strategy ?? .order,
                ))
            }
        }
        guard !candidates.isEmpty else {
            let variables = missingKeys.map { UpstreamKeys.variables(for: $0, in: configuration.registry).joined(separator: " or ") }
            throw PlanningError(
                status: 503,
                message: "no upstream is available for model `\(clientModel)`",
                detail: !variables.isEmpty
                    ? "no API key configured for \(missingKeys.joined(separator: ", ")) (configure keys, or set \(variables.joined(separator: "; ")))"
                    : "cannot resolve \(unresolved.joined(separator: "; "))",
            )
        }
        return candidates
    }

    static func invalidModel(_ reference: String, _ reason: String) -> PlanningError {
        PlanningError(status: 400, message: "invalid model `\(reference)`: \(reason)")
    }

    static func notAllowed(_ model: String) -> PlanningError {
        PlanningError(status: 403, message: "model `\(model)` is not available with this key")
    }
}
