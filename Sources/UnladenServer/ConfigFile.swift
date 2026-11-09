// The configuration file: JSON with comments and trailing commas (JSONC),
// decoded field by field so that unknown fields are refused and errors carry
// a line and column.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
@_spi(Wire) import UnladenCore

/// Settings that only take effect at start (the listener, the HTTP client).
struct ServerSettings: Sendable, Hashable {
    var host = "127.0.0.1"
    var port = 4141
    var connectTimeout: Duration = .seconds(10)
}

/// A configuration ready to serve, and what is worth telling about it.
struct LoadedConfiguration: Sendable {
    var server = ServerSettings()
    var gateway = GatewayConfiguration()
    /// Where it came from; `nil` without a file.
    var path: String?
    var warnings: [String] = []
    /// A key or secret is written out in the file, not as `${VAR}`.
    var hasLiteralSecrets = false
}

/// A configuration that cannot be used.
struct ConfigError: Error, CustomStringConvertible, Equatable {
    var message: String
    /// `file:line:column`, when the error is about one place in the file.
    var location: String?

    var description: String { location.map { "\($0): \(message)" } ?? message }
}

/// What the command line sets; each one wins over the file.
struct ConfigOverrides: Sendable {
    var host: String?
    var port: Int?
    /// Becomes the `*` entry of the menu.
    var model: String?
    /// A client key allowed every model name.
    var apiKey: String?
    var strict = false
    var connectTimeout: Int?
    var keepalive: Int?
}

enum ConfigLoader {
    /// `$XDG_CONFIG_HOME/unladen/config.jsonc`, or under `~/.config`.
    static func defaultPath(environment: (String) -> String?) -> String? {
        if let xdg = environment("XDG_CONFIG_HOME"), !xdg.isEmpty { return xdg + "/unladen/config.jsonc" }
        if let home = environment("HOME"), !home.isEmpty { return home + "/.config/unladen/config.jsonc" }
        return nil
    }

    /// Reads the file at `path` (else the default path, when it exists),
    /// then applies `overrides` and the environment. A missing default
    /// file is no error; a missing `path` is.
    static func load(
        path: String?, overrides: ConfigOverrides = ConfigOverrides(),
        environment: @escaping (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
    ) throws(ConfigError) -> LoadedConfiguration {
        var file = path
        if file == nil, let candidate = defaultPath(environment: environment), FileManager.default.fileExists(atPath: candidate) {
            file = candidate
        }
        var text = ""
        if let file {
            guard let data = FileManager.default.contents(atPath: file) else {
                throw ConfigError(message: "cannot read the configuration file \(file)")
            }
            text = String(decoding: data, as: UTF8.self)
        }
        var loaded = try ConfigFile.parse(text, file: file ?? "", overrides: overrides, environment: environment)
        loaded.path = file
        if let file, loaded.hasLiteralSecrets,
           let permissions = (try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] as? Int,
           permissions & 0o077 != 0
        {
            loaded.warnings.append(
                "\(file) holds keys in plain text and is readable by other users; chmod 600 it, or use ${VAR} references",
            )
        }
        return loaded
    }
}

enum ConfigFile {
    static let sections: Set<String> = ["listen", "panel", "accounts", "models", "clients", "advanced"]

    static func parse(
        _ text: String, file: String = "config", overrides: ConfigOverrides = ConfigOverrides(),
        environment: @escaping (String) -> String?,
    ) throws(ConfigError) -> LoadedConfiguration {
        let (root, locator) = try parseJSON(text, file: file)
        var parser = Parser(file: file, environment: environment, locator: locator)
        var loaded = LoadedConfiguration()
        var fileKeys: [String: [UpstreamKey]] = [:]
        var pools: [String: KeyPool.Strategy] = [:]
        var menu: [Parser.MenuEntry] = []
        var clientKeys: [ClientKey]?
        var disabledClients: [String] = []

        if !root.isNull {
            var fields: [String: Field] = [:]
            for (name, field) in try Field(value: root, keys: [], parser: parser).mapping(allowed: sections) { fields[name] = field }
            if let field = fields["listen"] { try parser.listen(field, into: &loaded.server) }
            if let field = fields["panel"] { loaded.gateway.adminToken = try parser.panel(field) }
            // Accounts first: they define the providers the rest names.
            if let field = fields["accounts"] { fileKeys = try parser.accounts(field, into: &loaded.gateway.registry) }
            if let field = fields["advanced"] { pools = try parser.advanced(field, into: &loaded) }
            if let field = fields["models"] { menu = try parser.menu(field) }
            if let field = fields["clients"] { (clientKeys, disabledClients) = try parser.clients(field) }
        }

        // Key pools: the file's accounts, else the environment's keys.
        let registry = loaded.gateway.registry
        for id in registry.providers.keys {
            let keys = fileKeys[id] ?? UpstreamKeys.load(for: id, in: registry, environment: environment)
            if !keys.isEmpty {
                loaded.gateway.keyPools[id] = KeyPool(keys: keys, strategy: pools[id] ?? .order, fromEnvironment: fileKeys[id] == nil)
            }
        }

        // Command line overrides.
        if let host = overrides.host { loaded.server.host = host }
        if let port = overrides.port { loaded.server.port = port }
        if let seconds = overrides.connectTimeout { loaded.server.connectTimeout = .seconds(seconds) }
        if let seconds = overrides.keepalive { loaded.gateway.keepaliveInterval = .seconds(seconds) }
        if overrides.strict { loaded.gateway.strict = true }
        if let apiKey = overrides.apiKey {
            clientKeys = (clientKeys ?? []) + [ClientKey(name: "command-line", secret: apiKey, models: ["*"])]
        } else if clientKeys == nil, let apiKey = environment("UNLADEN_API_KEY"), !apiKey.isEmpty {
            clientKeys = [ClientKey(name: "UNLADEN_API_KEY", secret: apiKey, models: ["*"])]
        }
        loaded.gateway.clientKeys = clientKeys ?? []
        loaded.gateway.disabledClients = disabledClients

        // The menu, checked against the final registry; --model is its
        // `*` entry.
        if let model = overrides.model {
            if menu.contains(where: { $0.name == "*" }) {
                loaded.warnings.append("--model replaces the `*` entry of models")
            }
            menu.removeAll { $0.name == "*" }
            menu.append(Parser.MenuEntry(name: "*", target: model.trimmingBlanks(), field: nil))
        }
        let routes = try parser.routes(menu, registry: registry)
        for route in routes {
            if route.name == "*" {
                loaded.warnings.append("models: `*` serves every model name no other entry matches: such requests are answered by \(route.targets.map(\.model).joined(separator: ", "))")
            } else if let (provider, _) = try? ProviderRegistry.parse(route.name), registry[provider] != nil {
                loaded.warnings.append("models: `\(route.name)` takes the place of the provider/model reference of the same name")
            }
            for target in route.targets {
                guard let (provider, _) = try? ProviderRegistry.parse(target.probe),
                      loaded.gateway.keyPools[provider] == nil,
                      registry[provider]?.endpoints.contains(where: { $0.auth != .none }) == true
                else { continue }
                let variables = UpstreamKeys.variables(for: provider, in: registry).joined(separator: " or ")
                loaded.warnings.append("models: `\(route.name)` goes to \(provider), which has no account (add one to accounts, or set \(variables))")
            }
        }
        loaded.gateway.routes = RouteTable(routes)
        loaded.hasLiteralSecrets = parser.literalSecrets
        return loaded
    }

    /// A target must name a known provider; without `$model`, a model it
    /// can resolve. The error is the message alone.
    static func check(_ target: RouteTarget, registry: ProviderRegistry) throws(ConfigError) {
        do {
            let (provider, _) = try ProviderRegistry.parse(target.probe)
            guard registry[provider] != nil else {
                throw ConfigError(message: "unknown provider `\(provider)` (providers: \(registry.providers.keys.sorted().joined(separator: ", ")))")
            }
            if !target.model.contains("$model") { _ = try registry.resolve(target.model) }
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError(message: "cannot use `\(target.model)`: \(error) (expected a provider, provider/model, or @name)")
        }
    }
}

// MARK: - JSONC

extension ConfigFile {
    /// The file's value (`null` when it holds nothing but whitespace and
    /// comments) and where its values are.
    static func parseJSON(_ text: String, file: String) throws(ConfigError) -> (value: JSONValue, locator: Locator) {
        let bytes = Array(text.utf8)
        do {
            let (value, offsets) = try JSONParser.parseWithOffsets(bytes, options: .jsonc)
            return (value, Locator(bytes: bytes, offsets: offsets))
        } catch {
            // Nothing but whitespace and comments: an empty configuration.
            if error.kind == .unexpectedEndOfInput, (try? JSONParser.parse(bytes + Array("\nnull".utf8), options: .jsonc)) != nil {
                return (.null, Locator(bytes: bytes, offsets: [:]))
            }
            let (line, column) = Locator(bytes: bytes, offsets: [:]).lineAndColumn(of: error.offset)
            let reason: String = switch error.kind {
            case .unexpectedEndOfInput: "the file ends too early"
            case .unexpectedByte(let byte): "unexpected \(Unicode.Scalar(byte).escaped(asASCII: true))"
            case .duplicateKey(let key): "`\(key)` is defined twice"
            case .unterminatedComment: "a /* comment is not closed"
            default: "\(error.kind)"
            }
            throw ConfigError(message: "not valid JSON: \(reason)", location: file.isEmpty ? nil : "\(file):\(line):\(column)")
        }
    }

    /// Turns paths into lines and columns (1-based; columns count bytes).
    struct Locator: Sendable {
        var lineStarts: [Int] = [0]
        var offsets: JSONParser.Offsets

        init(bytes: [UInt8], offsets: JSONParser.Offsets) {
            for (index, byte) in bytes.enumerated() where byte == 0x0A { lineStarts.append(index + 1) }
            self.offsets = offsets
        }

        func lineAndColumn(of offset: Int) -> (Int, Int) {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return (low + 1, offset - lineStarts[low] + 1)
        }

        func location(of path: [String]) -> (Int, Int)? {
            offsets[path].map(lineAndColumn(of:))
        }
    }
}

// MARK: - Value reading

/// One value of the file and its path, for error messages.
private struct Field {
    var value: JSONValue
    var keys: [String]
    var parser: ConfigFile.Parser

    var path: String { keys.joined(separator: ".") }

    /// A string, number or boolean.
    var isScalar: Bool {
        switch value {
        case .string, .number, .bool: true
        default: false
        }
    }

    func error(_ message: String) -> ConfigError {
        let location = parser.locator.location(of: keys).map { "\(parser.file):\($0.0):\($0.1)" }
        return ConfigError(message: keys.isEmpty ? message : "\(path): \(message)", location: parser.file.isEmpty ? nil : location)
    }

    func child(_ key: String, _ value: JSONValue) -> Field {
        Field(value: value, keys: keys + [key], parser: parser)
    }

    /// The entries of a mapping, in file order, refusing keys not in
    /// `allowed` (any key when `nil`) and naming the `reserved` ones as
    /// not supported yet.
    func mapping(allowed: Set<String>? = nil, reserved: Set<String> = []) throws(ConfigError) -> [(String, Field)] {
        guard let object = value.objectValue else { throw error("expected an object") }
        var entries: [(String, Field)] = []
        var seen: Set<String> = []
        for (key, value) in object {
            let field = child(key, value)
            if reserved.contains(key) { throw field.error("not supported yet") }
            if let allowed, !allowed.contains(key) {
                throw field.error("unknown field (expected one of: \(allowed.sorted().joined(separator: ", ")))")
            }
            guard seen.insert(key).inserted else { throw field.error("defined twice") }
            entries.append((key, field))
        }
        return entries
    }

    func sequence() throws(ConfigError) -> [Field] {
        guard let items = value.arrayValue else { throw error("expected a list") }
        return items.enumerated().map { child("\($0.offset)", $0.element) }
    }

    /// A string (or a number, as written), without `${VAR}` expansion.
    func rawString() throws(ConfigError) -> String {
        switch value {
        case .string(let text): return text
        case .number(let number): return number.description
        default: throw error("expected a string")
        }
    }

    /// A scalar, `${VAR}` expanded from the environment.
    func string() throws(ConfigError) -> String {
        let raw = try rawString()
        do {
            return try Interpolation.expand(raw, environment: parser.environment)
        } catch {
            throw self.error(error.message)
        }
    }

    func bool() throws(ConfigError) -> Bool {
        guard let flag = value.boolValue else { throw error("expected true or false") }
        return flag
    }

    func stringList() throws(ConfigError) -> [String] {
        if isScalar { return [try string()] }
        var values: [String] = []
        for item in try sequence() { values.append(try item.string()) }
        return values
    }

    func duration() throws(ConfigError) -> Duration {
        guard let duration = try duration(allowingOff: false) else { throw error("expected a duration") }
        return duration
    }

    /// A duration; `off` is `nil` when `allowingOff`.
    func duration(allowingOff: Bool) throws(ConfigError) -> Duration? {
        if allowingOff, value == .bool(false) { return nil }
        let text = try string().trimmingBlanks()
        if allowingOff, text == "off" { return nil }
        let units: [(String, Int64)] = [("ms", 1), ("s", 1000), ("m", 60_000), ("h", 3_600_000)]
        if let seconds = Int64(text), seconds > 0 { return .seconds(seconds) }
        for (unit, milliseconds) in units where text.hasSuffix(unit) {
            if let value = Int64(text.dropLast(unit.count)), value > 0 { return .milliseconds(value * milliseconds) }
        }
        throw error("expected a positive duration such as 500ms, 15s, 2m or 1h\(allowingOff ? ", or off" : "")")
    }

    func byteCount() throws(ConfigError) -> Int {
        let text = try string().trimmingBlanks()
        let units: [(String, Int)] = [("KiB", 1 << 10), ("MiB", 1 << 20), ("GiB", 1 << 30), ("KB", 1000), ("MB", 1_000_000), ("GB", 1_000_000_000)]
        if let value = Int(text), value > 0 { return value }
        for (unit, factor) in units where text.hasSuffix(unit) {
            if let value = Int(text.dropLast(unit.count).trimmingBlanks()), value > 0 { return value * factor }
        }
        throw error("expected a positive size such as 65536, 512KiB or 64MiB")
    }
}

/// `${NAME}` in string values, from the environment.
enum Interpolation {
    struct Failure: Error { var message: String }

    static func expand(_ text: String, environment: (String) -> String?) throws(Failure) -> String {
        guard text.contains("${") else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.firstRange(of: "${") {
            result += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "}") else { throw Failure(message: "unterminated ${ in `\(text)`") }
            let name = String(after[..<end])
            guard let first = name.first, first == "_" || (first.isASCII && first.isLetter),
                  name.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) })
            else { throw Failure(message: "`${\(name)}` is not an environment variable name") }
            guard let value = environment(name) else { throw Failure(message: "environment variable \(name) is not set") }
            result += value
            rest = after[after.index(after: end)...]
        }
        return result + rest
    }
}

// MARK: - Sections

extension ConfigFile {
    fileprivate struct Parser {
        var file: String
        var environment: (String) -> String?
        var locator: ConfigFile.Locator
        var literalSecrets = false

        /// A secret: expanded, never empty; notes one written in plain text.
        mutating func secret(_ field: Field) throws(ConfigError) -> String {
            let raw = try field.rawString()
            if !raw.contains("${") { literalSecrets = true }
            let value = try field.string()
            guard !value.isEmpty else { throw field.error("is empty") }
            return value
        }

        // MARK: Gateway

        func listen(_ field: Field, into server: inout ServerSettings) throws(ConfigError) {
            let text = try field.string()
            guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
                  (1...65535).contains(port)
            else { throw field.error("expected host:port, such as 127.0.0.1:4141 or [::1]:4141") }
            var host = String(text[..<colon])
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            guard !host.isEmpty else { throw field.error("the host is missing (0.0.0.0 listens everywhere)") }
            server.host = host
            server.port = port
        }

        mutating func panel(_ field: Field) throws(ConfigError) -> String? {
            var token: String?
            for (_, setting) in try field.mapping(allowed: ["token"]) {
                let value = try secret(setting)
                guard value.count >= 16 else { throw setting.error("is too short: use at least 16 characters") }
                token = value
            }
            return token
        }

        /// The key pools' orders, by provider.
        func advanced(_ field: Field, into loaded: inout LoadedConfiguration) throws(ConfigError) -> [String: KeyPool.Strategy] {
            var pools: [String: KeyPool.Strategy] = [:]
            for (name, value) in try field.mapping(
                allowed: ["strict", "keepalive", "connect_timeout", "max_request_bytes", "head_timeout", "idle_timeout", "pools"],
            ) {
                switch name {
                case "strict": loaded.gateway.strict = try value.bool()
                case "keepalive": loaded.gateway.keepaliveInterval = try value.duration()
                case "connect_timeout": loaded.server.connectTimeout = try value.duration()
                case "max_request_bytes": loaded.gateway.maxRequestBytes = try value.byteCount()
                case "head_timeout": loaded.gateway.headTimeout = try value.duration(allowingOff: true)
                case "idle_timeout": loaded.gateway.idleTimeout = try value.duration(allowingOff: true)
                case "pools":
                    for (provider, pick) in try value.mapping() {
                        guard loaded.gateway.registry[provider] != nil else {
                            throw pick.error("unknown provider `\(provider)`")
                        }
                        pools[provider] = try Self.pick(pick)
                    }
                default: break
                }
            }
            return pools
        }

        /// The order within one tier. Only `order` and `rotate` exist yet;
        /// the others are the names later versions give their orders.
        static let laterPicks: Set<String> = ["weight", "fastest", "cheapest", "least_used", "quota"]

        static func pick(_ field: Field) throws(ConfigError) -> KeyPool.Strategy {
            let text = try field.string()
            if laterPicks.contains(text) { throw field.error("`\(text)` is not supported yet (expected order or rotate)") }
            guard let strategy = KeyPool.Strategy(rawValue: text) else { throw field.error("expected order or rotate") }
            return strategy
        }

        // MARK: Accounts

        struct Account {
            var name: String
            var provider: String
            /// Where the provider is named, for errors.
            var providerField: Field
            var key: String?
            var enabled: Bool
        }

        /// What an account gives of its own provider.
        struct ProviderParts {
            var preset: String?
            var endpoints: [(APIProtocol, String)]?
            var headers: [String: String] = [:]
            var given = false
        }

        /// Registers the providers accounts define; returns the keys of
        /// every provider an account gives a key, in file order.
        mutating func accounts(_ field: Field, into registry: inout ProviderRegistry) throws(ConfigError) -> [String: [UpstreamKey]] {
            var accounts: [Account] = []
            var definitions: [(String, Field, ProviderParts)] = []
            for (name, value) in try field.mapping() {
                guard !name.isEmpty, !name.hasPrefix("@"), !name.contains("/"), !name.contains("*") else {
                    throw value.error("an account name cannot be empty, start with @, or contain / or *")
                }
                if value.isScalar {
                    if let kind = SignInKind.of(provider: name), !kind.takesKeys {
                        throw value.error("`\(name)` accounts sign in and hold no key: write `\"\(name)\": {}` and sign in from the control panel")
                    }
                    guard registry[name] != nil else {
                        throw value.error("`\(name)` is not a provider: write { \"provider\": \"…\", \"key\": \"…\" }, or give the account its `endpoints`")
                    }
                    accounts.append(Account(name: name, provider: name, providerField: value, key: try secret(value), enabled: true))
                    continue
                }
                var provider: (String, Field)?
                var key: String?
                var enabled = true
                var parts = ProviderParts()
                for (setting, item) in try value.mapping(
                    allowed: ["provider", "key", "enabled", "preset", "endpoints", "headers"],
                    reserved: ["weight", "protocols", "profiles"],
                ) {
                    switch setting {
                    case "provider": provider = (try item.string(), item)
                    case "key": key = try secret(item)
                    case "enabled": enabled = try item.bool()
                    case "preset":
                        parts.preset = try item.string()
                        parts.given = true
                    case "endpoints":
                        parts.endpoints = try endpoints(item)
                        parts.given = true
                    case "headers":
                        for (header, text) in try item.mapping() {
                            parts.headers[header.lowercased()] = ConfigDocument.isCredentialHeader(header) ? try secret(text) : try text.string()
                        }
                        parts.given = true
                    default: break
                    }
                }
                if parts.given {
                    if SignInKind.of(provider: name) != nil {
                        throw value.error("`\(name)` is the provider of accounts that sign in: it takes no `preset`, `endpoints` or `headers` (give a provider of your own another name)")
                    }
                    if let (id, item) = provider, id != name {
                        throw item.error("an account with `preset`, `endpoints` or `headers` is the provider `\(name)` itself: leave `provider` out")
                    }
                    definitions.append((name, value, parts))
                } else if let kind = SignInKind.of(provider: provider?.0 ?? name), key != nil, !kind.takesKeys {
                    throw value.error("`\(provider?.0 ?? name)` accounts sign in and hold no key: leave `key` out and sign in from the control panel")
                } else if SignInKind.of(provider: provider?.0 ?? name) != nil, key == nil {
                    // Signs in instead of holding a key.
                    if let (id, item) = provider, id != name, ProviderRegistry.builtIn[name] != nil {
                        throw item.error("`\(name)` is the name of a provider, so `\(name)/…` would not reach `\(id)`: give this account another name")
                    }
                } else {
                    guard key != nil else { throw value.error("`key` is missing") }
                    if let (id, item) = provider, id != name, ProviderRegistry.builtIn[name] != nil {
                        throw item.error("`\(name)` is the name of a provider, so `\(name)/…` would not reach `\(id)`: give this account another name")
                    }
                }
                accounts.append(Account(
                    name: name, provider: provider?.0 ?? name, providerField: provider?.1 ?? value, key: key, enabled: enabled,
                ))
            }

            var keys: [String: [UpstreamKey]] = [:]
            var owners: [String: String] = [:]
            for account in accounts {
                if account.key == nil, let kind = SignInKind.of(provider: account.provider) {
                    keys[account.provider, default: []] += account.enabled ? [UpstreamKey(signingIn: account.name, kind)] : []
                    continue
                }
                guard let key = account.key else { continue }
                if let owner = owners.updateValue(account.name, forKey: account.provider + "\u{0}" + key) {
                    throw account.providerField.error("account `\(account.name)` has the same key as `\(owner)`")
                }
                keys[account.provider, default: []] += account.enabled ? [UpstreamKey(name: account.name, secret: key)] : []
            }
            for (id, value, parts) in definitions {
                let keyless = keys[id] == nil && UpstreamKeys.load(for: id, in: registry, environment: environment).isEmpty
                registry.register(try provider(id: id, value, parts: parts, registry: registry, keyless: keyless))
            }
            for account in accounts where registry[account.provider] == nil {
                throw account.providerField.error(
                    "unknown provider `\(account.provider)` (presets: \(ProviderRegistry.builtIn.providers.keys.sorted().joined(separator: ", ")); or an account with `endpoints`)",
                )
            }
            return keys
        }

        func endpoints(_ field: Field) throws(ConfigError) -> [(APIProtocol, String)] {
            var list: [(APIProtocol, String)] = []
            for (name, url) in try field.mapping(allowed: Set(APIProtocol.allCases.map(\.rawValue))) {
                let address = try url.string()
                guard address.hasPrefix("http://") || address.hasPrefix("https://") else {
                    throw url.error("expected an http:// or https:// URL")
                }
                list.append((APIProtocol(rawValue: name)!, address))
            }
            guard !list.isEmpty else { throw field.error("lists no endpoint") }
            return list
        }

        /// The provider an account defines: a preset under its own name, a
        /// built-in provider changed, or one of its own endpoints.
        func provider(id: String, _ field: Field, parts: ProviderParts, registry: ProviderRegistry, keyless: Bool) throws(ConfigError) -> Provider {
            var provider: Provider
            if let preset = parts.preset {
                guard let base = ProviderRegistry.builtIn[preset] else {
                    throw field.error("unknown preset `\(preset)` (presets: \(ProviderRegistry.builtIn.providers.keys.sorted().joined(separator: ", ")))")
                }
                provider = base
                provider.id = id
                if id != preset { provider.apiKeyEnvironmentVariables = [] }
            } else if let existing = registry[id] {
                provider = existing
            } else {
                guard parts.endpoints != nil else {
                    throw field.error("`\(id)` is not a provider: give its `endpoints`, or a `preset` to start from")
                }
                provider = Provider(id: id, endpoints: [])
            }

            if let endpoints = parts.endpoints {
                // The list is complete: a preset's endpoints for other
                // protocols go, so its keys never reach the preset's host.
                provider.endpoints = endpoints.map { apiProtocol, url in
                    if var endpoint = provider.endpoints.first(where: { $0.apiProtocol == apiProtocol }) {
                        endpoint.baseURL = url
                        if keyless { endpoint.auth = .none }
                        return endpoint
                    }
                    let auth: EndpointAuth
                    switch apiProtocol {
                    case _ where keyless: auth = .none
                    case .chatCompletions, .responses: auth = .bearer
                    case .anthropicMessages: auth = .anthropic()
                    case .gemini: auth = .googleAPIKey
                    }
                    return Presets.customEndpoint(system: id, apiProtocol: apiProtocol, baseURL: url, auth: auth)
                }
            }
            for index in provider.endpoints.indices {
                provider.endpoints[index].headers.merge(parts.headers) { _, new in new }
            }
            return provider
        }

        // MARK: Models

        struct MenuEntry {
            var name: String
            /// As written: `provider`, `provider/model` or `@name`.
            var target: String
            /// Where it is written; `nil`: on the command line (`--model`).
            var field: Field?

            func error(_ message: String) -> ConfigError {
                field?.error(message) ?? ConfigError(message: "--model: \(message)")
            }
        }

        func menu(_ field: Field) throws(ConfigError) -> [MenuEntry] {
            var entries: [MenuEntry] = []
            var seen: Set<String> = []
            for (name, value) in try field.mapping() {
                guard !name.isEmpty, !name.hasPrefix("@") else { throw value.error("a model name cannot be empty or start with @") }
                guard seen.insert(name.lowercased()).inserted else {
                    throw value.error("`\(name)` is defined twice (names are case-insensitive)")
                }
                switch value.value {
                case .array:
                    throw value.error("a list of targets to fall back through is not supported yet: give one target")
                case .object:
                    throw value.error("an entry with settings (`try`, `budget`, …) is not supported yet: give one target")
                default:
                    let target = try value.string().trimmingBlanks()
                    guard !target.isEmpty else { throw value.error("is empty") }
                    entries.append(MenuEntry(name: name, target: target, field: value))
                }
            }
            return entries
        }

        /// `provider` alone is `provider/$model`.
        static func expand(_ target: String) -> String {
            target.contains("/") ? target : target + "/$model"
        }

        /// The menu as routes: references followed, targets checked.
        func routes(_ entries: [MenuEntry], registry: ProviderRegistry) throws(ConfigError) -> [Route] {
            var byName: [String: MenuEntry] = [:]
            for entry in entries { byName[entry.name.lowercased()] = entry }
            var routes: [Route] = []
            for entry in entries {
                var current = entry
                var chain = [entry.name]
                while current.target.hasPrefix("@") {
                    let name = String(current.target.dropFirst())
                    guard let next = byName[name.lowercased()] else {
                        throw entry.error("`@\(name)` names no entry of models")
                    }
                    guard !next.name.contains("*") else {
                        throw entry.error("`@\(name)` names a pattern: only an entry without * can be referred to")
                    }
                    guard !chain.contains(where: { $0.lowercased() == next.name.lowercased() }) else {
                        throw entry.error("refers back to itself: \((chain + [next.name]).joined(separator: " → "))")
                    }
                    chain.append(next.name)
                    current = next
                }
                let target = RouteTarget(model: Self.expand(current.target))
                do throws(ConfigError) {
                    try ConfigFile.check(target, registry: registry)
                } catch {
                    throw current.error(error.message)
                }
                routes.append(Route(name: entry.name, targets: [target]))
            }
            return routes
        }

        // MARK: Clients

        /// The enabled clients' keys, and the names of the disabled ones.
        mutating func clients(_ field: Field) throws(ConfigError) -> ([ClientKey], [String]) {
            var keys: [ClientKey] = []
            var disabled: [String] = []
            var owners: [String: String] = [:]
            for (name, item) in try field.mapping() {
                guard !name.isEmpty else { throw item.error("a client name cannot be empty") }
                var secretValue: String?
                var enabled = true
                var models: [String]?
                for (setting, value) in try item.mapping(allowed: ["key", "models", "enabled"], reserved: ["limits", "overrides"]) {
                    switch setting {
                    case "key": secretValue = try secret(value)
                    case "enabled": enabled = try value.bool()
                    case "models": models = try value.stringList()
                    default: break
                    }
                }
                guard let secretValue else { throw item.error("`key` is missing") }
                if let owner = owners.updateValue(name, forKey: secretValue) {
                    throw item.error("client `\(name)` has the key of `\(owner)`")
                }
                if enabled { keys.append(ClientKey(name: name, secret: secretValue, models: models)) } else { disabled.append(name) }
            }
            return (keys, disabled)
        }
    }
}

extension RouteTarget {
    /// The target with `$model` filled in, to check what it names.
    var probe: String { model.replacing("$model", with: "model") }
}
