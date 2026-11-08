import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private func parse(_ yaml: String, overrides: ConfigOverrides = ConfigOverrides(), environment: [String: String] = [:]) throws -> LoadedConfiguration {
    try ConfigFile.parse(yaml, file: "config.yaml", overrides: overrides) { environment[$0] }
}

private func parseError(_ yaml: String, environment: [String: String] = [:]) -> ConfigError? {
    do {
        _ = try parse(yaml, environment: environment)
        return nil
    } catch {
        return error as? ConfigError
    }
}

@Suite struct ConfigFileTests {
    static let example = """
    server:
      listen: 0.0.0.0:8080
      strict: true
      keepalive: 5s
      connect_timeout: 3s
      max_request_bytes: 1MiB

    providers:
      deepseek:
        keys: ["${DEEPSEEK_KEY}"]
      anthropic:
        strategy: rotate
        keys:
          - { name: work, key: "${ANTHROPIC_WORK}" }
          - { name: personal, key: "${ANTHROPIC_PERSONAL}", enabled: false }
      relay:
        preset: openai
        endpoints:
          chat: https://relay.example.com/v1
        headers: { X-Team: infra }
        keys: ["${RELAY_KEY}"]
      local:
        endpoints:
          chat: http://10.0.0.2:8000/v1

    routes:
      "claude-*": anthropic/$model
      sonnet:
        targets:
          - { model: anthropic/claude-sonnet-4-5 }
      "*": deepseek/deepseek-chat

    client_keys:
      - name: laptop
        secret: "${LAPTOP}"
        routes: ["claude-*"]
        passthrough: ["deepseek/*"]
      - { name: ci, secret: "${CI}", passthrough: true }
      - { name: old, secret: "${OLD}", enabled: false }
    """

    static let environment = [
        "DEEPSEEK_KEY": "sk-d", "ANTHROPIC_WORK": "sk-w", "ANTHROPIC_PERSONAL": "sk-p", "RELAY_KEY": "sk-r",
        "LAPTOP": "c-1", "CI": "c-2", "OLD": "c-3",
    ]

    @Test func fullExample() throws {
        let loaded = try parse(Self.example, environment: Self.environment)
        #expect(loaded.server == ServerSettings(host: "0.0.0.0", port: 8080, connectTimeout: .seconds(3)))
        let gateway = loaded.gateway
        #expect(gateway.strict)
        #expect(gateway.keepaliveInterval == .seconds(5))
        #expect(gateway.maxRequestBytes == 1 << 20)
        #expect(!loaded.hasLiteralSecrets)

        #expect(gateway.keyPools["deepseek"] == KeyPool(keys: [UpstreamKey(secret: "sk-d")]))
        // A disabled key is left out of the pool.
        #expect(gateway.keyPools["anthropic"] == KeyPool(keys: [UpstreamKey(name: "work", secret: "sk-w")], strategy: .rotate))

        // A preset-based relay keeps only the endpoints it lists, with the
        // preset's profile and the extra header.
        let relay = try #require(gateway.registry["relay"])
        #expect(relay.endpoints.map(\.apiProtocol) == [.chatCompletions])
        #expect(relay.endpoints[0].baseURL == "https://relay.example.com/v1")
        #expect(relay.endpoints[0].headers["x-team"] == "infra")
        #expect(relay.endpoints[0].auth == .bearer)
        #expect(gateway.keyPools["relay"]?.keys.map(\.secret) == ["sk-r"])
        // A custom provider without keys calls its endpoints unauthenticated.
        #expect(gateway.registry["local"]?.endpoints.map(\.auth) == [.none])

        #expect(gateway.routes.named("claude-opus-4-1")?.name == "claude-*")
        #expect(gateway.routes.named("SONNET")?.targets == [RouteTarget(model: "anthropic/claude-sonnet-4-5")])
        #expect(gateway.routes.catchAll?.targets == [RouteTarget(model: "deepseek/deepseek-chat")])

        #expect(gateway.clientKeys == [
            ClientKey(name: "laptop", secret: "c-1", routes: ["claude-*"], passthrough: ["deepseek/*"]),
            ClientKey(name: "ci", secret: "c-2", routes: nil, passthrough: ["*"]),
        ])
        #expect(loaded.warnings.contains { $0.contains("route `*`") })
    }

    @Test func emptyFileUsesTheEnvironment() throws {
        let loaded = try parse("", environment: ["DEEPSEEK_API_KEY": "a, b", "UNLADEN_API_KEY": "client"])
        #expect(loaded.server == ServerSettings())
        #expect(loaded.gateway.keyPools["deepseek"]?.keys.map(\.secret) == ["a", "b"])
        #expect(loaded.gateway.routes.isEmpty)
        #expect(loaded.gateway.clientKeys.map(\.secret) == ["client"])
    }

    @Test func fileKeysWinOverTheEnvironment() throws {
        let loaded = try parse("providers: { deepseek: { keys: [from-file] } }", environment: ["DEEPSEEK_API_KEY": "from-env"])
        #expect(loaded.gateway.keyPools["deepseek"]?.keys.map(\.secret) == ["from-file"])
        #expect(loaded.hasLiteralSecrets)
    }

    @Test func commandLineOverridesTheFile() throws {
        let overrides = ConfigOverrides(host: "::1", port: 9000, model: "openai/gpt-4o", apiKey: "cli", strict: true, keepalive: 2)
        let loaded = try parse(#"routes: { "*": deepseek/deepseek-chat }"#, overrides: overrides)
        #expect(loaded.server.host == "::1")
        #expect(loaded.server.port == 9000)
        #expect(loaded.gateway.routes.catchAll?.targets == [RouteTarget(model: "openai/gpt-4o")])
        #expect(loaded.gateway.strict)
        #expect(loaded.gateway.keepaliveInterval == .seconds(2))
        #expect(loaded.gateway.clientKeys.map(\.secret) == ["cli"])
        #expect(loaded.warnings.contains { $0.contains("--model replaces") })
    }

    @Test func unknownFieldsAreRefusedWithTheirPlace() {
        let error = parseError("server:\n  listen: 127.0.0.1:1\n  lisen: x\n")
        #expect(error?.message.contains("server.lisen: unknown field") == true)
        #expect(error?.location == "config.yaml:3:10")
    }

    @Test func laterFeaturesAreNamedAsNotSupportedYet() {
        #expect(parseError("routes: { a: { targets: [openai/gpt-4o], head_timeout: 5s } }")?.message.contains("not supported yet") == true)
        #expect(parseError("routes: { a: { targets: [openai/gpt-4o, deepseek/deepseek-chat] } }")?.message.contains("more than one target") == true)
        #expect(parseError("routes: { a: { targets: [{ model: openai/gpt-4o, priority: 2 }] } }")?.message.contains("not supported yet") == true)
        #expect(parseError("providers: { openai: { strategy: weight } }")?.message.contains("not supported yet") == true)
        #expect(parseError("providers: { openai: { models: {} } }")?.message.contains("not supported yet") == true)
    }

    @Test func invalidValues() {
        #expect(parseError("providers: { x: { keys: [\"${NOPE}\"] } }")?.message.contains("NOPE is not set") == true)
        #expect(parseError("routes: { a: nowhere/model }")?.message.contains("unknown provider `nowhere`") == true)
        #expect(parseError("routes: { a: gpt-4o }")?.message.contains("expected provider/model") == true)
        #expect(parseError("providers: { relay: { keys: [k] } }")?.message.contains("not a preset") == true)
        #expect(parseError("providers: { r: { preset: nope, endpoints: { chat: https://x } } }")?.message.contains("unknown preset") == true)
        #expect(parseError("providers: { r: { endpoints: { chat: ftp://x } } }")?.message.contains("http://") == true)
        #expect(parseError("server: { listen: localhost }")?.message.contains("host:port") == true)
        #expect(parseError("server: { keepalive: soon }")?.message.contains("duration") == true)
        #expect(parseError("providers: { openai: { keys: [a, a] } }")?.message.contains("listed twice") == true)
        #expect(parseError("client_keys: [{ name: a, secret: s }, { name: a, secret: t }]")?.message.contains("named `a`") == true)
        #expect(parseError("routes: { A: openai/gpt-4o, a: openai/gpt-4o }")?.message.contains("defined twice") == true)
        #expect(parseError("server: [")?.message.contains("not valid YAML") == true)
    }

    @Test func interpolation() throws {
        let env = ["A": "1", "B_2": "two"]
        #expect(try Interpolation.expand("x${A}y${B_2}", environment: { env[$0] }) == "x1ytwo")
        #expect(try Interpolation.expand("$model and $", environment: { env[$0] }) == "$model and $")
        #expect(throws: Interpolation.Failure.self) { try Interpolation.expand("${A", environment: { env[$0] }) }
        #expect(throws: Interpolation.Failure.self) { try Interpolation.expand("${1A}", environment: { env[$0] }) }
    }

    @Test func globs() {
        #expect(Glob.matches("claude-*", "Claude-Sonnet-4-5"))
        #expect(Glob.matches("*", ""))
        #expect(Glob.matches("a*b*c", "aXbYc"))
        #expect(!Glob.matches("claude-*", "gpt-4o"))
        #expect(!Glob.matches("a*b", "ab-c"))
        // More literal characters is more specific.
        let table = RouteTable([
            Route(name: "claude-*", targets: [RouteTarget(model: "anthropic/$model")]),
            Route(name: "claude-opus-*", targets: [RouteTarget(model: "openrouter/anthropic/$model")]),
        ])
        #expect(table.named("claude-opus-4-1")?.name == "claude-opus-*")
        #expect(table.named("claude-sonnet-4-5")?.name == "claude-*")
    }
}

@Suite struct RouteResolutionTests {
    static let routes = [
        Route(name: "claude-*", targets: [RouteTarget(model: "anthropic/$model")]),
        Route(name: "fast", targets: [RouteTarget(model: "deepseek/deepseek-chat")]),
    ]

    @Test func namesResolveInOrder() throws {
        var configuration = GatewayConfiguration()
        configuration.routes = RouteTable(Self.routes + [Route(name: "*", targets: [RouteTarget(model: "openai/gpt-4o")])])
        let planner = CandidatePlanner(configuration: configuration)
        #expect(try planner.references(for: "fast") == ["deepseek/deepseek-chat"])
        #expect(try planner.references(for: "claude-sonnet-4-5") == ["anthropic/claude-sonnet-4-5"])
        #expect(try planner.references(for: "models/claude-sonnet-4-5") == ["anthropic/claude-sonnet-4-5"])
        #expect(try planner.references(for: "mistral/mistral-large-latest") == ["mistral/mistral-large-latest"])
        #expect(try planner.references(for: "gpt-5") == ["openai/gpt-4o"])
        #expect(try planner.references(for: "nowhere/model") == ["openai/gpt-4o"])
    }

    @Test func withoutACatchAllUnknownNamesAre404() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        try await makeApp(makeGateway(upstream, model: nil, routes: Self.routes)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gpt-4o"))
            #expect(response.status == .notFound)
        }
        #expect(upstream.requests.isEmpty)
    }

    @Test func patternRoutePassesTheClientsModelThrough() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Anthropic/responses/thinking_text.json")) }
        try await makeApp(makeGateway(upstream, routes: Self.routes)).test(.router) { client in
            let response = try await client.post("/v1/messages", ClientRequest.anthropic(model: "claude-opus-4-1"))
            #expect(response.status == .ok)
            #expect(response.headers[Gateway.modelHeader] == "anthropic/claude-opus-4-1")
        }
        #expect(upstream.requests.first?.json["model"] == "claude-opus-4-1")
    }

    @Test func clientKeysAreHeldToTheirRoutesAndPassthrough() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        let laptop = ClientKey(name: "laptop", secret: "c-1", routes: ["fast"], passthrough: ["deepseek/*"])
        let gateway = makeGateway(upstream, routes: Self.routes, clientKeys: [laptop])
        try await makeApp(gateway).test(.router) { client in
            let auth: HTTPFields = [.authorization: "Bearer c-1"]
            var response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "fast"), headers: auth)
            #expect(response.status == .ok)
            response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "deepseek/deepseek-chat"), headers: auth)
            #expect(response.status == .ok)
            for model in ["claude-sonnet-4-5", "openai/gpt-4o", "anything"] {
                response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: model), headers: auth)
                #expect(response.status == .forbidden, "\(model)")
            }
            response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "fast"))
            #expect(response.status == .unauthorized)
            response = try await client.executeRequest(uri: "/v1/models", method: .get, headers: auth, body: nil)
            #expect(json(response.body)["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["fast"])
        }
        #expect(upstream.requests.count == 2)
    }
}
