// What `GET /v1/models` lists: the menu's exact names, and for menu
// patterns that pass the asked name on to a provider (`"gpt-*": "chatgpt"`),
// the provider's own models the pattern takes, asked of the provider.

import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
@_spi(Wire) import UnladenCore

/// Providers' model lists, asked of them with the first account that
/// answers and kept for a while.
final class ModelCatalog: Sendable {
    /// How long a list is kept.
    static let lifetime: Int64 = 10 * 60 * 1000
    /// How long a provider that did not answer is left alone.
    static let failureLifetime: Int64 = 60 * 1000
    /// The longest one provider may take to answer.
    static let timeout: Duration = .seconds(10)

    private struct Entry {
        var names: [String]
        var until: Int64
    }

    private let entries = NIOLockedValueBox([String: Entry]())

    init() {}

    /// Forgets every list (the configuration changed).
    func forget() {
        entries.withLockedValue { $0 = [:] }
    }

    /// The models `provider` lists; empty when it cannot be asked.
    func names(of provider: String, gateway: Gateway, configuration: GatewayConfiguration) async -> [String] {
        let now = LocalDay.nowMilliseconds()
        if let entry = entries.withLockedValue({ $0[provider] }), entry.until > now { return entry.names }
        let names = await fetch(provider, gateway: gateway, configuration: configuration)
        entries.withLockedValue {
            $0[provider] = Entry(names: names ?? [], until: now + (names == nil ? Self.failureLifetime : Self.lifetime))
        }
        return names ?? []
    }

    /// Each endpoint of the provider (Chat first) with each of its
    /// accounts, until one answers; `nil` when none does.
    private func fetch(_ provider: String, gateway: Gateway, configuration: GatewayConfiguration) async -> [String]? {
        guard let entry = configuration.registry[provider] else { return nil }
        let order: [APIProtocol] = [.chatCompletions, .responses, .anthropicMessages, .gemini]
        let endpoints = entry.endpoints.sorted { a, b in
            (order.firstIndex(of: a.apiProtocol) ?? 0) < (order.firstIndex(of: b.apiProtocol) ?? 0)
        }
        let keys = configuration.keyPools[provider]?.keys ?? []
        for endpoint in endpoints {
            guard let target = try? configuration.registry.resolve(provider + "/models", preferring: endpoint.apiProtocol),
                  target.endpoint == endpoint
            else { continue }
            // `nil`: no key (an endpoint without authentication).
            let credentials: [UpstreamKey?] = endpoint.auth == .none ? [nil] : keys.map(Optional.some)
            for key in credentials {
                var apiKey = key?.secret
                if let key, key.signIn != nil {
                    apiKey = try? await gateway.signIns.token(provider: provider, account: key.name, transport: gateway.transport)
                    if apiKey == nil { continue }
                }
                let transport = gateway.upstreamTransport(signIn: key?.signIn, provider: provider, account: key?.name ?? "")
                let call = UpstreamCall(target: target, apiKey: apiKey, transport: transport)
                if let names = try? await Gateway.within(Self.timeout, { try await call.listModels() }), !names.isEmpty {
                    return names
                }
            }
        }
        return nil
    }
}

extension Gateway {
    /// The model names `access` may ask for: the menu's exact names; the
    /// `*` entry's model when the client may name it directly; and the
    /// models of providers that menu patterns pass names on to, which the
    /// pattern takes and resolution leads to that pattern.
    func modelNames(_ configuration: GatewayConfiguration, access: ClientAccess = .open) async -> [String] {
        var names: [String] = []
        for route in configuration.routes.all {
            if route.name == "*" {
                for target in route.targets where !target.model.contains("$model") && access.mayPassThrough(target.model) {
                    names.append(target.model)
                }
            } else if !route.isPattern, access.mayUse(route.name) {
                names.append(route.name)
            }
        }
        for route in configuration.routes.all where route.isPattern || route.name == "*" {
            // Only a pattern that passes the name on as it is.
            guard let target = route.targets.first, target.model.hasSuffix("/$model") else { continue }
            let provider = String(target.model.dropLast("/$model".count))
            guard !provider.contains("$model") else { continue }
            for name in await models.names(of: provider, gateway: self, configuration: configuration) {
                let leadsHere = route.name == "*" ? configuration.routes.named(name) == nil : configuration.routes.named(name) == route
                if leadsHere, access.mayUse(name) { names.append(name) }
            }
        }
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}

/// The list in a form OpenAI clients (`object`, `data[].id`, `owned_by`)
/// and Anthropic clients (`data[].type`, `display_name`, `has_more`) read.
func modelList(_ references: [String]) -> Response {
    let data: [JSONValue] = references.map { reference in
        let provider = reference.contains("/") ? reference.split(separator: "/", maxSplits: 1).first.map(String.init) ?? reference : "unladen"
        return [
            "id": .string(reference),
            "object": "model",
            "type": "model",
            "display_name": .string(reference),
            "owned_by": .string(provider),
            "created": 0,
            "created_at": "1970-01-01T00:00:00Z",
        ]
    }
    let json: JSONValue = [
        "object": "list",
        "data": .array(data),
        "has_more": false,
        "first_id": references.first.map(JSONValue.string) ?? .null,
        "last_id": references.last.map(JSONValue.string) ?? .null,
    ]
    return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: json.encoded())))
}
