// Accounts that sign in instead of holding a key: a ChatGPT plan used
// through OpenAI's API ("Sign in with ChatGPT", which OpenAI offers to apps
// running on the user's own machine), and an Antigravity subscription used
// through Google's Code Assist backend (Antigravity.swift; not something
// Google offers to other apps). The sign-in is OAuth with PKCE; the browser
// may be on another computer, so it ends with the user pasting the address
// the browser was sent back to. The tokens are kept in the state directory,
// apart from the configuration file, and refreshed before they expire.

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
    /// OpenAI's Sign in with ChatGPT, for the `chatgpt` preset; its
    /// accounts may hold an API key instead.
    case chatgpt
    /// Antigravity's Google sign-in, for the `antigravity` preset; its
    /// accounts only sign in.
    case antigravity

    /// The kind of `provider`'s accounts; `nil`: they hold keys.
    static func of(provider: String) -> SignInKind? {
        switch provider {
        case Presets.chatGPT.id: .chatgpt
        case Presets.antigravity.id: .antigravity
        default: nil
        }
    }

    /// Whether an account may hold a key instead of signing in.
    var takesKeys: Bool { self == .chatgpt }
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
    /// The Google Cloud project Code Assist serves the account under
    /// (Antigravity).
    var project: String?
    /// Set when the refresh token was refused: sign in again.
    var lapsed: String?

    var json: JSONValue {
        var object: JSONObject = [
            "client_id": .string(clientID), "access": .string(access), "refresh": .string(refresh),
            "expires": .number(JSONNumber(expires)), "user": .string(user),
        ]
        if let plan { object["plan"] = .string(plan) }
        if let project { object["project"] = .string(project) }
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
        project = value["project"]?.stringValue
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
        var kind: SignInKind
        var provider: String
        var account: String
        /// Where the browser is sent back to.
        var redirect: String
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
                throw SignInError(message: "\(key): token refresh failed: \(error)")
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
                switch SignInKind.of(provider: provider) {
                case .antigravity: fresh = try await AntigravitySignIn.refresh(current, transport: transport)
                default: fresh = try await ChatGPTSignIn.refresh(current, transport: transport)
                }
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

    /// Starts a sign-in: the address to open, the id to finish it with, and
    /// the address the browser will be sent back to.
    func start(provider: String, account: String) throws(SignInError) -> (id: String, url: String, redirect: String) {
        guard let kind = SignInKind.of(provider: provider) else {
            throw SignInError(message: "\(provider) accounts do not sign in")
        }
        let redirect = switch kind {
        case .chatgpt: ChatGPTSignIn.redirect
        case .antigravity: AntigravitySignIn.redirect(port: Int.random(in: 49152...65535))
        }
        let pending = Pending(
            kind: kind, provider: provider, account: account, redirect: redirect, verifier: Base64URL.random(48),
            state: Base64URL.random(24), nonce: Base64URL.random(16), started: LocalDay.nowMilliseconds(),
        )
        let id = Base64URL.random(12)
        let challenge = Base64URL.encode(SHA256.hash(Array(pending.verifier.utf8)))
        let url = switch kind {
        case .chatgpt: ChatGPTSignIn.authorizeURL(state: pending.state, nonce: pending.nonce, challenge: challenge, hostID: try hostID())
        case .antigravity: AntigravitySignIn.authorizeURL(redirect: redirect, state: pending.state, challenge: challenge)
        }
        state.withLockedValue { state in
            let now = pending.started
            state.pending = state.pending.filter { now - $0.value.started < Self.pendingLimit }
            state.pending[id] = pending
        }
        return (id, url, redirect)
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
            throw SignInError(message: "the sign-in was refused: \(query["error_description"] ?? error)")
        }
        guard let code = query["code"], !code.isEmpty else {
            throw SignInError(message: "the address has no `code`: paste the whole address the browser ended on")
        }
        guard query["state"] == pending.state else {
            throw SignInError(message: "the address belongs to another sign-in: paste the one this sign-in ended on")
        }
        let credentials: SignInCredentials
        switch pending.kind {
        case .chatgpt:
            guard let clientID = query["client_id"], !clientID.isEmpty else {
                throw SignInError(message: "the address has no `client_id`: OpenAI did not finish registering the gateway; start again")
            }
            credentials = try await ChatGPTSignIn.exchange(
                code: code, clientID: clientID, verifier: pending.verifier, nonce: pending.nonce, transport: transport,
            )
        case .antigravity:
            credentials = try await AntigravitySignIn.exchange(
                code: code, verifier: pending.verifier, redirect: pending.redirect, transport: transport,
            )
        }
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
        try await OAuthForm.post(form, authority: tokenAuthority, path: tokenPath, who: "OpenAI", dead: deadRefresh, transport: transport)
    }
}

/// A form posted to an OAuth token endpoint, and its JSON reply.
enum OAuthForm {
    /// The longest a token request may take.
    static let timeout: Duration = .seconds(30)

    /// `dead`: error codes that mean the account must sign in again.
    static func post(
        _ form: [(String, String)], authority: String, path: String, who: String, dead: Set<String>, transport: any HTTPTransport,
    ) async throws(SignInError) -> JSONValue {
        var request = HTTPRequest(method: .post, scheme: "https", authority: authority, path: path)
        request.headerFields[.contentType] = "application/x-www-form-urlencoded"
        request.headerFields[.accept] = "application/json"
        let status: Int
        let bytes: [UInt8]
        do {
            let sent = request
            (status, bytes) = try await within(timeout) {
                let response = try await transport.send(sent, body: Array(FormEncoding.encode(form).utf8))
                return (response.status.code, try await response.body.collect(upTo: 1 << 20))
            }
        } catch is TimedOut {
            throw SignInError(message: "\(who)'s sign-in did not answer within \(timeout)")
        } catch {
            throw SignInError(message: "cannot reach \(who)'s sign-in: \(error)")
        }
        let reply = (try? JSONValue(parsing: bytes)) ?? .null
        guard status == 200 else {
            let code = reply["error"]?.stringValue ?? reply["error"]?["code"]?.stringValue ?? reply["code"]?.stringValue ?? ""
            let message = reply["error_description"]?.stringValue ?? reply["error"]?["message"]?.stringValue ?? "HTTP \(status)"
            throw SignInError(
                message: "\(who) refused the token request (\(code.isEmpty ? "\(status)" : code)): \(message)",
                needsSignIn: dead.contains(code),
            )
        }
        return reply
    }
}
