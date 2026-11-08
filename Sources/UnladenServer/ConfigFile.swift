// The configuration file: JSON with comments and trailing commas (JSONC),
// decoded field by field so that unknown fields are refused and errors carry
// a line and column.
// See docs/server-config-design.md for the schema.

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
    /// Becomes the `*` route.
    var model: String?
    /// A client key allowed every route and every passthrough.
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
    /// then applies `overrides` and the environment.
    ///
    /// - Parameter explicit: whether `path` was asked for; a missing
    ///   default file is no error, a missing explicit one is.
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
    static func parse(
        _ text: String, file: String = "config", overrides: ConfigOverrides = ConfigOverrides(),
        environment: @escaping (String) -> String?,
    ) throws(ConfigError) -> LoadedConfiguration {
        let (root, locator) = try parseJSON(text, file: file)
        var parser = Parser(file: file, environment: environment, locator: locator)
        var loaded = LoadedConfiguration()
        var fileKeys: [String: [UpstreamKey]] = [:]
        var poolStrategies: [String: KeyPool.Strategy] = [:]
        var routes: [Route] = []
        var clientKeys: [ClientKey]?

        if !root.isNull {
            let top = Field(value: root, keys: [], parser: parser)
            for (name, field) in try top.mapping(allowed: ["server", "providers", "routes", "client_keys"]) {
                switch name {
                case "server": try parser.server(field, into: &loaded)
                case "providers":
                    for (id, provider) in try field.mapping() {
                        let built = try parser.provider(id: id, provider, registry: loaded.gateway.registry)
                        loaded.gateway.registry.register(built.provider)
                        if let keys = built.keys { fileKeys[id] = keys }
                        poolStrategies[id] = built.strategy
                    }
                case "routes":
                    for (name, route) in try field.mapping() { routes.append(try parser.route(name: name, route)) }
                case "client_keys": clientKeys = try parser.clientKeys(field)
                default: break
                }
            }
        }

        // Key pools: the file's keys, else the environment's.
        let registry = loaded.gateway.registry
        for id in registry.providers.keys {
            let keys = fileKeys[id] ?? UpstreamKeys.load(for: id, in: registry, environment: environment)
            if !keys.isEmpty { loaded.gateway.keyPools[id] = KeyPool(keys: keys, strategy: poolStrategies[id] ?? .order) }
        }

        // Command line overrides.
        if let host = overrides.host { loaded.server.host = host }
        if let port = overrides.port { loaded.server.port = port }
        if let seconds = overrides.connectTimeout { loaded.server.connectTimeout = .seconds(seconds) }
        if let seconds = overrides.keepalive { loaded.gateway.keepaliveInterval = .seconds(seconds) }
        if overrides.strict { loaded.gateway.strict = true }
        if let model = overrides.model {
            if routes.contains(where: { $0.name == "*" }) {
                loaded.warnings.append("--model replaces the `*` route of the configuration file")
            }
            routes.removeAll { $0.name == "*" }
            routes.append(Route(name: "*", targets: [RouteTarget(model: model)]))
        }
        if let apiKey = overrides.apiKey {
            clientKeys = (clientKeys ?? []) + [ClientKey(name: "command-line", secret: apiKey, routes: nil, passthrough: ["*"])]
        } else if clientKeys == nil, let apiKey = environment("UNLADEN_API_KEY"), !apiKey.isEmpty {
            clientKeys = [ClientKey(name: "UNLADEN_API_KEY", secret: apiKey, routes: nil, passthrough: ["*"])]
        }
        loaded.gateway.clientKeys = clientKeys ?? []

        // Routes, checked against the final registry.
        var seen: Set<String> = []
        for route in routes {
            guard seen.insert(route.name.lowercased()).inserted else {
                throw ConfigError(message: "routes: `\(route.name)` is defined twice (names are case-insensitive)")
            }
            for target in route.targets {
                try check(target, of: route, registry: registry, fromCommandLine: route.name == "*" && overrides.model != nil)
            }
            if route.name == "*" {
                loaded.warnings.append("route `*` serves every model name no other route matches: such requests are answered by \(route.targets.map(\.model).joined(separator: ", "))")
            } else if let (provider, _) = try? ProviderRegistry.parse(route.name), registry[provider] != nil {
                loaded.warnings.append("route `\(route.name)` takes the place of the passthrough reference of the same name")
            }
        }
        loaded.gateway.routes = RouteTable(routes)
        loaded.hasLiteralSecrets = parser.literalSecrets
        return loaded
    }

    /// A target must name a known provider; without `$model`, a model it
    /// can resolve.
    static func check(_ target: RouteTarget, of route: Route, registry: ProviderRegistry, fromCommandLine: Bool) throws(ConfigError) {
        let place = fromCommandLine ? "--model" : "routes.\(route.name)"
        let probe = target.model.replacing("$model", with: "model")
        do {
            let (provider, _) = try ProviderRegistry.parse(probe)
            guard registry[provider] != nil else {
                throw ConfigError(message: "\(place): unknown provider `\(provider)` (providers: \(registry.providers.keys.sorted().joined(separator: ", ")))")
            }
            if !target.model.contains("$model") { _ = try registry.resolve(target.model) }
        } catch let error as ConfigError {
            throw error
        } catch {
            throw ConfigError(message: "\(place): cannot use `\(target.model)`: \(error) (expected provider/model)")
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

        mutating func server(_ field: Field, into loaded: inout LoadedConfiguration) throws(ConfigError) {
            for (name, value) in try field.mapping(
                allowed: ["listen", "strict", "keepalive", "connect_timeout", "max_request_bytes", "head_timeout", "idle_timeout", "admin"],
            ) {
                switch name {
                case "listen":
                    let text = try value.string()
                    guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
                          (1...65535).contains(port)
                    else { throw value.error("expected host:port, such as 127.0.0.1:4141 or [::1]:4141") }
                    var host = String(text[..<colon])
                    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
                    guard !host.isEmpty else { throw value.error("the host is missing (0.0.0.0 listens everywhere)") }
                    loaded.server.host = host
                    loaded.server.port = port
                case "strict": loaded.gateway.strict = try value.bool()
                case "keepalive": loaded.gateway.keepaliveInterval = try value.duration()
                case "connect_timeout": loaded.server.connectTimeout = try value.duration()
                case "max_request_bytes": loaded.gateway.maxRequestBytes = try value.byteCount()
                case "head_timeout": loaded.gateway.headTimeout = try value.duration(allowingOff: true)
                case "idle_timeout": loaded.gateway.idleTimeout = try value.duration(allowingOff: true)
                case "admin":
                    for (key, setting) in try value.mapping(allowed: ["token"]) where key == "token" {
                        let token = try secret(setting)
                        guard token.count >= 16 else { throw setting.error("is too short: use at least 16 characters") }
                        loaded.gateway.adminToken = token
                    }
                default: break
                }
            }
        }

        struct BuiltProvider {
            var provider: Provider
            /// `nil`: the file gives none (the environment may).
            var keys: [UpstreamKey]?
            var strategy: KeyPool.Strategy
        }

        mutating func provider(id: String, _ field: Field, registry: ProviderRegistry) throws(ConfigError) -> BuiltProvider {
            guard !id.isEmpty, !id.contains("/"), !id.contains("*") else { throw field.error("a provider id cannot be empty or contain / or *") }
            var preset: String?
            var endpoints: [(APIProtocol, String, Field)]?
            var headers: [String: String] = [:]
            var keys: [UpstreamKey]?
            var strategy = KeyPool.Strategy.order
            for (name, value) in try field.mapping(allowed: ["preset", "endpoints", "headers", "keys", "strategy"], reserved: ["models"]) {
                switch name {
                case "preset": preset = try value.string()
                case "endpoints":
                    var list: [(APIProtocol, String, Field)] = []
                    for (name, url) in try value.mapping(allowed: Set(APIProtocol.allCases.map(\.rawValue))) {
                        let address = try url.string()
                        guard address.hasPrefix("http://") || address.hasPrefix("https://") else {
                            throw url.error("expected an http:// or https:// URL")
                        }
                        list.append((APIProtocol(rawValue: name)!, address, url))
                    }
                    guard !list.isEmpty else { throw value.error("lists no endpoint") }
                    endpoints = list
                case "headers":
                    for (name, header) in try value.mapping() { headers[name.lowercased()] = try header.string() }
                case "keys": keys = try self.keys(value)
                case "strategy":
                    let text = try value.string()
                    if text == "weight" { throw value.error("`weight` is not supported yet") }
                    guard let parsed = KeyPool.Strategy(rawValue: text) else { throw value.error("expected order or rotate") }
                    strategy = parsed
                default: break
                }
            }

            var provider: Provider
            if let preset {
                guard let base = ProviderRegistry.builtIn[preset] else {
                    throw field.error("unknown preset `\(preset)` (presets: \(ProviderRegistry.builtIn.providers.keys.sorted().joined(separator: ", ")))")
                }
                provider = base
                provider.id = id
                if id != preset { provider.apiKeyEnvironmentVariables = [] }
            } else if let existing = registry[id] {
                provider = existing
            } else {
                guard endpoints != nil else {
                    throw field.error("`\(id)` is not a preset: give its `endpoints`, or a `preset` to start from")
                }
                provider = Provider(id: id, endpoints: [])
            }

            if let endpoints {
                // The list is complete: a preset's endpoints for other
                // protocols go, so its keys never reach the preset's host.
                let keyless = keys?.isEmpty ?? UpstreamKeys.load(for: id, in: ProviderRegistry([provider]), environment: environment).isEmpty
                provider.endpoints = endpoints.map { apiProtocol, url, _ in
                    if var endpoint = provider.endpoints.first(where: { $0.apiProtocol == apiProtocol }) {
                        endpoint.baseURL = url
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
                provider.endpoints[index].headers.merge(headers) { _, new in new }
            }
            return BuiltProvider(provider: provider, keys: keys, strategy: strategy)
        }

        mutating func keys(_ field: Field) throws(ConfigError) -> [UpstreamKey] {
            var keys: [UpstreamKey] = []
            for item in try field.sequence() {
                if item.isScalar {
                    keys.append(UpstreamKey(secret: try secret(item)))
                    continue
                }
                var name: String?
                var secretValue: String?
                var enabled = true
                for (key, value) in try item.mapping(allowed: ["name", "key", "enabled"], reserved: ["weight", "protocols"]) {
                    switch key {
                    case "name": name = try value.string()
                    case "key": secretValue = try secret(value)
                    case "enabled": enabled = try value.bool()
                    default: break
                    }
                }
                guard let secretValue else { throw item.error("`key` is missing") }
                if let name, name.isEmpty { throw item.error("`name` is empty") }
                if enabled { keys.append(UpstreamKey(name: name, secret: secretValue)) }
            }
            var names: Set<String> = [], secrets: Set<String> = []
            for key in keys {
                guard secrets.insert(key.secret).inserted else { throw field.error("the key `\(key.name)` is listed twice") }
                guard names.insert(key.name).inserted else { throw field.error("two keys are named `\(key.name)`") }
            }
            return keys
        }

        func route(name: String, _ field: Field) throws(ConfigError) -> Route {
            guard !name.isEmpty else { throw field.error("a route name cannot be empty") }
            if field.isScalar { return Route(name: name, targets: [RouteTarget(model: try field.string())]) }
            var targets: [RouteTarget] = []
            for (key, value) in try field.mapping(
                allowed: ["targets"],
                reserved: ["attempt_budget", "head_timeout", "patience", "strict", "affinity", "when"],
            ) where key == "targets" {
                for item in try value.sequence() {
                    if item.isScalar {
                        targets.append(RouteTarget(model: try item.string()))
                        continue
                    }
                    var model: String?
                    for (key, value) in try item.mapping(allowed: ["model"], reserved: ["priority", "weight", "route", "enabled", "when"])
                    where key == "model" {
                        model = try value.string()
                    }
                    guard let model else { throw item.error("`model` is missing") }
                    targets.append(RouteTarget(model: model))
                }
                guard targets.count <= 1 else { throw value.error("routes with more than one target are not supported yet") }
            }
            guard !targets.isEmpty else { throw field.error("has no target") }
            return Route(name: name, targets: targets)
        }

        mutating func clientKeys(_ field: Field) throws(ConfigError) -> [ClientKey] {
            var keys: [ClientKey] = []
            for item in try field.sequence() {
                var name: String?
                var secretValue: String?
                var enabled = true
                var routes: [String]?
                var passthrough: [String] = []
                for (key, value) in try item.mapping(allowed: ["name", "secret", "enabled", "routes", "passthrough"]) {
                    switch key {
                    case "name": name = try value.string()
                    case "secret": secretValue = try secret(value)
                    case "enabled": enabled = try value.bool()
                    case "routes": routes = try value.stringList()
                    case "passthrough":
                        if let flag = value.value.boolValue {
                            passthrough = flag ? ["*"] : []
                        } else {
                            passthrough = try value.stringList()
                        }
                    default: break
                    }
                }
                guard let name, !name.isEmpty else { throw item.error("`name` is missing") }
                guard let secretValue else { throw item.error("`secret` is missing") }
                if enabled { keys.append(ClientKey(name: name, secret: secretValue, routes: routes, passthrough: passthrough)) }
            }
            var names: Set<String> = [], secrets: Set<String> = []
            for key in keys {
                guard names.insert(key.name).inserted else { throw field.error("two client keys are named `\(key.name)`") }
                guard secrets.insert(key.secret).inserted else { throw field.error("client key `\(key.name)` has the secret of another") }
            }
            return keys
        }
    }
}
