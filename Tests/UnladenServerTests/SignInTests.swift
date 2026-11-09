import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// An unsigned JSON Web Token carrying `claims`.
private func token(_ claims: JSONValue) -> String {
    "e30." + Base64URL.encode(claims.encoded()) + ".c2ln"
}

private func tokenReply(access: String, refresh: String, idToken: String? = nil, scope: String = ChatGPTSignIn.scopes) -> HTTPTransportResponse {
    var object: JSONObject = [
        "access_token": .string(access), "refresh_token": .string(refresh), "expires_in": 3600, "scope": .string(scope),
    ]
    if let idToken { object["id_token"] = .string(idToken) }
    return reply(String(decoding: JSONValue.object(object).encoded(), as: UTF8.self))
}

private func temporaryDirectory() -> String {
    let path = NSTemporaryDirectory() + "unladen-sign-in-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Suite struct SignInEncodingTests {
    @Test func sha256MatchesKnownDigests() {
        func hex(_ text: String) -> String { SHA256.hash(Array(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(String(repeating: "a", count: 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func pkceChallengeMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(Base64URL.encode(SHA256.hash(Array(verifier.utf8))) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func base64URLRoundTrips() {
        for count in 0..<8 {
            let bytes = (0..<count).map { UInt8(($0 * 37 + 200) & 0xff) }
            #expect(Base64URL.decode(Base64URL.encode(bytes)) == bytes)
        }
        #expect(Base64URL.encode(Array("hi?".utf8)) == "aGk_")
    }

    @Test func formEncodingRoundTrips() {
        let pairs = [("redirect_uri", "http://127.0.0.1:1455/auth/callback"), ("scope", "openid email"), ("x", "a&b=c+ü")]
        let encoded = FormEncoding.encode(pairs)
        #expect(encoded.contains("scope=openid%20email"))
        let decoded = FormEncoding.decode(encoded)
        for (name, value) in pairs { #expect(decoded[name] == value) }
        #expect(FormEncoding.decode("a=1+2&b=%2F")["a"] == "1 2")
    }

    @Test func aPastedAddressGivesItsQuery() {
        let query = ChatGPTSignIn.query(of: "  http://127.0.0.1:1455/auth/callback?code=abc&state=xyz&client_id=app_1#frag \n")
        #expect(query == ["code": "abc", "state": "xyz", "client_id": "app_1"])
    }
}

@Suite struct SignInConfigTests {
    @Test func aChatGPTAccountSignsIn() throws {
        let loaded = try ConfigFile.parse(#"{"accounts": {"chatgpt": {}, "work": {"provider": "chatgpt"}}}"#, file: "c.jsonc") { _ in nil }
        let keys = try #require(loaded.gateway.keyPools["chatgpt"]?.keys)
        #expect(keys.map(\.name) == ["chatgpt", "work"])
        #expect(keys.allSatisfy { $0.signIn == .chatgpt && $0.secret.isEmpty })
    }

    @Test func aChatGPTAccountMayHoldAKeyInstead() throws {
        let text = #"{"accounts": {"chatgpt": "sk-1", "me": {"provider": "chatgpt"}, "team": {"provider": "chatgpt", "key": "sk-2"}}}"#
        let keys = try #require(try ConfigFile.parse(text, file: "c.jsonc") { _ in nil }.gateway.keyPools["chatgpt"]?.keys)
        #expect(keys.map(\.name) == ["chatgpt", "me", "team"])
        #expect(keys.map(\.signIn) == [nil, .chatgpt, nil])
        #expect(keys.map(\.secret) == ["sk-1", "", "sk-2"])
    }

    @Test func theSignInProviderIsNotRedefined() {
        for text in [
            #"{"accounts": {"chatgpt": {"endpoints": {"responses": "https://proxy.example/v1"}, "key": "sk-1"}}}"#,
            #"{"accounts": {"chatgpt": {"preset": "openai", "key": "sk-1"}}}"#,
            #"{"accounts": {"anthropic": {"provider": "chatgpt"}}}"#,
        ] {
            #expect(throws: ConfigError.self, "\(text)") { try ConfigFile.parse(text, file: "c.jsonc") { _ in nil } }
        }
    }

    @Test func theEnvironmentGivesAKey() throws {
        let loaded = try ConfigFile.parse("{}", file: "c.jsonc") { $0 == "UNLADEN_CHATGPT_API_KEY" ? "sk-1" : nil }
        #expect(loaded.gateway.keyPools["chatgpt"]?.keys.map(\.signIn) == [nil])
    }

    @Test func candidatesOfASignedInAccountCarryNoKey() throws {
        var configuration = GatewayConfiguration()
        configuration.keyPools["chatgpt"] = KeyPool(keys: [UpstreamKey(signingIn: "me", .chatgpt)])
        let candidates = try CandidatePlanner(configuration: configuration).candidates(for: "chatgpt/gpt-5", clientProtocol: .responses)
        let candidate = try #require(candidates.first)
        #expect(candidate.apiKey == nil && candidate.keyName == "me" && candidate.signIn == .chatgpt)
    }
}

@Suite struct SignInFlowTests {
    @Test func signingInKeepsTheTokens() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let signIns = SignIns(directory: directory)
        let started = try signIns.start(provider: "chatgpt", account: "me")
        let query = ChatGPTSignIn.query(of: started.url)
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["redirect_uri"] == ChatGPTSignIn.redirect)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true)
        let nonce = try #require(query["nonce"])
        let state = try #require(query["state"])

        let idToken = token([
            "iss": "https://auth.openai.com", "aud": ["app_1"], "nonce": .string(nonce), "email": "me@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ])
        let upstream = MockUpstream { _ in tokenReply(access: "access-1", refresh: "refresh-1", idToken: idToken) }
        let callback = "http://127.0.0.1:1455/auth/callback?code=the-code&state=\(state)&client_id=app_1"
        let (provider, account, credentials) = try await signIns.finish(id: started.id, callback: callback, transport: upstream.transport)
        #expect(provider == "chatgpt" && account == "me")
        #expect(credentials.user == "me@example.com" && credentials.plan == "plus" && credentials.access == "access-1")

        let hit = try #require(upstream.requests.first)
        #expect(hit.request.authority == "auth.openai.com" && hit.path == "/api/accounts/oauth/token")
        let form = FormEncoding.decode(String(decoding: hit.body, as: UTF8.self))
        #expect(form["grant_type"] == "authorization_code" && form["code"] == "the-code" && form["client_id"] == "app_1")
        #expect(form["code_challenge"] == nil)
        let challenge = Base64URL.encode(SHA256.hash(Array((form["code_verifier"] ?? "").utf8)))
        #expect(challenge == query["code_challenge"])

        // Kept in the file, private, and read back by another store.
        let path = directory + "/logins.json"
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions.map { $0 & 0o777 } == 0o600)
        #expect(SignIns(directory: directory).credentials(provider: "chatgpt", account: "me") == credentials)
        // The machine's id stays the same.
        let again = ChatGPTSignIn.query(of: try signIns.start(provider: "chatgpt", account: "me").url)
        #expect(again["ext_agent_host_id"] == query["ext_agent_host_id"])
    }

    @Test func aWriteKeepsWhatAnotherProcessWrote() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let gateway = SignIns(directory: directory)
        let commandLine = SignIns(directory: directory)
        let first = SignInCredentials(clientID: "app", access: "a1", refresh: "r1", expires: 1, user: "a")
        try gateway.keep(first, provider: "chatgpt", account: "a")
        // The command line signs `b` in, holding a store read earlier.
        try commandLine.keep(SignInCredentials(clientID: "app", access: "b", refresh: "rb", expires: 1, user: "b"), provider: "chatgpt", account: "b")
        // The gateway refreshes `a` meanwhile; then reloads.
        var refreshed = first
        refreshed.refresh = "r2"
        try gateway.keep(refreshed, provider: "chatgpt", account: "a")
        gateway.load()
        #expect(gateway.credentials(provider: "chatgpt", account: "a")?.refresh == "r2")
        #expect(gateway.credentials(provider: "chatgpt", account: "b") != nil)
        commandLine.load()
        #expect(commandLine.credentials(provider: "chatgpt", account: "a")?.refresh == "r2")
    }

    @Test func anotherSignInsAddressIsRefused() async throws {
        let signIns = SignIns()
        let started = try signIns.start(provider: "chatgpt", account: "me")
        let upstream = MockUpstream { _ in tokenReply(access: "a", refresh: "r") }
        await #expect(throws: SignInError.self) {
            _ = try await signIns.finish(id: started.id, callback: "?code=c&state=other&client_id=app", transport: upstream.transport)
        }
        await #expect(throws: SignInError.self) {
            _ = try await signIns.finish(id: "unknown", callback: "?code=c&state=s&client_id=app", transport: upstream.transport)
        }
        #expect(upstream.requests.isEmpty)
    }

    @Test func aTokenWithoutTheDirectScopeIsRefused() async throws {
        let signIns = SignIns()
        let started = try signIns.start(provider: "chatgpt", account: "me")
        let query = ChatGPTSignIn.query(of: started.url)
        let idToken = token(["iss": "https://auth.openai.com", "aud": "app", "nonce": .string(query["nonce"]!), "sub": "u"])
        let upstream = MockUpstream { _ in tokenReply(access: "a", refresh: "r", idToken: idToken, scope: "openid email") }
        let error = await #expect(throws: SignInError.self) {
            _ = try await signIns.finish(id: started.id, callback: "?code=c&state=\(query["state"]!)&client_id=app", transport: upstream.transport)
        }
        #expect(error?.message.contains("chatgpt.tokens.use.direct") == true)
        #expect(signIns.credentials(provider: "chatgpt", account: "me") == nil)
    }
}

@Suite struct SignInRefreshTests {
    private func signedIn(expiresIn milliseconds: Int64) throws -> SignIns {
        let signIns = SignIns()
        try signIns.keep(
            SignInCredentials(clientID: "app", access: "old", refresh: "refresh-0", expires: LocalDay.nowMilliseconds() + milliseconds, user: "me"),
            provider: "chatgpt", account: "me",
        )
        return signIns
    }

    @Test func aFreshTokenIsUsedAsItIs() async throws {
        let signIns = try signedIn(expiresIn: 3_600_000)
        let upstream = MockUpstream { _ in tokenReply(access: "new", refresh: "refresh-1") }
        #expect(try await signIns.token(provider: "chatgpt", account: "me", transport: upstream.transport) == "old")
        #expect(upstream.requests.isEmpty)
    }

    @Test func anExpiringTokenIsRefreshedOnceForEveryone() async throws {
        let signIns = try signedIn(expiresIn: 60_000)
        let upstream = MockUpstream { _ in
            try await Task.sleep(for: .milliseconds(50))
            return tokenReply(access: "new", refresh: "refresh-1")
        }
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await signIns.token(provider: "chatgpt", account: "me", transport: upstream.transport) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "new", count: 5))
        #expect(upstream.requests.count == 1)
        let form = FormEncoding.decode(String(decoding: upstream.requests[0].body, as: UTF8.self))
        #expect(form["grant_type"] == "refresh_token" && form["refresh_token"] == "refresh-0" && form["client_id"] == "app")
        #expect(signIns.credentials(provider: "chatgpt", account: "me")?.refresh == "refresh-1")
    }

    @Test func aDeadRefreshTokenAsksForASignIn() async throws {
        let signIns = try signedIn(expiresIn: 0)
        let upstream = MockUpstream { _ in reply(status: .badRequest, #"{"error": "invalid_grant", "error_description": "reused"}"#) }
        let error = await #expect(throws: SignInError.self) {
            _ = try await signIns.token(provider: "chatgpt", account: "me", transport: upstream.transport)
        }
        #expect(error?.needsSignIn == true)
        #expect(signIns.credentials(provider: "chatgpt", account: "me")?.lapsed != nil)
        // No further refresh is tried.
        _ = try? await signIns.token(provider: "chatgpt", account: "me", transport: upstream.transport)
        #expect(upstream.requests.count == 1)
    }

    @Test func aPassingFailureKeepsTheTokenInHand() async throws {
        let signIns = try signedIn(expiresIn: 60_000)
        let upstream = MockUpstream { _ in reply(status: .badGateway, "down") }
        #expect(try await signIns.token(provider: "chatgpt", account: "me", transport: upstream.transport) == "old")
        #expect(signIns.credentials(provider: "chatgpt", account: "me")?.lapsed == nil)
    }
}

@Suite struct SignInGatewayTests {
    /// A gateway serving `chatgpt/*` through the signed-in account `me`.
    private func gateway(_ upstream: MockUpstream, expiresIn milliseconds: Int64 = 3_600_000) throws -> Gateway {
        var gateway = makeGateway(upstream, model: "chatgpt/gpt-5", keys: [:])
        var configuration = gateway.configuration
        configuration.keyPools["chatgpt"] = KeyPool(keys: [UpstreamKey(signingIn: "me", .chatgpt)])
        gateway.configuration = configuration
        gateway.signIns = SignIns()
        try gateway.signIns.keep(
            SignInCredentials(clientID: "app", access: "old", refresh: "refresh-0", expires: LocalDay.nowMilliseconds() + milliseconds, user: "me"),
            provider: "chatgpt", account: "me",
        )
        return gateway
    }

    @Test func aRequestCarriesTheAccountsToken() async throws {
        let upstream = MockUpstream { _ in reply(headers: [.contentType: "text/event-stream"], fixture("Responses/streams/text.sse")) }
        try await makeApp(try gateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/responses", ClientRequest.responses(model: "gpt-5"))
            #expect(response.status == .ok)
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.request.authority == "api.openai.com" && hit.path == "/v1/responses")
        #expect(hit.header("authorization") == "Bearer old")
        #expect(hit.json["store"] == false)
    }

    @Test func aTokenTurnedAwayIsRefreshedAndTriedAgain() async throws {
        let upstream = MockUpstream { hit in
            if hit.request.authority == "auth.openai.com" { return tokenReply(access: "new", refresh: "refresh-1") }
            if hit.header("authorization") == "Bearer old" { return reply(status: .unauthorized, #"{"error": {"message": "expired"}}"#) }
            return reply(headers: [.contentType: "text/event-stream"], fixture("Responses/streams/text.sse"))
        }
        try await makeApp(try gateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/responses", ClientRequest.responses(model: "gpt-5"))
            #expect(response.status == .ok)
        }
        #expect(upstream.requests.map { $0.header("authorization") ?? "token" } == ["Bearer old", "token", "Bearer new"])
    }

    @Test func anAccountNotSignedInIsReported() async throws {
        let upstream = MockUpstream { _ in reply("{}") }
        var gateway = try gateway(upstream)
        gateway.signIns = SignIns()
        try await makeApp(gateway).test(.router) { client in
            let response = try await client.post("/v1/responses", ClientRequest.responses(model: "gpt-5"))
            #expect(response.status == .unauthorized)
            #expect(String(buffer: response.body).contains("has not signed in"))
        }
        #expect(upstream.requests.isEmpty)
    }
}
