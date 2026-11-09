import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// A Gemini SSE fixture as Code Assist sends it: each event in an envelope.
private func wrappedStream(_ path: String) -> [UInt8] {
    let text = String(decoding: fixture(path), as: UTF8.self)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard line.hasPrefix("data:") else { return String(line) }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return "data: {\"response\":" + payload + ",\"traceId\":\"t\"}"
    }
    return Array(lines.joined(separator: "\n").utf8)
}

@Suite struct AntigravityConfigTests {
    @Test func anAntigravityAccountSignsIn() throws {
        let loaded = try ConfigFile.parse(#"{"accounts": {"antigravity": {}}}"#, file: "c.jsonc") { _ in nil }
        #expect(loaded.gateway.keyPools["antigravity"]?.keys.map(\.signIn) == [.antigravity])
    }

    @Test func anAntigravityAccountHoldsNoKey() {
        for text in [#"{"accounts": {"antigravity": "k"}}"#, #"{"accounts": {"me": {"provider": "antigravity", "key": "k"}}}"#] {
            #expect(throws: ConfigError.self, "\(text)") { try ConfigFile.parse(text, file: "c.jsonc") { _ in nil } }
        }
    }
}

@Suite struct AntigravitySignInTests {
    @Test func signingInFindsTheAccountsProject() async throws {
        let signIns = SignIns()
        let started = try signIns.start(provider: "antigravity", account: "me")
        let query = ChatGPTSignIn.query(of: started.url)
        #expect(started.url.hasPrefix(AntigravitySignIn.authorizeEndpoint))
        #expect(query["client_id"] == AntigravitySignIn.clientID)
        #expect(AntigravitySignIn.clientID.hasSuffix(".apps.googleusercontent.com") && AntigravitySignIn.clientSecret.count == 35)
        #expect(query["access_type"] == "offline" && query["code_challenge_method"] == "S256")
        #expect(query["redirect_uri"] == started.redirect && started.redirect.hasPrefix("http://localhost:"))

        let upstream = MockUpstream { hit in
            switch hit.request.authority {
            case "oauth2.googleapis.com":
                return reply(#"{"access_token": "ya29.a", "refresh_token": "1//r", "expires_in": 3599}"#)
            case "www.googleapis.com":
                return reply(#"{"email": "me@example.com"}"#)
            default:
                // loadCodeAssist without a project, then onboardUser.
                if hit.path.hasSuffix("loadCodeAssist") {
                    return reply(#"{"currentTier": {"id": "free-tier", "name": "Antigravity Free"}, "allowedTiers": [{"id": "free-tier", "isDefault": true}]}"#)
                }
                return reply(#"{"done": true, "response": {"cloudaicompanionProject": {"id": "proj-1"}}}"#)
            }
        }
        let callback = started.redirect + "?state=" + query["state"]! + "&code=4/c&scope=email"
        let (_, _, credentials) = try await signIns.finish(id: started.id, callback: callback, transport: upstream.transport)
        #expect(credentials.user == "me@example.com" && credentials.project == "proj-1" && credentials.plan == "Antigravity Free")

        let exchange = FormEncoding.decode(String(decoding: upstream.requests[0].body, as: UTF8.self))
        #expect(exchange["client_secret"] == AntigravitySignIn.clientSecret && exchange["redirect_uri"] == started.redirect)
        let load = try #require(upstream.requests.first { $0.path.hasSuffix("loadCodeAssist") })
        #expect(load.request.authority == CodeAssist.productionAuthority && load.json["metadata"]?["ideType"] == "ANTIGRAVITY")
        let onboard = try #require(upstream.requests.first { $0.path.hasSuffix("onboardUser") })
        #expect(onboard.request.authority == CodeAssist.dailyAuthority && onboard.json["tier_id"] == "free-tier")
    }

    @Test func aRefreshKeepsTheRefreshToken() async throws {
        let signIns = SignIns()
        var credentials = SignInCredentials(clientID: AntigravitySignIn.clientID, access: "old", refresh: "1//r", expires: 0, user: "me")
        credentials.project = "proj-1"
        try signIns.keep(credentials, provider: "antigravity", account: "me")
        let upstream = MockUpstream { _ in reply(#"{"access_token": "new", "expires_in": 3599}"#) }
        #expect(try await signIns.token(provider: "antigravity", account: "me", transport: upstream.transport) == "new")
        let stored = signIns.credentials(provider: "antigravity", account: "me")
        #expect(stored?.refresh == "1//r" && stored?.project == "proj-1")
    }
}

@Suite struct CodeAssistFitTests {
    @Test func aGeminiRequestIsFitted() {
        let request = json(#"""
        {"systemInstruction": {"parts": [{"text": "Be brief."}]},
         "contents": [
           {"role": "model", "parts": [{"text": "hm", "thought": true}, {"functionCall": {"id": "call:1", "name": "look", "args": {}}}]},
           {"role": "user", "parts": [{"functionResponse": {"id": "call:1", "name": "look", "response": {"output": "sunny"}}}]}],
         "tools": [{"functionDeclarations": [{"name": "look", "parametersJsonSchema":
           {"type": "object", "additionalProperties": false, "properties": {"city": {"type": ["string", "null"], "format": "x"}}, "required": ["city", "gone"]}}]}],
         "generationConfig": {"maxOutputTokens": 100, "temperature": 0.5}}
        """#)
        let fitted = CodeAssist.fit(request, model: "gemini-3-flash")
        #expect(fitted["systemInstruction"]?["role"] == "user")
        let contents = fitted["contents"]?.arrayValue ?? []
        // A user turn first; the thought dropped; ids made plain; `result`.
        #expect(contents.first?["role"] == "user")
        #expect(contents[1]["parts"]?.arrayValue?.count == 1)
        #expect(contents[1]["parts"]?[0]?["functionCall"]?["id"] == "call_1")
        #expect(contents[2]["parts"]?[0]?["functionResponse"]?["response"] == ["result": "sunny"])
        let declaration = fitted["tools"]?[0]?["functionDeclarations"]?[0]
        #expect(declaration?["parametersJsonSchema"] == nil)
        #expect(declaration?["parameters"] == json(#"{"type": "object", "properties": {"city": {"type": "string", "nullable": true}}, "required": ["city"]}"#))
        // Gemini models take no output limit.
        #expect(fitted["generationConfig"] == ["temperature": 0.5])
        #expect(fitted["sessionId"]?.stringValue?.hasPrefix("-") == true)
    }

    @Test func claudeKeepsItsLimitAndThinking() {
        let request = json(#"{"contents": [{"role": "user", "parts": [{"text": "Hi"}]}], "generationConfig": {"thinkingConfig": {"thinkingBudget": 4096}}}"#)
        let fitted = CodeAssist.fit(request, model: "claude-opus-4-6-thinking")
        #expect(fitted["generationConfig"]?["maxOutputTokens"] == 36096)
        #expect(fitted["generationConfig"]?["thinkingConfig"]?["includeThoughts"] == true)
        let plain = CodeAssist.fit(request, model: "claude-sonnet-4-6")
        #expect(plain["generationConfig"]?["thinkingConfig"] == nil)
    }

    @Test func theSessionStaysWithTheConversation() {
        let first = json(#"{"contents": [{"role": "user", "parts": [{"text": "Hi"}]}]}"#)
        let later = json(#"{"contents": [{"role": "user", "parts": [{"text": "Hi"}]}, {"role": "model", "parts": [{"text": "Hello"}]}, {"role": "user", "parts": [{"text": "More"}]}]}"#)
        #expect(CodeAssist.fit(first, model: "m")["sessionId"] == CodeAssist.fit(later, model: "m")["sessionId"])
    }

    @Test func schemasAreReducedToWhatCodeAssistTakes() {
        let schema = json(#"""
        {"$defs": {"Item": {"type": "object", "properties": {"n": {"const": 3}}}},
         "type": "object",
         "properties": {
           "items": {"type": "array", "items": {"$ref": "#/$defs/Item"}},
           "mode": {"anyOf": [{"type": "null"}, {"type": "string", "enum": ["a", " "]}]},
           "count": {"type": "integer", "exclusiveMinimum": 0, "default": 1},
           "list": {"type": "array"}}}
        """#)
        let plain = PlainSchema.convert(schema)
        #expect(plain["$defs"] == nil)
        // Only string values can be an enum.
        #expect(plain["properties"]?["items"]?["items"] == json(#"{"type": "object", "properties": {"n": {}}}"#))
        #expect(plain["properties"]?["mode"] == json(#"{"nullable": true, "type": "string", "enum": ["a"]}"#))
        #expect(plain["properties"]?["count"] == json(#"{"type": "integer", "minimum": 0}"#))
        #expect(plain["properties"]?["list"] == json(#"{"type": "array", "items": {}}"#))
    }

    @Test func modelsAreListedInAntigravitysOrder() {
        let reply = json(#"""
        {"models": {"gemini-3-flash": {}, "claude-sonnet-4-6": {}, "chat_20706": {}, "tab_x": {}, "gone": {"disabled": true}, "gpt-oss-120b-medium": {}},
         "agentModelSorts": [{"groups": [{"modelIds": ["claude-sonnet-4-6", "gemini-3-flash"]}]}]}
        """#)
        #expect(CodeAssist.modelIDs(reply) == ["claude-sonnet-4-6", "gemini-3-flash", "gpt-oss-120b-medium"])
    }
}

@Suite struct CodeAssistGatewayTests {
    private func gateway(_ upstream: MockUpstream) throws -> Gateway {
        var gateway = makeGateway(upstream, model: nil, routes: [Route(name: "gemini-*", targets: [RouteTarget(model: "antigravity/$model")])], keys: [:])
        var configuration = gateway.configuration
        configuration.keyPools["antigravity"] = KeyPool(keys: [UpstreamKey(signingIn: "me", .antigravity)])
        gateway.configuration = configuration
        gateway.signIns = SignIns()
        var credentials = SignInCredentials(
            clientID: AntigravitySignIn.clientID, access: "ya29.a", refresh: "1//r", expires: LocalDay.nowMilliseconds() + 3_600_000, user: "me",
        )
        credentials.project = "proj-1"
        try gateway.signIns.keep(credentials, provider: "antigravity", account: "me")
        return gateway
    }

    @Test func aRequestGoesThroughCodeAssist() async throws {
        let upstream = MockUpstream { _ in reply(headers: [.contentType: "text/event-stream"], wrappedStream("Gemini/streams/text.sse")) }
        try await makeApp(try gateway(upstream)).test(.router) { client in
            let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "gemini-3-flash"))
            #expect(response.status == .ok)
            #expect(!replyText(response.body, as: .chatCompletions).isEmpty)
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.request.authority == CodeAssist.dailyAuthority)
        #expect(hit.path == "/v1internal:streamGenerateContent?alt=sse")
        #expect(hit.header("authorization") == "Bearer ya29.a")
        #expect(hit.header("user-agent")?.hasPrefix("antigravity/hub/") == true)
        #expect(hit.json["model"] == "gemini-3-flash" && hit.json["project"] == "proj-1" && hit.json["requestType"] == "agent")
        #expect(hit.json["request"]?["contents"]?[0]?["parts"]?[0]?["text"] == "Hi")
    }

    @Test func theModelListComesFromCodeAssist() async throws {
        let upstream = MockUpstream { _ in reply(#"{"models": {"gemini-3-flash": {}, "claude-sonnet-4-6": {}}}"#) }
        try await makeApp(try gateway(upstream)).test(.router) { client in
            let response = try await client.executeRequest(uri: "/v1/models", method: .get, headers: [:], body: nil)
            #expect(json(response.body)["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["gemini-3-flash"])
        }
        let hit = try #require(upstream.requests.first)
        #expect(hit.request.method == .post && hit.path == "/v1internal:fetchAvailableModels" && hit.json == ["project": "proj-1"])
    }
}
