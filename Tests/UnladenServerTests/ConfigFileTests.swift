import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private func parse(_ text: String, overrides: ConfigOverrides = ConfigOverrides(), environment: [String: String] = [:]) throws -> LoadedConfiguration {
    try ConfigFile.parse(text, file: "config.jsonc", overrides: overrides) { environment[$0] }
}

private func parseError(_ text: String, environment: [String: String] = [:]) -> ConfigError? {
    do {
        _ = try parse(text, environment: environment)
        return nil
    } catch {
        return error as? ConfigError
    }
}

@Suite struct ConfigFileTests {
    static let example = """
    // An example with every section.
    {
      "listen": "0.0.0.0:8080",
      "panel": { "token": "${PANEL}" },
      "accounts": {
        "deepseek": "${DEEPSEEK_KEY}",
        "work": { "provider": "anthropic", "key": "${ANTHROPIC_WORK}" },
        "personal": { "provider": "anthropic", "key": "${ANTHROPIC_PERSONAL}", "enabled": false },
        "spare": { "provider": "anthropic", "key": "${ANTHROPIC_SPARE}" },
        "relay": {
          "preset": "openai",
          "endpoints": { "chat": "https://relay.example.com/v1" },
          "headers": { "X-Team": "infra" },
          "key": "${RELAY_KEY}",
        },
        "relay-2": { "provider": "relay", "key": "${RELAY_KEY_2}" },
        /* No key: called without authentication. */
        "local": { "endpoints": { "chat": "http://10.0.0.2:8000/v1" } },
      },
      "models": {
        "claude-*": "anthropic",
        "sonnet": "anthropic/claude-sonnet-4-5",
        "cheap": "deepseek/deepseek-chat",
        "fast": "@cheap",
        "gpt-*": "relay",
        "*": "@fast",
      },
      "clients": {
        "laptop": { "key": "${LAPTOP}", "models": "*" },
        "bob": { "key": "${BOB}", "models": ["claude-*", "deepseek/*"] },
        "ci": { "key": "${CI}" },
        "old": { "key": "${OLD}", "enabled": false },
      },
      "advanced": {
        "strict": true,
        "keepalive": "5s",
        "connect_timeout": "3s",
        "max_request_bytes": "1MiB",
        "pools": { "anthropic": "rotate" },
      },
    }
    """

    static let environment = [
        "PANEL": "panel-token-0123456789",
        "DEEPSEEK_KEY": "sk-d", "ANTHROPIC_WORK": "sk-w", "ANTHROPIC_PERSONAL": "sk-p", "ANTHROPIC_SPARE": "sk-s",
        "RELAY_KEY": "sk-r", "RELAY_KEY_2": "sk-r2", "LAPTOP": "c-1", "BOB": "c-2", "CI": "c-3", "OLD": "c-4",
    ]

    @Test func fullExample() throws {
        let loaded = try parse(Self.example, environment: Self.environment)
        #expect(loaded.server == ServerSettings(host: "0.0.0.0", port: 8080, connectTimeout: .seconds(3)))
        let gateway = loaded.gateway
        #expect(gateway.adminToken == "panel-token-0123456789")
        #expect(gateway.strict)
        #expect(gateway.keepaliveInterval == .seconds(5))
        #expect(gateway.maxRequestBytes == 1 << 20)
        #expect(!loaded.hasLiteralSecrets)

        // Accounts are keys named after themselves, pooled by provider in
        // file order; a disabled one is left out.
        #expect(gateway.keyPools["deepseek"] == KeyPool(keys: [UpstreamKey(name: "deepseek", secret: "sk-d")]))
        #expect(gateway.keyPools["anthropic"] == KeyPool(
            keys: [UpstreamKey(name: "work", secret: "sk-w"), UpstreamKey(name: "spare", secret: "sk-s")], strategy: .rotate,
        ))

        // An account with endpoints is a provider of its own, keeping only
        // the endpoints it lists, with the preset's profile and the header;
        // another account of it joins its pool.
        let relay = try #require(gateway.registry["relay"])
        #expect(relay.endpoints.map(\.apiProtocol) == [.chatCompletions])
        #expect(relay.endpoints[0].baseURL == "https://relay.example.com/v1")
        #expect(relay.endpoints[0].headers["x-team"] == "infra")
        #expect(relay.endpoints[0].auth == .bearer)
        #expect(gateway.keyPools["relay"]?.keys.map(\.name) == ["relay", "relay-2"])
        // Without a key, its endpoints are called unauthenticated.
        #expect(gateway.registry["local"]?.endpoints.map(\.auth) == [.none])
        #expect(gateway.keyPools["local"] == nil)

        // A provider alone stands for provider/$model; @name takes the
        // target of another entry.
        #expect(gateway.routes.named("claude-opus-4-1")?.targets == [RouteTarget(model: "anthropic/$model")])
        #expect(gateway.routes.named("SONNET")?.targets == [RouteTarget(model: "anthropic/claude-sonnet-4-5")])
        #expect(gateway.routes.named("fast")?.targets == [RouteTarget(model: "deepseek/deepseek-chat")])
        #expect(gateway.routes.catchAll?.targets == [RouteTarget(model: "deepseek/deepseek-chat")])

        #expect(gateway.clientKeys == [
            ClientKey(name: "laptop", secret: "c-1", models: ["*"]),
            ClientKey(name: "bob", secret: "c-2", models: ["claude-*", "deepseek/*"]),
            ClientKey(name: "ci", secret: "c-3", models: nil),
        ])
        #expect(loaded.warnings.contains { $0.contains("`*` serves every model name") })
    }

    @Test func clientsAreHeldToTheirModels() throws {
        let gateway = try parse(Self.example, environment: Self.environment).gateway
        let planner = CandidatePlanner(configuration: gateway)
        func allowed(_ client: String, _ model: String) -> Bool {
            let key = gateway.clientKeys.first { $0.name == client }!
            return (try? planner.references(for: model, access: .key(key))) != nil
        }
        // The whole menu, nothing outside it.
        #expect(allowed("ci", "claude-sonnet-4-5") && allowed("ci", "fast") && allowed("ci", "anything"))
        #expect(!allowed("ci", "openai/gpt-4o"))
        // Globs over the names asked for, menu or provider/model alike.
        #expect(allowed("bob", "claude-sonnet-4-5") && allowed("bob", "deepseek/deepseek-chat"))
        #expect(!allowed("bob", "fast") && !allowed("bob", "anything") && !allowed("bob", "openai/gpt-4o"))
        #expect(allowed("laptop", "openai/gpt-4o") && allowed("laptop", "anything"))
    }

    @Test func aKeylessAccountOnAPresetCallsItsEndpointsUnauthenticated() throws {
        let loaded = try parse(#"{ "accounts": { "lan": { "preset": "openai", "endpoints": { "chat": "http://10.0.0.2:8000/v1" } } } }"#)
        #expect(loaded.gateway.registry["lan"]?.endpoints.map(\.auth) == [.none])
        #expect(loaded.warnings.isEmpty)
    }

    @Test func disabledClientsStillRequireAKey() throws {
        let loaded = try parse(#"{ "clients": { "old": { "key": "k", "enabled": false } } }"#, environment: ["UNLADEN_API_KEY": "env"])
        #expect(loaded.gateway.clientKeys.isEmpty)
        #expect(loaded.gateway.disabledClients == ["old"])
        #expect(!loaded.gateway.isOpen)
        #expect(Summary.lines(loaded.gateway).contains("clients: old (disabled)"))
    }

    @Test func emptyFileUsesTheEnvironment() throws {
        let loaded = try parse("", environment: ["DEEPSEEK_API_KEY": "a, b", "UNLADEN_API_KEY": "client"])
        #expect(loaded.server == ServerSettings())
        #expect(loaded.gateway.keyPools["deepseek"]?.keys.map(\.secret) == ["a", "b"])
        #expect(loaded.gateway.keyPools["deepseek"]?.fromEnvironment == true)
        #expect(loaded.gateway.routes.isEmpty)
        #expect(loaded.gateway.clientKeys.map(\.secret) == ["client"])
    }

    @Test func accountsWinOverTheEnvironment() throws {
        let loaded = try parse(#"{ "accounts": { "deepseek": "from-file" } }"#, environment: ["DEEPSEEK_API_KEY": "from-env"])
        #expect(loaded.gateway.keyPools["deepseek"]?.keys.map(\.secret) == ["from-file"])
        #expect(loaded.gateway.keyPools["deepseek"]?.fromEnvironment == false)
        #expect(loaded.hasLiteralSecrets)
    }

    @Test func minimalFile() throws {
        let loaded = try parse(#"{ "accounts": { "anthropic": "${K}" }, "models": { "claude-*": "anthropic" } }"#, environment: ["K": "sk"])
        #expect(try CandidatePlanner(configuration: loaded.gateway).references(for: "claude-opus-4-1") == ["anthropic/claude-opus-4-1"])
        #expect(loaded.warnings.isEmpty)
    }

    @Test func aModelOfAProviderWithoutAccountIsWarnedAbout() throws {
        let loaded = try parse(#"{ "models": { "fast": "deepseek/deepseek-chat" } }"#)
        #expect(loaded.warnings.contains { $0.contains("`fast` goes to deepseek, which has no account") })
    }

    @Test func commandLineOverridesTheFile() throws {
        let overrides = ConfigOverrides(host: "::1", port: 9000, model: "openai/gpt-4o", apiKey: "cli", strict: true, keepalive: 2)
        let loaded = try parse(#"{ "models": { "*": "deepseek/deepseek-chat" } }"#, overrides: overrides)
        #expect(loaded.server.host == "::1")
        #expect(loaded.server.port == 9000)
        #expect(loaded.gateway.routes.catchAll?.targets == [RouteTarget(model: "openai/gpt-4o")])
        #expect(loaded.gateway.strict)
        #expect(loaded.gateway.keepaliveInterval == .seconds(2))
        #expect(loaded.gateway.clientKeys == [ClientKey(name: "command-line", secret: "cli", models: ["*"])])
        #expect(loaded.warnings.contains { $0.contains("--model replaces") })
    }

    @Test func modelOnTheCommandLineIsAMenuEntry() throws {
        // It may name an entry, and the `*` it replaces is not checked.
        let text = #"{ "models": { "fast": "deepseek/deepseek-chat", "*": "nowhere" } }"#
        let loaded = try parse(text, overrides: ConfigOverrides(model: "@fast"))
        #expect(loaded.gateway.routes.catchAll?.targets == [RouteTarget(model: "deepseek/deepseek-chat")])
        let error = #expect(throws: ConfigError.self) { try parse(text, overrides: ConfigOverrides(model: "nowhere")) }
        #expect(error?.message.hasPrefix("--model: unknown provider `nowhere`") == true)
    }

    @Test func unknownFieldsAreRefusedWithTheirPlace() {
        let error = parseError("{\n  \"advanced\": {\n    \"strict\": true,\n    \"stict\": true\n  }\n}")
        #expect(error?.message.contains("advanced.stict: unknown field") == true)
        #expect(error?.location == "config.jsonc:4:14")
        #expect(parseError(#"{ "routes": {} }"#)?.message.contains("unknown field") == true)
    }

    @Test func laterFeaturesAreNamedAsNotSupportedYet() {
        for text in [
            #"{ "models": { "a": ["openai/gpt-4o", "deepseek/deepseek-chat"] } }"#,
            #"{ "models": { "a": { "try": ["openai/gpt-4o"], "budget": { "attempts": 2 } } } }"#,
            #"{ "accounts": { "openai": { "key": "k", "weight": 2 } } }"#,
            #"{ "accounts": { "r": { "endpoints": { "chat": "https://x" }, "profiles": {} } } }"#,
            #"{ "clients": { "a": { "key": "k", "limits": {} } } }"#,
            #"{ "advanced": { "pools": { "openai": "weight" } } }"#,
            #"{ "advanced": { "pools": { "openai": "fastest" } } }"#,
        ] {
            #expect(parseError(text)?.message.contains("not supported yet") == true, "\(text)")
        }
    }

    @Test func aFreeProvidersAccountMayHoldNoKey() throws {
        let loaded = try parse(#"{ "accounts": { "kilo": {}, "free": { "provider": "kilo" }, "off": { "provider": "kilo", "enabled": false } } }"#)
        let keys = try #require(loaded.gateway.keyPools["kilo"]?.keys)
        #expect(keys.map(\.name) == ["kilo", "free"])
        #expect(keys.allSatisfy { $0.apiKey == nil && $0.signIn == nil })
    }

    @Test func invalidValues() {
        #expect(parseError(#"{ "accounts": { "openai": "${NOPE}" } }"#)?.message.contains("NOPE is not set") == true)
        #expect(parseError(#"{ "models": { "a": "nowhere/model" } }"#)?.message.contains("unknown provider `nowhere`") == true)
        #expect(parseError(#"{ "models": { "a": "nowhere" } }"#)?.message.contains("unknown provider `nowhere`") == true)
        #expect(parseError(#"{ "accounts": { "work": "k" } }"#)?.message.contains("not a provider") == true)
        #expect(parseError(#"{ "accounts": { "work": { "provider": "nope", "key": "k" } } }"#)?.message.contains("unknown provider `nope`") == true)
        #expect(parseError(#"{ "accounts": { "work": { "provider": "openai" } } }"#)?.message.contains("`key` is missing") == true)
        // An account named after a provider is that provider's.
        #expect(parseError(#"{ "accounts": { "openai": { "provider": "deepseek", "key": "k" } } }"#)?.message.contains("another name") == true)
        #expect(parseError(#"{ "accounts": { "r": { "provider": "openai", "endpoints": { "chat": "https://x" } } } }"#)?.message.contains("leave `provider` out") == true)
        #expect(parseError(#"{ "accounts": { "r": { "preset": "nope", "endpoints": { "chat": "https://x" } } } }"#)?.message.contains("unknown preset") == true)
        #expect(parseError(#"{ "accounts": { "r": { "endpoints": { "chat": "ftp://x" } } } }"#)?.message.contains("http://") == true)
        #expect(parseError(#"{ "accounts": { "a/b": "k" } }"#)?.message.contains("cannot be empty") == true)
        #expect(parseError(#"{ "accounts": { "openai": "k", "o2": { "provider": "openai", "key": "k" } } }"#)?.message.contains("same key as `openai`") == true)
        #expect(parseError(#"{ "listen": "localhost" }"#)?.message.contains("host:port") == true)
        #expect(parseError(#"{ "panel": { "token": "short" } }"#)?.message.contains("too short") == true)
        #expect(parseError(#"{ "advanced": { "keepalive": "soon" } }"#)?.message.contains("duration") == true)
        #expect(parseError(#"{ "advanced": { "strict": "yes" } }"#)?.message.contains("true or false") == true)
        #expect(parseError(#"{ "advanced": { "pools": { "nope": "rotate" } } }"#)?.message.contains("unknown provider") == true)
        #expect(parseError(#"{ "advanced": { "pools": { "openai": "random" } } }"#)?.message.contains("expected order or rotate") == true)
        #expect(parseError(#"{ "clients": { "a": { "key": "s" }, "b": { "key": "s" } } }"#)?.message.contains("has the key of `a`") == true)
        #expect(parseError(#"{ "clients": { "a": {} } }"#)?.message.contains("`key` is missing") == true)
        #expect(parseError(#"{ "models": { "A": "openai/gpt-4o", "a": "openai/gpt-4o" } }"#)?.message.contains("defined twice") == true)
        #expect(parseError(#"{ "models": [] }"#)?.message.contains("expected an object") == true)
        // References.
        #expect(parseError(#"{ "models": { "a": "@b" } }"#)?.message.contains("names no entry") == true)
        #expect(parseError(#"{ "models": { "a": "@b", "b": "@a" } }"#)?.message.contains("refers back to itself: a → b → a") == true)
        #expect(parseError(#"{ "models": { "a": "@gpt-*", "gpt-*": "openai" } }"#)?.message.contains("names a pattern") == true)
        // Syntax errors carry their place.
        let syntax = parseError("{\n  \"advanced\": [\n")
        #expect(syntax?.message.contains("not valid JSON") == true)
        #expect(syntax?.location == "config.jsonc:3:1")
        #expect(parseError(#"{ "models": {}, "models": {} }"#)?.message.contains("`models` is defined twice") == true)
        #expect(parseError("{ /* open").map { $0.message.contains("not closed") } == true)
    }

    @Test func errorsInsideAnEntryPointAtIt() {
        let error = parseError("{\n  \"models\": {\n    \"a\": \"nowhere/x\"\n  }\n}")
        #expect(error?.message == "models.a: unknown provider `nowhere` (providers: \(ProviderRegistry.builtIn.providers.keys.sorted().joined(separator: ", ")))")
        #expect(error?.location == "config.jsonc:3:10")
    }

    @Test func commentsAndNumbers() throws {
        let loaded = try parse("""
        // Only comments and numbers here.
        {
          "advanced": { "keepalive": 5, "max_request_bytes": 1024, "head_timeout": false, "idle_timeout": "off" }, // trailing
        }
        """)
        #expect(loaded.gateway.keepaliveInterval == .seconds(5))
        #expect(loaded.gateway.maxRequestBytes == 1024)
        #expect(loaded.gateway.headTimeout == nil && loaded.gateway.idleTimeout == nil)
        #expect(try parse("// nothing yet\n/* at all */").gateway.routes.isEmpty)
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

    @Test func clientKeysAreHeldToTheirModels() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        let laptop = ClientKey(name: "laptop", secret: "c-1", models: ["fast", "deepseek/*"])
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
        // The two allowed requests (the model list also asks providers for theirs).
        #expect(upstream.requests.filter { $0.request.method == .post }.count == 2)
    }
}

@Suite struct ReloadTests {
    @Test func replacedConfigurationServesTheNextRequests() async throws {
        let upstream = MockUpstream { _ in reply(fixture("Chat/responses/text.json")) }
        let gateway = makeGateway(upstream, model: "deepseek/deepseek-chat")
        try await makeApp(gateway).test(.router) { client in
            var response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.headers[Gateway.modelHeader] == "deepseek/deepseek-chat")

            let loaded = try ConfigFile.parse(#"{ "models": { "*": "together/llama-3.3-70b" } }"#) { $0 == "TOGETHER_API_KEY" ? "t" : nil }
            gateway.replace(loaded.gateway)
            response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(response.headers[Gateway.modelHeader] == "together/llama-3.3-70b")
        }
        #expect(upstream.requests.last?.header("authorization") == "Bearer t")
    }

    @Test func healthFollowsKeyNamesAndResetsWhenASecretChanges() {
        let upstream = MockUpstream { _ in reply("{}") }
        var configuration = GatewayConfiguration()
        configuration.keyPools = ["deepseek": KeyPool(keys: [UpstreamKey(name: "a", secret: "s1"), UpstreamKey(name: "b", secret: "s2")])]
        let gateway = Gateway(configuration: configuration, transport: upstream.transport)
        let a = HealthScope.key(provider: "deepseek", keyName: "a")
        let b = HealthScope.key(provider: "deepseek", keyName: "b")
        gateway.health.recordFailure(a, base: .seconds(60))
        gateway.health.recordFailure(b, base: .seconds(60))

        // `a` keeps its secret and moves; `b` gets a new one.
        configuration.keyPools = ["deepseek": KeyPool(keys: [UpstreamKey(name: "b", secret: "s3"), UpstreamKey(name: "a", secret: "s1")])]
        gateway.replace(configuration)
        let health = gateway.health.snapshot()
        #expect(health.isCooling(a))
        #expect(!health.isCooling(b))

        // `a` is removed, then added back: it starts afresh.
        configuration.keyPools = ["deepseek": KeyPool(keys: [UpstreamKey(name: "b", secret: "s3")])]
        gateway.replace(configuration)
        configuration.keyPools = ["deepseek": KeyPool(keys: [UpstreamKey(name: "b", secret: "s3"), UpstreamKey(name: "a", secret: "s1")])]
        gateway.replace(configuration)
        #expect(!gateway.health.snapshot().isCooling(a))
    }
}
