// Accounts that sign in instead of holding a key: a ChatGPT plan used
// through OpenAI's API ("Sign in with ChatGPT", which OpenAI offers to apps
// running on the user's own machine). The sign-in is OAuth with PKCE; the
// browser may be on another computer, so it ends with the user pasting the
// address the browser was sent back to. The tokens are kept in the state
// directory, apart from the configuration file, and refreshed before they
// expire; the refresh token changes with each refresh.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import NIOConcurrencyHelpers
@_spi(Wire) import UnladenCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// How a provider's accounts sign in.
enum SignInKind: String, Sendable, Hashable {
    /// OpenAI's Sign in with ChatGPT, for the `chatgpt` preset.
    case chatgpt

    /// The kind of `provider`'s accounts; `nil`: they hold keys.
    static func of(provider: String) -> SignInKind? {
        provider == Presets.chatGPT.id ? .chatgpt : nil
    }
}

/// What can keep a signed-in account from being used.
struct SignInError: Error, Sendable, CustomStringConvertible {
    var message: String
    /// The account must sign in again: no tokens, or tokens OpenAI no
    /// longer refreshes.
    var needsSignIn = false

    var description: String { message }
}

/// A signed-in account's tokens and what they say of it.
struct SignInCredentials: Sendable, Hashable {
    /// The client id OpenAI issued when the gateway first signed in.
    var clientID: String
    var access: String
    var refresh: String
    /// Unix time in milliseconds.
    var expires: Int64
    var user: String
    var plan: String?
    /// Set when OpenAI refused the refresh token: sign in again.
    var lapsed: String?

    var json: JSONValue {
        var object: JSONObject = [
            "client_id": .string(clientID), "access": .string(access), "refresh": .string(refresh),
            "expires": .number(JSONNumber(expires)), "user": .string(user),
        ]
        if let plan { object["plan"] = .string(plan) }
        if let lapsed { object["lapsed"] = .string(lapsed) }
        return .object(object)
    }

    init(clientID: String, access: String, refresh: String, expires: Int64, user: String, plan: String? = nil) {
        self.clientID = clientID
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.user = user
        self.plan = plan
    }

    init?(_ value: JSONValue) {
        guard let clientID = value["client_id"]?.stringValue, let access = value["access"]?.stringValue,
              let refresh = value["refresh"]?.stringValue, let expires = value["expires"]?.numberValue?.int,
              let user = value["user"]?.stringValue
        else { return nil }
        self.init(clientID: clientID, access: access, refresh: refresh, expires: Int64(expires), user: user,
                  plan: value["plan"]?.stringValue)
        lapsed = value["lapsed"]?.stringValue
    }
}

// MARK: - The store

/// Signed-in accounts' credentials, by `provider/account`, kept in
/// `logins.json` of the state directory (0600), and the sign-ins under way.
final class SignIns: Sendable {
    /// Refreshed when it has less than this left, so no request starts
    /// with a token about to expire.
    static let margin: Int64 = 3 * 60 * 1000
    /// How long a started sign-in waits for its pasted address.
    static let pendingLimit: Int64 = 15 * 60 * 1000

    let path: String?
    let hostIDPath: String?

    private struct Pending {
        var provider: String
        var account: String
        var verifier: String
        var state: String
        var nonce: String
        var started: Int64
    }

    private struct State {
        var credentials: [String: SignInCredentials] = [:]
        var refreshing: [String: Task<String, any Error>] = [:]
        var pending: [String: Pending] = [:]
    }

    private let state = NIOLockedValueBox(State())

    /// `directory`: the state directory; `nil` keeps everything in memory.
    init(directory: String? = nil) {
        path = directory.map { $0 + "/logins.json" }
        hostIDPath = directory.map { $0 + "/host-id" }
        load()
    }

    static func key(_ provider: String, _ account: String) -> String { provider + "/" + account }

    /// Reads the file again (a sign-in from the command line wrote it).
    func load() {
        writing.lock()
        defer { writing.unlock() }
        if let stored = readFile() { state.withLockedValue { $0.credentials = stored } }
    }

    /// The file's credentials; `nil` without a file (or one that cannot be read).
    private func readFile() -> [String: SignInCredentials]? {
        guard let path, let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONValue(parsing: Array(data)))?.objectValue
        else { return nil }
        var credentials: [String: SignInCredentials] = [:]
        for (key, value) in object { if let entry = SignInCredentials(value) { credentials[key] = entry } }
        return credentials
    }

    func credentials(provider: String, account: String) -> SignInCredentials? {
        state.withLockedValue { $0.credentials[Self.key(provider, account)] }
    }

    /// Keeps `credentials` for the account, in memory and in the file.
    func keep(_ credentials: SignInCredentials?, provider: String, account: String) throws(SignInError) {
        try update(provider: provider, account: account) { _ in credentials }
    }

    /// Changes the account's credentials with `change` (given the current
    /// ones) and writes the file. One change at a time, so the file is
    /// written in the order of the changes; writes also share the
    /// temporary file's name.
    private func update(
        provider: String, account: String, _ change: (SignInCredentials?) -> SignInCredentials?,
    ) throws(SignInError) {
        writing.lock()
        defer { writing.unlock() }
        // The file is read again first: another process (`unladen sign-in`,
        // a gateway being replaced) may have changed other accounts.
        let stored = readFile()
        let all = state.withLockedValue { state in
            if let stored { state.credentials = stored }
            let key = Self.key(provider, account)
            state.credentials[key] = change(state.credentials[key])
            return state.credentials
        }
        guard let path else { return }
        var object = JSONObject()
        for (key, value) in all.sorted(by: { $0.key < $1.key }) { object[key] = value.json }
        let text = String(decoding: JSONValue.object(object).encoded(), as: UTF8.self) + "\n"
        do {
            try Self.write(text, to: path)
        } catch {
            throw SignInError(message: "cannot keep the sign-in: \(error.message)")
        }
    }

    private let writing = NIOLock()

    /// Writes a private file (0600) in a private directory (0700).
    private static func write(_ text: String, to path: String) throws(SignInError) {
        let directory = String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700],
            )
        }
        do {
            try ConfigManager.write(text, to: path)
        } catch {
            throw SignInError(message: error.message)
        }
        // Private even if it was once written otherwise.
        _ = chmod(path, 0o600)
    }

    /// Forgets an account's sign-in.
    func forget(provider: String, account: String) throws(SignInError) {
        try keep(nil, provider: provider, account: account)
    }

    /// An access token for the account, refreshed first when it is about
    /// to expire, or when it is `rejected` (OpenAI turned it away). One
    /// refresh at a time per account: the refresh token is used up by it.
    func token(
        provider: String, account: String, transport: any HTTPTransport, rejected: String? = nil,
    ) async throws(SignInError) -> String {
        let key = Self.key(provider, account)
        let now = LocalDay.nowMilliseconds()
        enum Next { case ready(String), wait(Task<String, any Error>), fail(SignInError) }
        let next: Next = state.withLockedValue { state in
            guard let current = state.credentials[key] else {
                return .fail(SignInError(message: "\(key) has not signed in (sign in from the control panel)", needsSignIn: true))
            }
            if let lapsed = current.lapsed { return .fail(SignInError(message: lapsed, needsSignIn: true)) }
            if current.access != rejected, current.expires - now > Self.margin { return .ready(current.access) }
            if let running = state.refreshing[key] { return .wait(running) }
            let turnedAway = current.access == rejected
            let task = Task<String, any Error> {
                try await self.refresh(current, provider: provider, account: account, transport: transport, rejected: turnedAway)
            }
            state.refreshing[key] = task
            return .wait(task)
        }
        switch next {
        case .ready(let token): return token
        case .fail(let error): throw error
        case .wait(let task):
            do {
                let token = try await task.value
                // A refresh already under way kept the token turned away
                // (it could not reach OpenAI): refresh again for this one.
                if let rejected, token == rejected, state.withLockedValue({ $0.credentials[key]?.access == rejected }) {
                    return try await self.token(provider: provider, account: account, transport: transport, rejected: rejected)
                }
                return token
            } catch let error as SignInError {
                throw error
            } catch {
                throw error as? SignInError ?? SignInError(message: "\(key): token refresh failed: \(error)")
            }
        }
    }

    /// Refreshes `current` and keeps the result, unless the account signed
    /// in again or was forgotten meanwhile; a refresh token OpenAI will no
    /// longer take marks the account as needing to sign in.
    private func refresh(
        _ current: SignInCredentials, provider: String, account: String, transport: any HTTPTransport, rejected: Bool,
    ) async throws(SignInError) -> String {
        let key = Self.key(provider, account)
        defer { state.withLockedValue { _ = $0.refreshing.removeValue(forKey: key) } }
        do {
            let fresh: SignInCredentials
            do {
                fresh = try await ChatGPTSignIn.refresh(current, transport: transport)
            } catch where !error.needsSignIn && current.expires > LocalDay.nowMilliseconds() + 10_000 && !rejected {
                // A hiccup: the token in hand still does.
                return current.access
            }
            try update(provider: provider, account: account) { $0?.refresh == current.refresh ? fresh : $0 }
            return fresh.access
        } catch {
            var failure = error
            failure.message = "\(key): \(failure.message)"
            if failure.needsSignIn {
                let message = failure.message
                try? update(provider: provider, account: account) { stored in
                    guard var lapsed = stored, lapsed.refresh == current.refresh else { return stored }
                    lapsed.lapsed = message
                    return lapsed
                }
            }
            throw failure
        }
    }

    // MARK: Signing in

    /// Starts a sign-in: the address to open, and the id to finish it with.
    func start(provider: String, account: String) throws(SignInError) -> (id: String, url: String) {
        guard SignInKind.of(provider: provider) == .chatgpt else {
            throw SignInError(message: "\(provider) accounts do not sign in")
        }
        let pending = Pending(
            provider: provider, account: account, verifier: Base64URL.random(32), state: Base64URL.random(16),
            nonce: Base64URL.random(16), started: LocalDay.nowMilliseconds(),
        )
        let id = Base64URL.random(12)
        let url = ChatGPTSignIn.authorizeURL(
            state: pending.state, nonce: pending.nonce, challenge: Base64URL.encode(SHA256.hash(Array(pending.verifier.utf8))),
            hostID: try hostID(),
        )
        state.withLockedValue { state in
            let now = pending.started
            state.pending = state.pending.filter { now - $0.value.started < Self.pendingLimit }
            state.pending[id] = pending
        }
        return (id, url)
    }

    /// Finishes sign-in `id` with the address the browser was sent back
    /// to, and keeps the account's tokens.
    func finish(
        id: String, callback: String, transport: any HTTPTransport,
    ) async throws(SignInError) -> (provider: String, account: String, credentials: SignInCredentials) {
        guard let pending = state.withLockedValue({ $0.pending[id] }),
              LocalDay.nowMilliseconds() - pending.started < Self.pendingLimit
        else { throw SignInError(message: "this sign-in has expired: start it again") }
        let query = ChatGPTSignIn.query(of: callback)
        if let error = query["error"] {
            throw SignInError(message: "OpenAI refused the sign-in: \(query["error_description"] ?? error)")
        }
        guard let code = query["code"], !code.isEmpty else {
            throw SignInError(message: "the address has no `code`: paste the whole address the browser ended on")
        }
        guard query["state"] == pending.state else {
            throw SignInError(message: "the address belongs to another sign-in: paste the one this sign-in ended on")
        }
        guard let clientID = query["client_id"], !clientID.isEmpty else {
            throw SignInError(message: "the address has no `client_id`: OpenAI did not finish registering the gateway; start again")
        }
        let credentials = try await ChatGPTSignIn.exchange(
            code: code, clientID: clientID, verifier: pending.verifier, nonce: pending.nonce, transport: transport,
        )
        _ = state.withLockedValue { $0.pending.removeValue(forKey: id) }
        try keep(credentials, provider: pending.provider, account: pending.account)
        return (pending.provider, pending.account, credentials)
    }

    /// Names this machine to OpenAI, the same at every sign-in.
    private func hostID() throws(SignInError) -> String {
        writing.lock()
        defer { writing.unlock() }
        if let hostIDPath, let data = FileManager.default.contents(atPath: hostIDPath) {
            let id = String(decoding: data, as: UTF8.self).trimmingBlanks()
            if id.hasPrefix("urn:uuid:") { return id }
        }
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        bytes[6] = bytes[6] & 0x0f | 0x40
        bytes[8] = bytes[8] & 0x3f | 0x80
        let hex = bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        let id = "urn:uuid:" + parts.joined(separator: "-")
        if let hostIDPath {
            do {
                try Self.write(id + "\n", to: hostIDPath)
            } catch {
                throw SignInError(message: "cannot keep this machine's id: \(error.message)")
            }
        }
        return id
    }
}

// MARK: - OpenAI's Sign in with ChatGPT

enum ChatGPTSignIn {
    static let authorizeEndpoint = "https://auth.openai.com/api/accounts/authorize"
    static let tokenAuthority = "auth.openai.com"
    static let tokenPath = "/api/accounts/oauth/token"
    static let issuer = "https://auth.openai.com"
    /// What the token is for.
    static let resource = "https://api.openai.com/v1"
    /// Registers the gateway as an app at its first sign-in.
    static let dynamicClient = "dynamic_agent_client"
    static let agentName = "unladen"
    /// Lets the token be sent to api.openai.com itself.
    static let directScope = "chatgpt.tokens.use.direct"
    /// The longest a token request may take.
    static let timeout: Duration = .seconds(30)
    static let scopes = "openid profile email offline_access resource.invoke " + directScope
    /// Where the browser is sent back to, as OpenAI's own apps are: on the
    /// browser's computer, where nothing answers; the user pastes the
    /// address it ends on.
    static let redirect = "http://127.0.0.1:1455/auth/callback"
    /// Refusals of a refresh token that will never work again.
    static let deadRefresh: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated",
        "refresh_token_reused", "invalid_client",
    ]

    static func authorizeURL(state: String, nonce: String, challenge: String, hostID: String) -> String {
        let query: [(String, String)] = [
            ("client_id", dynamicClient), ("agent_name_hint", agentName), ("ext_agent_host_id", hostID),
            ("response_type", "code"), ("redirect_uri", redirect), ("resource", resource), ("scope", scopes),
            ("state", state), ("nonce", nonce), ("code_challenge", challenge), ("code_challenge_method", "S256"),
        ]
        return authorizeEndpoint + "?" + FormEncoding.encode(query)
    }

    /// The query of a pasted address (or of a bare query string).
    static func query(of address: String) -> [String: String] {
        var text = address.trimmingBlanks()
        if let mark = text.firstIndex(of: "?") { text = String(text[text.index(after: mark)...]) }
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        return FormEncoding.decode(text)
    }

    static func exchange(
        code: String, clientID: String, verifier: String, nonce: String, transport: any HTTPTransport,
    ) async throws(SignInError) -> SignInCredentials {
        let reply = try await post([
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code), ("code_verifier", verifier),
            ("redirect_uri", redirect), ("resource", resource),
        ], transport: transport)
        guard let idToken = reply["id_token"]?.stringValue else { throw SignInError(message: "OpenAI sent no ID token") }
        let claims = JWT.claims(idToken)
        guard claims?["iss"]?.stringValue.map({ $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) == issuer else {
            throw SignInError(message: "the ID token is not OpenAI's")
        }
        let audience = claims?["aud"]
        guard audience?.stringValue == clientID || audience?.arrayValue?.contains(.string(clientID)) == true else {
            throw SignInError(message: "the ID token is for another app")
        }
        guard claims?["nonce"]?.stringValue == nonce else { throw SignInError(message: "the ID token is not this sign-in's") }
        if let expiry = claims?["exp"]?.numberValue?.double, Int64(expiry) * 1000 < LocalDay.nowMilliseconds() - 60_000 {
            throw SignInError(message: "the ID token has expired")
        }
        guard let user = claims?["email"]?.stringValue ?? claims?["sub"]?.stringValue, !user.isEmpty else {
            throw SignInError(message: "OpenAI did not say which account signed in")
        }
        var credentials = try credentials(from: reply, clientID: clientID, user: user)
        credentials.plan = plan(of: idToken) ?? plan(of: credentials.access)
        return credentials
    }

    static func refresh(_ current: SignInCredentials, transport: any HTTPTransport) async throws(SignInError) -> SignInCredentials {
        let reply = try await post([
            ("grant_type", "refresh_token"), ("client_id", current.clientID), ("refresh_token", current.refresh),
            ("resource", resource),
        ], transport: transport)
        var fresh = try credentials(from: reply, clientID: current.clientID, user: current.user)
        fresh.plan = plan(of: fresh.access) ?? current.plan
        return fresh
    }

    /// The ChatGPT plan a token names.
    static func plan(of token: String) -> String? {
        JWT.claims(token)?["https://api.openai.com/auth"]?["chatgpt_plan_type"]?.stringValue
    }

    private static func credentials(from reply: JSONValue, clientID: String, user: String) throws(SignInError) -> SignInCredentials {
        guard let access = reply["access_token"]?.stringValue, let refresh = reply["refresh_token"]?.stringValue,
              let lifetime = reply["expires_in"]?.numberValue?.double, lifetime > 0
        else { throw SignInError(message: "OpenAI sent no usable token") }
        let scopes = (reply["scope"]?.stringValue ?? "").split(separator: " ").map(String.init)
        guard scopes.contains(directScope) else {
            throw SignInError(message: "OpenAI did not grant the use of the plan through its API (\(directScope)): this ChatGPT account may not be eligible")
        }
        return SignInCredentials(
            clientID: clientID, access: access, refresh: refresh,
            expires: LocalDay.nowMilliseconds() + Int64(lifetime * 1000), user: user,
        )
    }

    private static func post(_ form: [(String, String)], transport: any HTTPTransport) async throws(SignInError) -> JSONValue {
        var request = HTTPRequest(method: .post, scheme: "https", authority: tokenAuthority, path: tokenPath)
        request.headerFields[.contentType] = "application/x-www-form-urlencoded"
        request.headerFields[.accept] = "application/json"
        let status: Int
        let bytes: [UInt8]
        do {
            let request = request
            (status, bytes) = try await Gateway.within(timeout) {
                let response = try await transport.send(request, body: Array(FormEncoding.encode(form).utf8))
                return (response.status.code, try await response.body.collect(upTo: 1 << 20))
            }
        } catch is Gateway.HeadTimeout {
            throw SignInError(message: "OpenAI's sign-in did not answer within \(timeout)")
        } catch {
            throw SignInError(message: "cannot reach OpenAI's sign-in: \(error)")
        }
        let reply = (try? JSONValue(parsing: bytes)) ?? .null
        guard status == 200 else {
            let code = reply["error"]?.stringValue ?? reply["error"]?["code"]?.stringValue ?? reply["code"]?.stringValue ?? ""
            let message = reply["error_description"]?.stringValue ?? reply["error"]?["message"]?.stringValue ?? "HTTP \(status)"
            throw SignInError(
                message: "OpenAI refused the token request (\(code.isEmpty ? "\(status)" : code)): \(message)",
                needsSignIn: deadRefresh.contains(code),
            )
        }
        return reply
    }
}

// MARK: - Encodings

/// `application/x-www-form-urlencoded`, also for query strings.
enum FormEncoding {
    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let hex = String(byte, radix: 16, uppercase: true)
                out += "%" + (byte < 16 ? "0" : "") + hex
            }
        }
        return out
    }

    static func decode(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            out[unescape(name)] = parts.count > 1 ? unescape(parts[1]) : ""
        }
        return out
    }

    static func unescape(_ text: Substring) -> String {
        var bytes: [UInt8] = []
        var index = text.utf8.startIndex
        let utf8 = text.utf8
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "%"), let first = utf8.index(index, offsetBy: 1, limitedBy: utf8.endIndex),
               let second = utf8.index(index, offsetBy: 2, limitedBy: utf8.endIndex), second < utf8.endIndex,
               utf8[first].isHexDigit, utf8[second].isHexDigit,
               let value = UInt8(String(decoding: [utf8[first], utf8[second]], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index = utf8.index(after: second)
                continue
            }
            bytes.append(byte == UInt8(ascii: "+") ? UInt8(ascii: " ") : byte)
            index = utf8.index(after: index)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Base64 with the URL alphabet and no padding.
enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let chunk = Array(bytes[index..<min(index + 3, bytes.count)])
            let value = chunk.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (16 - 8 * $1.offset) }
            for position in 0...chunk.count { out.append(alphabet[Int(value >> (18 - 6 * position) & 0x3f)]) }
            index += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> [UInt8]? {
        var bits: UInt32 = 0
        var count = 0
        var out: [UInt8] = []
        for byte in text.utf8 where byte != UInt8(ascii: "=") {
            let value: UInt8
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = byte - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = byte - UInt8(ascii: "a") + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = byte - UInt8(ascii: "0") + 52
            case UInt8(ascii: "-"), UInt8(ascii: "+"): value = 62
            case UInt8(ascii: "_"), UInt8(ascii: "/"): value = 63
            default: return nil
            }
            bits = bits << 6 | UInt32(value)
            count += 6
            if count >= 8 {
                count -= 8
                out.append(UInt8(bits >> UInt32(count) & 0xff))
            }
        }
        return out
    }

    /// `byteCount` random bytes, encoded.
    static func random(_ byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return encode((0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

/// The claims of a JSON Web Token, unverified: the token came straight
/// from OpenAI over TLS, and only says who signed in and on what plan.
enum JWT {
    static func claims(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let bytes = Base64URL.decode(String(parts[1])) else { return nil }
        return try? JSONValue(parsing: bytes)
    }
}

/// SHA-256 (FIPS 180-4), for the PKCE challenge: FoundationEssentials has
/// no hashing, and a crypto package would bring in the whole of Foundation.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let length = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(length >> UInt64(shift) & 0xff)) }
        func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                w[i] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[chunk + i * 4 + $1]) }
            }
            for i in 16..<64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ w[i - 15] >> 3
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ w[i - 2] >> 10
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = e & f ^ ~e & g
                let t1 = hh &+ s1 &+ choice &+ k[i] &+ w[i]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = a & b ^ a & c ^ b & c
                let t2 = s0 &+ majority
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            for (i, value) in [a, b, c, d, e, f, g, hh].enumerated() { h[i] = h[i] &+ value }
        }
        return h.flatMap { word in (0..<4).map { UInt8(word >> (24 - 8 * UInt32($0)) & 0xff) } }
    }
}

private extension UInt8 {
    var isHexDigit: Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(self)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(self)
    }
}
