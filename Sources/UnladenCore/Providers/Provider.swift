/// A vendor or relay: its endpoints (one per protocol) and model rules.
///
/// Vendor = protocol × endpoint × Profile. A standard OpenAI-compatible
/// vendor is one Chat endpoint and no rules; a quirky one adds Profile data
/// and named transforms.
///
/// **Profile resolution** for a model id:
/// 1. Pick the model rule: an ``ModelMatch/exact(_:)`` match wins; else the
///    *longest* matching ``ModelMatch/prefix(_:)``; else the first matching
///    ``ModelMatch/pattern(_:)`` in declaration order; else none. Matching
///    ignores ASCII case.
/// 2. Pick the endpoint: the rule's ``Profile/forcedProtocol`` if the
///    provider has it; else the caller's preferred protocol if it has it;
///    else the first endpoint.
/// 3. Merge: endpoint ``Endpoint/defaults`` < rule profile
///    (``Profile/merged(over:)``).
public struct Provider: Hashable, Sendable {
    /// The name in model references (`"<id>/<model>"`).
    public var id: String
    /// In order of preference.
    public var endpoints: [Endpoint]
    public var models: [ModelRule]
    /// Environment variables that may hold this provider's API key, in
    /// order of preference (e.g. `ANTHROPIC_API_KEY`). Consulted by the
    /// library when no key was configured explicitly.
    public var apiKeyEnvironmentVariables: [String]
    /// Some models are served to callers with no key (a relay's free
    /// models): without one, requests go with no credentials.
    public var servesWithoutKey: Bool

    public init(
        id: String, apiKeyEnvironmentVariables: [String] = [], servesWithoutKey: Bool = false, endpoints: [Endpoint],
        models: [ModelRule] = [],
    ) {
        self.id = id
        self.endpoints = endpoints
        self.models = models
        self.apiKeyEnvironmentVariables = apiKeyEnvironmentVariables
        self.servesWithoutKey = servesWithoutKey
    }

    /// The rule that applies to `model` (see the type's documentation).
    public func rule(for model: String) -> ModelRule? {
        var bestPrefix: (rule: ModelRule, length: Int)?
        var firstPattern: ModelRule?
        for rule in models where rule.match.matches(model) {
            switch rule.match {
            case .exact:
                return rule
            case .prefix(let value):
                if value.count > bestPrefix?.length ?? -1 { bestPrefix = (rule, value.count) }
            case .pattern:
                if firstPattern == nil { firstPattern = rule }
            }
        }
        return bestPrefix?.rule ?? firstPattern
    }

    /// Resolves `model` on this provider.
    public func resolve(model: String, preferring preferred: APIProtocol? = nil) throws(ModelReferenceError) -> ResolvedModel {
        let rule = rule(for: model)
        let endpoint: Endpoint?
        if let forced = rule?.profile.forcedProtocol {
            endpoint = endpoints.first { $0.apiProtocol == forced }
            guard endpoint != nil else { throw .forcedProtocolUnavailable(provider: id, model: model, forced) }
        } else {
            endpoint = preferred.flatMap { want in endpoints.first { $0.apiProtocol == want } } ?? endpoints.first
        }
        guard let endpoint else { throw .noEndpoint(provider: id) }
        try ModelID.validate(model, for: endpoint.apiProtocol)
        let profile = rule.map { $0.profile.merged(over: endpoint.defaults) } ?? endpoint.defaults
        return ResolvedModel(provider: id, model: model, endpoint: endpoint, profile: profile)
    }
}

/// A model reference resolved to everything needed to call it.
public struct ResolvedModel: Hashable, Sendable {
    public var provider: String
    /// The model id as the upstream knows it (e.g. `anthropic/claude-…` on
    /// OpenRouter).
    public var model: String
    public var endpoint: Endpoint
    public var profile: Profile

    public init(provider: String, model: String, endpoint: Endpoint, profile: Profile) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
        self.profile = profile
    }
}

public enum ModelReferenceError: Error, Hashable, Sendable {
    /// Not `"<provider>/<model>"` with both parts non-empty.
    case malformed(String)
    case unknownProvider(String)
    case noEndpoint(provider: String)
    case forcedProtocolUnavailable(provider: String, model: String, APIProtocol)
    /// The model id holds something that could leave its place in the
    /// upstream request (see ``ModelID/validate(_:for:)``).
    case invalidModelID(String, reason: String)
}

/// Model id checks, applied when a reference is resolved.
public enum ModelID {
    /// Throws ``ModelReferenceError/invalidModelID(_:reason:)`` unless
    /// `model` is a plain id.
    ///
    /// Rejected anywhere: an empty id, control characters, whitespace, `?`,
    /// `#`, `\`, and empty, `.` or `..` path segments. `/` is allowed where
    /// the id goes into the JSON body (OpenRouter's `anthropic/claude-…`);
    /// Gemini puts the id in the URL path, so there only a leading
    /// `models/` is (it is not repeated in the path).
    public static func validate(_ model: String, for apiProtocol: APIProtocol) throws(ModelReferenceError) {
        func reject(_ reason: String) -> ModelReferenceError { .invalidModelID(model, reason: reason) }
        guard !model.isEmpty else { throw reject("empty") }
        for scalar in model.unicodeScalars {
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { throw reject("control character") }
            if scalar.properties.isWhitespace { throw reject("whitespace") }
            if scalar == "?" || scalar == "#" || scalar == "\\" { throw reject("`\(scalar)` is not allowed") }
        }
        let segments = model.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments where segment.isEmpty || segment == "." || segment == ".." {
            throw reject(segment.isEmpty ? "empty path segment" : "`\(segment)` path segment")
        }
        if apiProtocol == .gemini {
            let name = model.hasPrefix("models/") ? model.dropFirst(7) : Substring(model)
            if name.contains("/") { throw reject("`/` is not allowed in a Gemini model id") }
        }
    }
}

/// The providers a library client or gateway knows about: a value, so each
/// owner keeps its own copy (no global mutable state).
///
/// ```swift
/// var registry = ProviderRegistry.builtIn
/// registry.register(Provider(id: "lab", endpoints: [Endpoint(system: "lab", apiProtocol: .chatCompletions, baseURL: "http://10.0.0.2:8000/v1")]))
/// let target = try registry.resolve("openrouter/anthropic/claude-sonnet-4-6")
/// ```
public struct ProviderRegistry: Hashable, Sendable {
    public private(set) var providers: [String: Provider] = [:]

    public init(_ providers: [Provider] = []) {
        for provider in providers { register(provider) }
    }

    /// The built-in presets (``Presets``).
    public static var builtIn: ProviderRegistry { ProviderRegistry(Presets.all) }

    /// Adds `provider`, replacing one with the same id.
    public mutating func register(_ provider: Provider) {
        providers[provider.id] = provider
    }

    /// Adds model rules to a registered provider. They come first, so a
    /// user's rule wins over a preset's of the same kind (an exact match
    /// over an exact match, a pattern over a pattern; a longer prefix still
    /// wins over a shorter one).
    public mutating func addModelRules(_ rules: [ModelRule], to providerID: String) throws(ModelReferenceError) {
        guard var provider = providers[providerID] else { throw .unknownProvider(providerID) }
        provider.models = rules + provider.models
        providers[providerID] = provider
    }

    public subscript(id: String) -> Provider? { providers[id] }

    /// Splits `"<provider>/<model>"` at the first `/`; the model keeps any
    /// further slashes (`openrouter/anthropic/claude-…`).
    public static func parse(_ reference: String) throws(ModelReferenceError) -> (provider: String, model: String) {
        guard let slash = reference.firstIndex(of: "/") else { throw .malformed(reference) }
        let provider = String(reference[..<slash])
        let model = String(reference[reference.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { throw .malformed(reference) }
        return (provider, model)
    }

    /// Resolves a `"<provider>/<model>"` reference.
    public func resolve(_ reference: String, preferring preferred: APIProtocol? = nil) throws(ModelReferenceError) -> ResolvedModel {
        let (providerID, model) = try Self.parse(reference)
        guard let provider = providers[providerID] else { throw .unknownProvider(providerID) }
        return try provider.resolve(model: model, preferring: preferred)
    }
}
