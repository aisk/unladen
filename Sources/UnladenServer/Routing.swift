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

    var healthKey: HealthKey { HealthKey(reference: reference, keyName: keyName) }
    var upstreamProtocol: WireProtocol { target.endpoint.apiProtocol.wire }
}

/// What a candidate's health is recorded under.
struct HealthKey: Hashable, Sendable {
    var reference: String
    var keyName: String

    /// An upstream key: its provider and name.
    struct Key: Hashable, Sendable {
        var provider: String
        var keyName: String
    }

    var key: Key {
        Key(provider: String(reference.prefix { $0 != "/" }), keyName: keyName)
    }
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
/// left).
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
        let ready = ordered.filter { !health.isCooling($0.healthKey) }
        let cooling = ordered.filter { health.isCooling($0.healthKey) }
        return ready + cooling
    }
}

/// Cooldowns at one instant.
struct HealthSnapshot: Sendable {
    var now: ContinuousClock.Instant
    var cooldowns: [HealthKey: ContinuousClock.Instant]

    func isCooling(_ key: HealthKey) -> Bool {
        guard let until = cooldowns[key] else { return false }
        return until > now
    }
}

/// In-memory candidate health: a cooldown after a rate limit, a server
/// error or a connection failure.
final class HealthStore: Sendable {
    private let cooldowns = NIOLockedValueBox<[HealthKey: ContinuousClock.Instant]>([:])

    /// Cooldown after a 5xx or a connection failure.
    static let failureCooldown: Duration = .seconds(10)
    /// Cooldown after a 429 without a usable `Retry-After`.
    static let rateLimitCooldown: Duration = .seconds(30)
    /// Longest cooldown, whatever `Retry-After` says.
    static let maxCooldown: Duration = .seconds(300)

    init() {}

    func snapshot() -> HealthSnapshot {
        let now = ContinuousClock.now
        return cooldowns.withLockedValue { cooldowns in
            cooldowns = cooldowns.filter { $0.value > now }
            return HealthSnapshot(now: now, cooldowns: cooldowns)
        }
    }

    func recordFailure(_ key: HealthKey, cooldown: Duration) {
        let until = ContinuousClock.now + min(cooldown, Self.maxCooldown)
        cooldowns.withLockedValue { cooldowns in
            cooldowns[key] = max(cooldowns[key] ?? until, until)
        }
    }

    func recordSuccess(_ key: HealthKey) {
        _ = cooldowns.withLockedValue { $0.removeValue(forKey: key) }
    }

    /// Drops the cooldowns of the keys `matching` selects.
    func forget(_ matching: (HealthKey) -> Bool) {
        cooldowns.withLockedValue { cooldowns in cooldowns = cooldowns.filter { !matching($0.key) } }
    }

    /// The cooldown for an upstream status, honouring a `Retry-After` in
    /// seconds (HTTP dates are not parsed and get the default).
    static func cooldown(status: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Int(retryAfter.trimmingBlanks()), seconds >= 0 {
            return .seconds(seconds)
        }
        return status == 429 ? rateLimitCooldown : failureCooldown
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
