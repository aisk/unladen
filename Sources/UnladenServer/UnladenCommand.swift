// The `unladen` command: a protocol-translating LLM gateway configured by a
// file, flags and environment variables.

import ArgumentParser
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import AsyncHTTPClient
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Hummingbird
import Logging
import NIOCore
import UnladenAsyncHTTPClient
@_spi(Wire) import UnladenCore

@main
struct UnladenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unladen",
        abstract: "A lightweight LLM protocol-translating gateway.",
        subcommands: [Serve.self, CheckConfig.self, SignIn.self],
        defaultSubcommand: Serve.self,
    )

    /// The warning for listening on `host` with no client configured, or
    /// `nil` when `host` is a loopback address or a client is.
    static func exposureWarning(host: String, open: Bool) -> String? {
        guard open, !isLoopback(host) else { return nil }
        return """

        ************************************************************************
        WARNING: unladen is listening on \(host) without a client key.
        Anyone who can reach this address can use the upstream API keys it
        holds. Configure clients or set --api-key (or UNLADEN_API_KEY),
        or listen on 127.0.0.1.
        ************************************************************************

        """
    }

    /// `localhost`, `127.0.0.0/8` and `::1` (bracketed or not).
    static func isLoopback(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name == "localhost" || name == "::1" || name == "0:0:0:0:0:0:0:1" { return true }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    static func printToStandardError(_ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(2, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}

/// Options shared by `serve` and `check-config`.
struct ConfigOptions: ParsableArguments {
    @Option(help: "Configuration file (JSON; comments and trailing commas allowed). Default: $XDG_CONFIG_HOME/unladen/config.jsonc when it exists.")
    var config: String?

    @Option(help: "Address to listen on (overrides listen).")
    var host: String?

    @Option(help: "Port to listen on (overrides listen).")
    var port: Int?

    @Option(help: "The `*` entry of models: provider, provider/model or @name, for every model name the menu does not list.")
    var model: String?

    @Option(name: .customLong("api-key"), help: "A client key allowed every model name. Also UNLADEN_API_KEY when the file has no clients.")
    var apiKey: String?

    @Flag(help: "Refuse to forward a request that would lose something (content or fields the target cannot carry, lossy conversions). Parameters a model's profile declares it does not take are left out and only reported.")
    var strict = false

    @Option(name: .customLong("connect-timeout"), help: "Upstream connect timeout, in seconds.")
    var connectTimeout: Int?

    @Option(help: "Seconds of upstream silence after which a streaming client is sent a keepalive.")
    var keepalive: Int?

    func validate() throws {
        if let port, !(1...65535).contains(port) { throw ValidationError("--port must be 1...65535") }
        if let connectTimeout, connectTimeout <= 0 { throw ValidationError("--connect-timeout must be positive") }
        if let keepalive, keepalive <= 0 { throw ValidationError("--keepalive must be positive") }
    }

    var overrides: ConfigOverrides {
        ConfigOverrides(
            host: host, port: port, model: model, apiKey: apiKey.flatMap { $0.isEmpty ? nil : $0 }, strict: strict,
            connectTimeout: connectTimeout, keepalive: keepalive,
        )
    }

    func load() throws -> LoadedConfiguration {
        // A ConfigError prints as itself, without the usage text.
        try ConfigLoader.load(path: config, overrides: overrides)
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the gateway (the default).",
        discussion: """
        Serves OpenAI Chat Completions (/v1/chat/completions), OpenAI Responses \
        (/v1/responses), Anthropic Messages (/v1/messages) and Gemini \
        (/v1beta/models/{model}:generateContent, :streamGenerateContent) and \
        translates each to whatever protocol the chosen upstream speaks.

        Models: a client model name is looked up in the configuration's menu \
        (exact names, then patterns such as claude-*); else a provider/model \
        reference (e.g. deepseek/deepseek-chat) is used as is; else the `*` \
        entry (--model) serves it. When an account fails (rate limit, server \
        error, refused key), the provider's next account is tried; the \
        gateway never switches to another provider or model by itself.

        Upstream keys come from the configuration file's accounts, else the environment: \
        UNLADEN_<PROVIDER>_API_KEY, else the provider's usual variable \
        (OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, DEEPSEEK_API_KEY, ...). \
        Several comma-separated keys form a pool. Providers: \(ProviderRegistry.builtIn.providers.keys.sorted().joined(separator: ", ")). \
        Log level: LOG_LEVEL (trace, debug, info, ...).

        Client keys: clients present one as a Bearer token, x-api-key or \
        x-goog-api-key, or ?key= on Gemini routes. Listening on a non-loopback \
        address without one prints a warning.

        Disconnects: a client that closes its connection, or half-closes it \
        (shuts down its sending side), is treated as gone and its upstream \
        request is cancelled, even before the response has started. Clients \
        must keep their side open until the response is complete.
        """,
    )

    @OptionGroup var options: ConfigOptions

    func run() async throws {
        // Checked before anything is started, so a mistyped level stops here.
        var logLevel = Logger.Level.info
        if let level = ProcessInfo.processInfo.environment["LOG_LEVEL"], !level.isEmpty {
            guard let parsed = Logger.Level(rawValue: level.lowercased()) else {
                throw ValidationError("LOG_LEVEL: \(level) is none of trace, debug, info, notice, warning, error, critical")
            }
            logLevel = parsed
        }
        let loaded = try options.load()
        let server = loaded.server
        var clientConfiguration = HTTPClient.Configuration()
        clientConfiguration.timeout = .init(connect: .nanoseconds(Int64(server.connectTimeout / .nanoseconds(1))), read: nil)
        // A redirect to another host would carry `x-api-key` and
        // `x-goog-api-key` there (only `Authorization` is dropped): an API
        // that redirects answers with the redirect instead.
        clientConfiguration.redirectConfiguration = .disallow
        let client = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup, configuration: clientConfiguration)

        var logger = Logger(label: "unladen")
        logger.logLevel = logLevel
        var gateway = Gateway(configuration: loaded.gateway, transport: AsyncHTTPClientTransport(client: client))
        // Usage and sign-ins are kept across restarts in the state directory.
        let stateDirectory = UsageLog.defaultDirectory { ProcessInfo.processInfo.environment[$0] }
        let usageLog = stateDirectory.map(UsageLog.init(directory:))
        gateway.signIns = SignIns(directory: stateDirectory)
        let usageLogger = logger
        gateway.activity = Activity(log: usageLog) { usageLogger.warning("\($0)") }
        gateway.activity.restore()
        // Reloads (SIGHUP, the control panel) and the panel's saves.
        let manager = ConfigManager(
            path: loaded.path ?? options.config, overrides: options.overrides, server: server, gateway: gateway, logger: logger,
        )
        let app = Application(
            router: buildRouter(gateway: gateway, manager: manager),
            configuration: .init(address: .hostname(server.host, port: server.port), serverName: "unladen"),
            logger: logger,
        )
        if let warning = UnladenCommand.exposureWarning(host: server.host, open: loaded.gateway.isOpen) {
            UnladenCommand.printToStandardError(warning)
        }
        app.logger.info("configuration: \(loaded.path ?? "none (flags and environment only)")")
        app.logger.info("usage log: \(usageLog.map { $0.directory } ?? "off (no HOME or XDG_STATE_HOME)")")
        for warning in loaded.warnings { app.logger.warning("\(warning)") }
        for line in Summary.lines(loaded.gateway) { app.logger.info("\(line)") }

        // SIGHUP: read the configuration again and install it.
        signal(SIGHUP, SIG_IGN)
        let hangup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .global())
        hangup.setEventHandler { manager.reload() }
        hangup.resume()
        defer { hangup.cancel() }

        do {
            try await app.runService()
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }
}

struct SignIn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign-in",
        abstract: "Sign an account in (of provider `chatgpt` or `antigravity`), keeping its tokens in the state directory.",
        discussion: """
        Prints an address to open in a browser, on any computer. After \
        signing in there, the browser is sent to a loopback address that \
        does not load: copy that address and paste it here. A running \
        gateway picks the sign-in up on its next reload (SIGHUP, or the \
        control panel's Reload); the control panel can also sign accounts \
        in itself.
        """,
    )

    @Argument(help: "The account, as named under accounts in the configuration.")
    var account: String

    @OptionGroup var options: ConfigOptions

    func run() async throws {
        let loaded = try options.load()
        guard let (provider, key) = loaded.gateway.keyPools.lazy.compactMap({ provider, pool in
            pool.keys.first { $0.name == account }.map { (provider, $0) }
        }).first, key.signIn != nil else {
            throw ValidationError("`\(account)` is not an enabled account that signs in (an account of provider `chatgpt` or `antigravity` without a key)")
        }
        guard let directory = UsageLog.defaultDirectory(environment: { ProcessInfo.processInfo.environment[$0] }) else {
            throw ValidationError("no state directory: set HOME or XDG_STATE_HOME")
        }
        let signIns = SignIns(directory: directory)
        if key.signIn == .antigravity {
            print("Warning: Google does not offer Antigravity's sign-in to other apps, and may suspend an account it sees used outside Antigravity. Use one you can afford to lose, at your own risk.\n")
        }
        let started = try signIns.start(provider: provider, account: account)
        print("Open this address in a browser and sign in:\n\n\(started.url)\n")
        print("Then paste the address the browser ends on (\(started.redirect)?…):")
        guard let callback = readLine(strippingNewline: true), !callback.isEmpty else {
            throw ValidationError("no address given")
        }
        var clientConfiguration = HTTPClient.Configuration()
        clientConfiguration.timeout = .init(connect: .nanoseconds(Int64(loaded.server.connectTimeout / .nanoseconds(1))), read: nil)
        clientConfiguration.redirectConfiguration = .disallow
        let client = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup, configuration: clientConfiguration)
        let result: Result<SignInCredentials, SignInError>
        do throws(SignInError) {
            result = .success(try await signIns.finish(id: started.id, callback: callback, transport: AsyncHTTPClientTransport(client: client)).credentials)
        } catch {
            result = .failure(error)
        }
        try await client.shutdown()
        let credentials = try result.get()
        print("Signed in as \(credentials.user)\(credentials.plan.map { " (\($0))" } ?? "") into \(provider)/\(account).")
        print("A running gateway uses it after a reload (SIGHUP, or Reload in the control panel).")
    }
}

struct CheckConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-config",
        abstract: "Load and check the configuration, print what it serves, and exit.",
    )

    @OptionGroup var options: ConfigOptions

    func run() throws {
        let loaded = try options.load()
        print("configuration: \(loaded.path ?? "none (flags and environment only)")")
        print("listen: \(loaded.server.host):\(loaded.server.port)")
        for line in Summary.lines(loaded.gateway) { print(line) }
        for warning in loaded.warnings { print("warning: \(warning)") }
    }
}

/// What a configuration serves, without secrets.
enum Summary {
    static func lines(_ configuration: GatewayConfiguration) -> [String] {
        var lines: [String] = []
        let pools = configuration.keyPools.sorted { $0.key < $1.key }
        lines.append("accounts: " + (pools.isEmpty ? "none" : pools.map { id, pool in
            let names = pool.fromEnvironment ? "\(pool.keys.count) from the environment" : pool.keys.map(\.name).joined(separator: ", ")
            return "\(id) [\(names)\(pool.strategy == .order ? "" : ", \(pool.strategy.rawValue)")]"
        }.joined(separator: "; ")))
        let routes = configuration.routes.all
        lines.append("models: " + (routes.isEmpty ? "none" : routes.map { route in
            "\(route.name) → \(route.targets.map(\.model).joined(separator: ", "))"
        }.joined(separator: "; ")))
        let clients = configuration.clientKeys.map(\.name) + configuration.disabledClients.map { "\($0) (disabled)" }
        lines.append("clients: " + (clients.isEmpty ? "none" : clients.joined(separator: ", ")))
        lines.append("control panel: " + (configuration.adminToken == nil ? "off (set panel.token)" : "/admin"))
        return lines
    }
}
