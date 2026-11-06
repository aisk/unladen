// The `unladen` command: a protocol-translating LLM gateway configured by
// flags and environment variables.

import ArgumentParser
import AsyncHTTPClient
import Hummingbird
import NIOCore
import UnladenAsyncHTTPClient
@_spi(Wire) import UnladenCore

@main
struct UnladenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unladen",
        abstract: "A lightweight LLM protocol-translating gateway.",
        discussion: """
        Serves OpenAI Chat Completions (/v1/chat/completions), OpenAI Responses \
        (/v1/responses), Anthropic Messages (/v1/messages) and Gemini \
        (/v1beta/models/{model}:generateContent, :streamGenerateContent) and \
        translates each to whatever protocol the chosen upstream speaks.

        Models: a client model string of the form provider/model (e.g. \
        deepseek/deepseek-chat) is used as is; anything else (claude-sonnet-4-5, \
        gpt-4o) is served by --model. --fallback models are tried, in order, \
        when the first fails with a rate limit, server error or connection error.

        Upstream keys come from the environment: UNLADEN_<PROVIDER>_API_KEY, \
        else the provider's usual variable (OPENAI_API_KEY, ANTHROPIC_API_KEY, \
        GEMINI_API_KEY, DEEPSEEK_API_KEY, ...). Several comma-separated keys \
        rotate per request. Providers: \(ProviderRegistry.builtIn.providers.keys.sorted().joined(separator: ", ")). \
        Log level: LOG_LEVEL (trace, debug, info, ...).
        """,
    )

    @Option(help: "Address to listen on.")
    var host = "127.0.0.1"

    @Option(help: "Port to listen on.")
    var port = 4141

    @Option(help: "Default model (provider/model) for client model strings that are not a provider/model reference.")
    var model: String?

    @Option(name: .customLong("fallback"), help: "Fallback model (provider/model), tried in order; repeatable.")
    var fallbacks: [String] = []

    @Option(name: .customLong("api-key"), help: "Key clients must present (Bearer, x-api-key or x-goog-api-key). Also UNLADEN_API_KEY.")
    var apiKey: String?

    @Flag(help: "Reject requests that cannot be translated exactly (that produce warnings) instead of forwarding them.")
    var strict = false

    @Option(name: .customLong("connect-timeout"), help: "Upstream connect timeout, in seconds.")
    var connectTimeout = 10

    @Option(help: "Seconds of upstream silence after which a streaming client is sent a keepalive.")
    var keepalive = 15

    func validate() throws {
        let registry = ProviderRegistry.builtIn
        for reference in [model].compactMap({ $0 }) + fallbacks {
            do {
                _ = try registry.resolve(reference)
            } catch {
                throw ValidationError("cannot use model `\(reference)`: \(error) (expected provider/model, providers: \(registry.providers.keys.sorted().joined(separator: ", ")))")
            }
        }
        guard (1...65535).contains(port) else { throw ValidationError("--port must be 1...65535") }
        guard connectTimeout > 0, keepalive > 0 else { throw ValidationError("timeouts must be positive") }
    }

    func run() async throws {
        let environment = Environment()
        var configuration = GatewayConfiguration()
        configuration.defaultModel = model
        configuration.fallbacks = fallbacks
        configuration.apiKey = apiKey ?? environment.get("UNLADEN_API_KEY").flatMap { $0.isEmpty ? nil : $0 }
        configuration.strict = strict
        configuration.keepaliveInterval = .seconds(keepalive)
        configuration.upstreamKeys = UpstreamKeys.load(for: configuration.registry) { environment.get($0) }

        var clientConfiguration = HTTPClient.Configuration()
        clientConfiguration.timeout = .init(connect: .seconds(Int64(connectTimeout)), read: nil)
        let client = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup, configuration: clientConfiguration)

        let gateway = Gateway(configuration: configuration, transport: AsyncHTTPClientTransport(client: client))
        let app = Application(
            router: buildRouter(gateway: gateway),
            configuration: .init(address: .hostname(host, port: port), serverName: "unladen"),
        )
        app.logger.info("models: default \(model ?? "none"), fallbacks \(fallbacks.isEmpty ? "none" : fallbacks.joined(separator: ", "))")
        app.logger.info("upstream keys for: \(configuration.upstreamKeys.keys.sorted().joined(separator: ", "))")
        do {
            try await app.runService()
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }
}
