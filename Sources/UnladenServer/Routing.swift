// Candidates, routing strategy and health (design decision 5).
//
// A request is routed to an ordered candidate list (model × key); the
// fallback loop only tries candidates in that order. A `RoutingStrategy`
// orders them from the request context and each candidate's health. v1 has
// one strategy: configuration order with round-robin key rotation, cooling
// candidates last.

import NIOConcurrencyHelpers
@_spi(Wire) import UnladenCore

/// One way to serve a request: a resolved model and the key to call it with.
struct Candidate: Sendable, Hashable {
    /// The model reference, `provider/model`.
    var reference: String
    var target: ResolvedModel
    /// `nil` for endpoints without authentication.
    var apiKey: String?
    /// Position of ``apiKey`` in its provider's key list.
    var keyIndex: Int

    var healthKey: HealthKey { HealthKey(reference: reference, keyIndex: keyIndex) }
    var upstreamProtocol: WireProtocol { target.endpoint.apiProtocol.wire }
}

/// What a candidate's health is recorded under.
struct HealthKey: Hashable, Sendable {
    var reference: String
    var keyIndex: Int
}

/// What a strategy may look at besides the candidates.
struct RoutingContext: Sendable {
    var clientProtocol: WireProtocol
    var stream: Bool
}

/// Orders a request's candidates. Implementations may keep state (the
/// rotation counter); new policies (weights, quotas, latency) are new
/// conformances, the fallback loop does not change.
protocol RoutingStrategy: Sendable {
    /// - Parameter candidates: in configuration order, keys in key-list order.
    func order(_ candidates: [Candidate], context: RoutingContext, health: HealthSnapshot) -> [Candidate]
}

/// Configuration order; within a model, keys start at a round-robin offset
/// per provider; candidates cooling down go last (still tried, in the same
/// order, when nothing else is left).
final class OrderedKeyRotation: RoutingStrategy {
    private let counters = NIOLockedValueBox<[String: Int]>([:])

    init() {}

    func order(_ candidates: [Candidate], context: RoutingContext, health: HealthSnapshot) -> [Candidate] {
        // Group consecutive candidates of one model; rotate each group.
        var groups: [[Candidate]] = []
        for candidate in candidates {
            if let last = groups.last?.last, last.reference == candidate.reference {
                groups[groups.count - 1].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        var rotated: [Candidate] = []
        for group in groups where !group.isEmpty {
            let provider = group[0].target.provider
            let offset = counters.withLockedValue { counters -> Int in
                let value = counters[provider, default: 0]
                counters[provider] = value &+ 1
                return value
            }
            let start = offset % group.count
            rotated += group[start...] + group[..<start]
        }
        let ready = rotated.filter { !health.isCooling($0.healthKey) }
        let cooling = rotated.filter { health.isCooling($0.healthKey) }
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
    var message: String
}

/// Builds a request's candidate list in configuration order.
///
/// Model resolution: the client's model string is tried as a
/// `provider/model` reference against the registry; if it is not one
/// (`claude-sonnet-4-5`, `gpt-4o`), the configured default model is used.
/// The configured fallbacks follow, without repeats. Each model is
/// resolved preferring the client's protocol, so a provider that speaks it
/// is called without translation.
struct CandidatePlanner: Sendable {
    var configuration: GatewayConfiguration

    /// The model references to try for `clientModel`, in order.
    func references(for clientModel: String) -> [String] {
        var references: [String] = []
        if (try? configuration.registry.resolve(clientModel)) != nil {
            references.append(clientModel)
        } else if let model = configuration.defaultModel {
            references.append(model)
        }
        for fallback in configuration.fallbacks where !references.contains(fallback) {
            references.append(fallback)
        }
        return references
    }

    func candidates(for clientModel: String, clientProtocol: WireProtocol) throws(PlanningError) -> [Candidate] {
        let references = references(for: clientModel)
        guard !references.isEmpty else {
            throw PlanningError(
                status: 404,
                message: "model `\(clientModel)` is not a provider/model reference and the gateway has no default model (--model)",
            )
        }
        var candidates: [Candidate] = []
        var missingKeys: [String] = []
        for reference in references {
            let target: ResolvedModel
            do {
                target = try configuration.registry.resolve(reference, preferring: APIProtocol(clientProtocol))
            } catch {
                continue
            }
            if target.endpoint.auth == .none {
                candidates.append(Candidate(reference: reference, target: target, apiKey: nil, keyIndex: 0))
                continue
            }
            let keys = configuration.upstreamKeys[target.provider] ?? []
            if keys.isEmpty { missingKeys.append(target.provider) }
            for (index, key) in keys.enumerated() {
                candidates.append(Candidate(reference: reference, target: target, apiKey: key, keyIndex: index))
            }
        }
        guard !candidates.isEmpty else {
            let variables = missingKeys.map { UpstreamKeys.variables(for: $0, in: configuration.registry).joined(separator: " or ") }
            throw PlanningError(
                status: 503,
                message: variables.isEmpty
                    ? "no upstream can serve model `\(clientModel)`"
                    : "no API key configured for the upstream (set \(variables.joined(separator: "; ")))",
            )
        }
        return candidates
    }
}
