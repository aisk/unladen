// What the gateway is told at start: CLI flags and environment variables.
// There is no configuration file yet (its design is still open).

@_spi(Wire) import UnladenCore

/// Settings of one gateway instance.
struct GatewayConfiguration: Sendable {
    /// Model references (`provider/model`) used when the client's model
    /// string does not resolve as a reference itself, in order of
    /// preference: the default model first. Empty: only resolvable client
    /// model strings are served.
    var defaultModel: String?
    /// Models tried, in order, after the requested (or default) one failed
    /// with a retryable error.
    var fallbacks: [String] = []
    /// When set, clients must present it (`Authorization: Bearer`,
    /// `x-api-key`, `x-goog-api-key`, or `?key=` on Gemini routes).
    var apiKey: String?
    /// Skip candidates the request cannot be carried to exactly (lossy
    /// warnings; kept unknown fields, `adjusted` rewrites and cache hints
    /// do not count), and answer 400 when no candidate is left, instead of
    /// forwarding with an `x-unladen-warnings` header.
    var strict = false
    /// How long a streaming client may go without an event before it is
    /// sent a keepalive.
    var keepaliveInterval: Duration = .seconds(15)
    /// Largest request body accepted.
    var maxRequestBytes = 64 << 20
    var registry = ProviderRegistry.builtIn
    /// Upstream API keys by provider id, rotated per request.
    var upstreamKeys: [String: [String]] = [:]
}

/// Where upstream API keys come from: one environment variable per
/// provider, a comma-separated list for key rotation.
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

    /// Keys for every provider of `registry` found in `environment`.
    static func load(for registry: ProviderRegistry, environment: (String) -> String?) -> [String: [String]] {
        var keys: [String: [String]] = [:]
        for provider in registry.providers.keys {
            for variable in variables(for: provider, in: registry) {
                guard let value = environment(variable) else { continue }
                let list = split(value)
                if !list.isEmpty {
                    keys[provider] = list
                    break
                }
            }
        }
        return keys
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
