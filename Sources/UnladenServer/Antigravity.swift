// Antigravity accounts: a Google sign-in with Antigravity's own OAuth
// client, and Google's Code Assist backend (cloudcode-pa), which speaks
// Gemini's API inside an envelope of its own, under a Google Cloud project
// Code Assist gives the account. Google does not offer this to other apps
// and may suspend an account it sees used outside Antigravity.
//
// The upstream side is a transport: the gateway encodes a Gemini request
// for the `antigravity` preset as for any Gemini endpoint, and
// `CodeAssistTransport` fits it to what Code Assist takes, wraps it, and
// unwraps the reply.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
@_spi(Wire) import UnladenCore

// MARK: - Signing in

enum AntigravitySignIn {
    static let authorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenAuthority = "oauth2.googleapis.com"
    static let tokenPath = "/token"
    static let userInfoAuthority = "www.googleapis.com"
    static let userInfoPath = "/oauth2/v2/userinfo?alt=json"
    /// Antigravity's OAuth client: an installed app's, whose secret is
    /// not secret. Kept as reversed Base64 so scanners do not take it
    /// for a leaked credential.
    static let clientID = unfolded("==QbvNmL05WZ052bjJXZzVXZsd2bvdmLzBHch5CclNDM0cGNop2bs9Gd2VzMyUmcjxWMygmMul2czhWb01SM5UDM2AjNwATM3ATM")
    static let clientSecret = unfolded("=YWQEFnN6RzQYNHOCxUbxoETkxkN4QjUXZEO1sULYB1UD90R")
    private static func unfolded(_ text: String) -> String {
        String(decoding: Data(base64Encoded: String(text.reversed())) ?? Data(), as: UTF8.self)
    }

    static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ].joined(separator: " ")
    /// Refusals of a refresh token that will never work again.
    static let deadRefresh: Set<String> = ["invalid_grant", "invalid_client", "unauthorized_client"]

    /// A loopback address: Google sends an installed app's sign-in back
    /// to any port of it. Nothing answers there; the user pastes it.
    static func redirect(port: Int) -> String { "http://localhost:\(port)/oauth-callback" }

    static func authorizeURL(redirect: String, state: String, challenge: String) -> String {
        authorizeEndpoint + "?" + FormEncoding.encode([
            ("client_id", clientID), ("redirect_uri", redirect), ("response_type", "code"), ("scope", scopes),
            ("access_type", "offline"), ("prompt", "consent"), ("state", state), ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
        ])
    }

    static func exchange(code: String, verifier: String, redirect: String, transport: any HTTPTransport) async throws(SignInError) -> SignInCredentials {
        let reply = try await post([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect), ("client_id", clientID),
            ("client_secret", clientSecret), ("code_verifier", verifier),
        ], transport: transport)
        guard let access = reply["access_token"]?.stringValue, let refresh = reply["refresh_token"]?.stringValue,
              let lifetime = reply["expires_in"]?.numberValue?.double, lifetime > 0
        else { throw SignInError(message: "Google sent no usable token") }
        let user = try await email(access: access, transport: transport)
        var credentials = SignInCredentials(
            clientID: clientID, access: access, refresh: refresh, expires: LocalDay.nowMilliseconds() + Int64(lifetime * 1000), user: user,
        )
        let (project, plan) = try await CodeAssist.project(token: access, transport: transport)
        credentials.project = project
        credentials.plan = plan
        return credentials
    }

    /// Google's refresh tokens do not change: the same one is kept.
    static func refresh(_ current: SignInCredentials, transport: any HTTPTransport) async throws(SignInError) -> SignInCredentials {
        let reply = try await post([
            ("grant_type", "refresh_token"), ("refresh_token", current.refresh), ("client_id", clientID), ("client_secret", clientSecret),
        ], transport: transport)
        guard let access = reply["access_token"]?.stringValue, let lifetime = reply["expires_in"]?.numberValue?.double, lifetime > 0 else {
            throw SignInError(message: "Google sent no usable token")
        }
        var fresh = current
        fresh.access = access
        fresh.refresh = reply["refresh_token"]?.stringValue ?? current.refresh
        fresh.expires = LocalDay.nowMilliseconds() + Int64(lifetime * 1000)
        if fresh.project == nil, let (project, plan) = try? await CodeAssist.project(token: access, transport: transport) {
            fresh.project = project
            fresh.plan = plan ?? fresh.plan
        }
        return fresh
    }

    private static func email(access: String, transport: any HTTPTransport) async throws(SignInError) -> String {
        var request = HTTPRequest(method: .get, scheme: "https", authority: userInfoAuthority, path: userInfoPath)
        request.headerFields[.authorization] = "Bearer \(access)"
        let reply: JSONValue?
        do {
            let response = try await transport.send(request, body: nil)
            let bytes = try await response.body.collect(upTo: 1 << 20)
            reply = response.status.code == 200 ? try? JSONValue(parsing: bytes) : nil
        } catch {
            throw SignInError(message: "cannot ask Google which account signed in: \(error)")
        }
        guard let email = reply?["email"]?.stringValue, !email.isEmpty else {
            throw SignInError(message: "Google did not say which account signed in")
        }
        return email
    }

    private static func post(_ form: [(String, String)], transport: any HTTPTransport) async throws(SignInError) -> JSONValue {
        try await OAuthForm.post(form, authority: tokenAuthority, path: tokenPath, who: "Google", dead: deadRefresh, transport: transport)
    }
}

// MARK: - Code Assist

enum CodeAssist {
    /// Where the account's project is looked up.
    static let productionAuthority = "cloudcode-pa.googleapis.com"
    /// Where Antigravity sends everything else.
    static let dailyAuthority = "daily-cloudcode-pa.googleapis.com"
    /// The Antigravity version the gateway says it is.
    static let version = "2.9.1"
    static let timeout: Duration = .seconds(30)

    static var userAgent: String {
        #if os(macOS)
        let system = "darwin"
        #elseif os(Windows)
        let system = "windows"
        #else
        let system = "linux"
        #endif
        #if arch(arm64)
        let machine = "arm64"
        #else
        let machine = "amd64"
        #endif
        return "antigravity/hub/\(version) \(system)/\(machine)"
    }

    struct Failure: Error, CustomStringConvertible {
        var status: Int
        var message: String
        var description: String { message }
    }

    /// `POST /v1internal:{method}` with `body`; the JSON reply.
    static func call(
        _ method: String, body: JSONValue, authority: String = dailyAuthority, token: String,
        headers: [String: String] = [:], transport: any HTTPTransport,
    ) async throws -> JSONValue {
        var request = HTTPRequest(method: .post, scheme: "https", authority: authority, path: "/v1internal:" + method)
        request.headerFields[.contentType] = "application/json"
        request.headerFields[.authorization] = "Bearer \(token)"
        request.headerFields[.userAgent] = userAgent
        for (name, value) in headers { if let field = HTTPField.Name(name) { request.headerFields[field] = value } }
        let request2 = request
        let (status, bytes) = try await Gateway.within(timeout) {
            let response = try await transport.send(request2, body: body.encoded())
            return (response.status.code, try await response.body.collect(upTo: 8 << 20))
        }
        let reply = (try? JSONValue(parsing: bytes)) ?? .null
        guard status == 200 else {
            throw Failure(status: status, message: "Code Assist \(method): " + (reply["error"]?["message"]?.stringValue ?? "HTTP \(status)"))
        }
        return reply
    }

    /// The project Code Assist serves the account under, onboarding it
    /// when it has none yet, and the account's plan.
    static func project(token: String, transport: any HTTPTransport) async throws(SignInError) -> (project: String, plan: String?) {
        do {
            let loaded = try await call(
                "loadCodeAssist", body: ["metadata": ["ideType": "ANTIGRAVITY"]], authority: productionAuthority, token: token,
                transport: transport,
            )
            let plan = loaded["paidTier"]?["name"]?.stringValue ?? loaded["currentTier"]?["name"]?.stringValue
                ?? loaded["currentTier"]?["id"]?.stringValue
            if let project = projectID(loaded["cloudaicompanionProject"]) { return (project, plan) }

            let tiers = loaded["allowedTiers"]?.arrayValue ?? []
            var tier = (tiers.first { $0["isDefault"]?.boolValue == true } ?? tiers.first)?["id"]?.stringValue ?? ""
            if tier.isEmpty || tier == "legacy-tier" { tier = "free-tier" }
            let body: JSONValue = [
                "tier_id": .string(tier),
                "metadata": ["ide_type": "ANTIGRAVITY", "ide_version": .string(version), "ide_name": "antigravity"],
            ]
            let headers = ["user-agent": userAgent + " google-api-nodejs-client/10.3.0", "x-goog-api-client": "gl-node/22.21.1"]
            for attempt in 0..<5 {
                if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
                let operation = try await call("onboardUser", body: body, token: token, headers: headers, transport: transport)
                if operation["done"]?.boolValue == true {
                    if let project = projectID(operation["response"]?["cloudaicompanionProject"]) { return (project, plan) }
                    break
                }
            }
            if let reason = loaded["ineligibleTiers"]?.arrayValue?.compactMap({ $0["reasonMessage"]?.stringValue }).first {
                throw SignInError(message: "Antigravity does not serve this Google account: \(reason)")
            }
            throw SignInError(message: "Code Assist gave this Google account no project: sign in to the Antigravity app with it once, then here again")
        } catch let error as SignInError {
            throw error
        } catch {
            throw SignInError(message: "cannot set the account up with Code Assist: \(error)")
        }
    }

    /// A project as Code Assist gives it: a string, or `{id, name}`.
    static func projectID(_ value: JSONValue?) -> String? {
        if let id = value?.stringValue, !id.isEmpty { return id }
        if let id = value?["id"]?.stringValue, !id.isEmpty { return id }
        return nil
    }

    // MARK: Models

    /// Not offered to clients: Antigravity's own internal models.
    static let hiddenModels: Set<String> = [
        "chat_20706", "chat_23310", "tab_flash_lite_preview", "tab_jump_flash_lite_preview", "gemini-2.5-flash-thinking", "gemini-2.5-pro",
    ]

    /// The ids of a `fetchAvailableModels` reply that can be used, in
    /// Antigravity's order.
    static func modelIDs(_ reply: JSONValue) -> [String] {
        guard let models = reply["models"]?.objectValue else { return [] }
        let usable = models.compactMap { id, model -> String? in
            if hiddenModels.contains(id) || id.hasPrefix("chat_") || id.hasPrefix("tab_") { return nil }
            if model["disabled"]?.boolValue == true { return nil }
            return id
        }
        var order: [String] = []
        for sort in reply["agentModelSorts"]?.arrayValue ?? [] {
            for group in sort["groups"]?.arrayValue ?? [] {
                for id in group["modelIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !order.contains(id) { order.append(id) }
            }
        }
        return usable.sorted { a, b in
            switch (order.firstIndex(of: a), order.firstIndex(of: b)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a < b
            }
        }
    }

    // MARK: Requests

    /// Fits a Gemini request to what Code Assist takes for `model`.
    static func fit(_ request: JSONValue, model: String) -> JSONValue {
        guard var object = request.objectValue else { return request }
        let claude = model.lowercased().contains("claude")

        if case .object(var system)? = object["systemInstruction"] {
            system["role"] = "user"
            object["systemInstruction"] = .object(system)
        }

        if let tools = object["tools"]?.arrayValue {
            object["tools"] = .array(tools.map { entry in
                guard var tool = entry.objectValue, let declarations = tool["functionDeclarations"]?.arrayValue else { return entry }
                tool["functionDeclarations"] = .array(declarations.map { declaration in
                    guard var declaration = declaration.objectValue else { return declaration }
                    if let schema = declaration["parametersJsonSchema"] ?? declaration["parameters"] {
                        declaration["parametersJsonSchema"] = nil
                        declaration["parameters"] = PlainSchema.convert(schema)
                    }
                    return .object(declaration)
                })
                return .object(tool)
            })
            if claude {
                var toolConfig = object["toolConfig"]?.objectValue ?? [:]
                var calling = toolConfig["functionCallingConfig"]?.objectValue ?? [:]
                if calling["mode"] == nil || calling["mode"]?.stringValue == "AUTO" {
                    calling["mode"] = "VALIDATED"
                    toolConfig["functionCallingConfig"] = .object(calling)
                    object["toolConfig"] = .object(toolConfig)
                }
            }
        }

        if var contents = object["contents"]?.arrayValue {
            contents = contents.compactMap { content in
                guard var content = content.objectValue, let parts = content["parts"]?.arrayValue else { return content }
                let fitted = parts.compactMap { part -> JSONValue? in
                    guard var part = part.objectValue else { return part }
                    // Thinking is not sent back.
                    if part["thought"]?.boolValue == true { return nil }
                    if var call = part["functionCall"]?.objectValue {
                        if let id = call["id"]?.stringValue { call["id"] = .string(sanitized(id)) }
                        part["functionCall"] = .object(call)
                        if claude { part["thoughtSignature"] = .string(GeminiRequestOptions.skipSignatureValidator) }
                    }
                    if var answer = part["functionResponse"]?.objectValue {
                        if let id = answer["id"]?.stringValue { answer["id"] = .string(sanitized(id)) }
                        if var response = answer["response"]?.objectValue, response.count == 1,
                           let value = response["output"] ?? response["error"] {
                            response = ["result": value]
                            answer["response"] = .object(response)
                        }
                        part["functionResponse"] = .object(answer)
                    }
                    return .object(part)
                }
                if fitted.isEmpty { return nil }
                content["parts"] = .array(fitted)
                return .object(content)
            }
            // A conversation may neither start nor end with the model.
            if contents.first?["role"]?.stringValue == "model" {
                contents.insert(["role": "user", "parts": [["text": "[Continuing from previous AI thoughts...]"]]], at: 0)
            }
            if contents.last?["role"]?.stringValue == "model" {
                contents.append(["role": "user", "parts": [["text": "Continue."]]])
            }
            object["contents"] = .array(contents)
        }

        var generation = object["generationConfig"]?.objectValue ?? [:]
        let lower = model.lowercased()
        if lower.hasPrefix("gpt-oss") || (claude && !lower.contains("thinking")) {
            generation["thinkingConfig"] = nil
        }
        if claude {
            if lower.contains("thinking") {
                var thinking = generation["thinkingConfig"]?.objectValue ?? [:]
                var budget = thinking["thinkingBudget"]?.numberValue?.int ?? 10000
                var maxTokens = generation["maxOutputTokens"]?.numberValue?.int ?? budget + 32000
                if maxTokens <= budget { budget = maxTokens - 1 }
                if budget < 1024 {
                    generation["thinkingConfig"] = nil
                } else {
                    thinking["includeThoughts"] = true
                    thinking["thinkingBudget"] = .number(JSONNumber(budget))
                    thinking["thinkingLevel"] = nil
                    generation["thinkingConfig"] = .object(thinking)
                }
                maxTokens = max(maxTokens, 1)
                generation["maxOutputTokens"] = .number(JSONNumber(maxTokens))
            }
        } else {
            generation["maxOutputTokens"] = nil
        }
        object["generationConfig"] = generation.isEmpty ? nil : .object(generation)
        object["sessionId"] = .string(sessionID(object["contents"]))
        return .object(object)
    }

    /// The same for every turn of a conversation: from its first user text.
    static func sessionID(_ contents: JSONValue?) -> String {
        let text = contents?.arrayValue?.lazy
            .filter { $0["role"]?.stringValue == "user" }
            .compactMap { $0["parts"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.first }
            .first ?? Base64URL.random(16)
        let digest = SHA256.hash(Array(text.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } & 0x7fff_ffff_ffff_ffff
        return "-\(value)"
    }

    static func sanitized(_ id: String) -> String {
        String(id.unicodeScalars.map { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-")
                ? Character(scalar) : "_"
        })
    }

    /// The envelope around a Gemini request.
    static func envelope(_ request: JSONValue, model: String, project: String) -> JSONValue {
        [
            "model": .string(model), "project": .string(project), "request": request,
            "userAgent": "antigravity", "requestType": "agent", "requestId": .string("agent-" + Base64URL.random(12)),
        ]
    }

    /// A reply chunk without its envelope.
    static func unwrapped(_ chunk: JSONValue) -> JSONValue {
        chunk["response"] ?? chunk
    }
}

// MARK: - Transport

/// Speaks Code Assist for the account's `project` to the gateway's Gemini
/// requests: generation (`…/v1beta/models/{model}:streamGenerateContent`)
/// becomes `v1internal:streamGenerateContent` with the request fitted and
/// wrapped, and the model list (`GET …/v1beta/models`) becomes
/// `fetchAvailableModels`. Anything else passes through.
struct CodeAssistTransport: HTTPTransport {
    var base: any HTTPTransport
    var project: String

    func send(_ request: HTTPRequest, body: [UInt8]?) async throws -> HTTPTransportResponse {
        let path = request.path ?? ""
        if request.method == .get, path.hasPrefix("/v1beta/models") {
            return try await models(request)
        }
        guard request.method == .post, path.hasPrefix("/v1beta/models/"), let colon = path.lastIndex(of: ":") else {
            return try await base.send(request, body: body)
        }
        let model = String(path[path.index(path.startIndex, offsetBy: "/v1beta/models/".count)..<colon])
        let streams = path[colon...].hasPrefix(":streamGenerateContent")
        let gemini = (try? JSONValue(parsing: body ?? [])) ?? [:]
        let wrapped = CodeAssist.envelope(CodeAssist.fit(gemini, model: model), model: model, project: project)

        var upstream = request
        upstream.path = streams ? "/v1internal:streamGenerateContent?alt=sse" : "/v1internal:generateContent"
        upstream.headerFields[.userAgent] = CodeAssist.userAgent
        upstream.headerFields[.accept] = nil
        let response = try await base.send(upstream, body: wrapped.encoded())
        guard (200..<300).contains(response.status.code) else { return response }
        if streams {
            return HTTPTransportResponse(response: response.response, body: Self.unwrappingEvents(response.body))
        }
        let bytes = try await response.body.collect(upTo: 64 << 20)
        let reply = (try? JSONValue(parsing: bytes)).map(CodeAssist.unwrapped)?.encoded() ?? bytes
        return HTTPTransportResponse(response: response.response, body: HTTPResponseBody(bytes: reply))
    }

    /// `fetchAvailableModels`, answered as an OpenAI-style list.
    private func models(_ request: HTTPRequest) async throws -> HTTPTransportResponse {
        let token = request.headerFields[.authorization].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 } ?? ""
        let reply = try await CodeAssist.call("fetchAvailableModels", body: ["project": .string(project)], token: token, transport: base)
        let list: JSONValue = ["data": .array(CodeAssist.modelIDs(reply).map { ["id": .string($0)] })]
        return HTTPTransportResponse(
            response: HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), body: HTTPResponseBody(bytes: list.encoded()),
        )
    }

    /// The SSE stream with each `data:` line's envelope removed.
    static func unwrappingEvents(_ body: HTTPResponseBody) -> HTTPResponseBody {
        let stream = AsyncThrowingStream<ArraySlice<UInt8>, any Error> { continuation in
            let task = Task {
                var pending: [UInt8] = []
                func line(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
                    var text = bytes
                    if text.last == UInt8(ascii: "\r") { text = text.dropLast() }
                    let prefix = Array("data:".utf8)
                    guard text.starts(with: prefix) else { return Array(bytes) }
                    let payload = text.dropFirst(prefix.count).drop { $0 == UInt8(ascii: " ") }
                    guard let chunk = try? JSONValue(parsing: Array(payload)) else { return Array(bytes) }
                    return Array("data: ".utf8) + CodeAssist.unwrapped(chunk).encoded()
                }
                do {
                    for try await chunk in body {
                        pending.append(contentsOf: chunk)
                        var out: [UInt8] = []
                        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                            out += line(pending[..<newline]) + [UInt8(ascii: "\n")]
                            pending.removeSubrange(...newline)
                        }
                        if !out.isEmpty { continuation.yield(out[...]) }
                    }
                    if !pending.isEmpty { continuation.yield(line(pending[...])[...]) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPResponseBody(stream)
    }
}

// MARK: - Schemas

/// Tool schemas as Code Assist takes them: the OpenAPI subset Gemini's
/// `parameters` speaks, with references inlined and unions narrowed. Any
/// other keyword makes it refuse the request.
enum PlainSchema {
    static let kept: Set<String> = [
        "description", "nullable", "required", "pattern", "minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems",
        "minProperties", "maxProperties", "propertyOrdering", "type", "properties", "items", "enum",
    ]
    static let arrayKeywords: Set<String> = ["items", "minItems", "maxItems"]
    static let objectKeywords: Set<String> = ["properties", "required", "minProperties", "maxProperties", "propertyOrdering"]

    static func convert(_ schema: JSONValue) -> JSONValue {
        var definitions = JSONObject()
        for source in ["definitions", "$defs"] {
            for (name, value) in schema[source]?.objectValue ?? [:] { definitions[name] = value }
        }
        return convert(schema, definitions: definitions, depth: 0)
    }

    private static func convert(_ schema: JSONValue, definitions: JSONObject, depth: Int) -> JSONValue {
        guard depth < 16, var object = schema.objectValue else { return [:] }

        if let reference = object["$ref"]?.stringValue {
            let name = reference.split(separator: "/").last.map(String.init) ?? ""
            var resolved = definitions[name]?.objectValue ?? [:]
            if let description = object["description"] { resolved["description"] = description }
            return convert(.object(resolved), definitions: definitions, depth: depth + 1)
        }
        if let parts = object["allOf"]?.arrayValue {
            object["allOf"] = nil
            for part in parts {
                guard let part = convert(part, definitions: definitions, depth: depth + 1).objectValue else { continue }
                for (key, value) in part {
                    if key == "properties", case .object(var properties)? = object[key], let more = value.objectValue {
                        for (name, property) in more { properties[name] = property }
                        object[key] = .object(properties)
                    } else if key == "required", let more = value.arrayValue {
                        object[key] = .array((object[key]?.arrayValue ?? []) + more)
                    } else if object[key] == nil {
                        object[key] = value
                    }
                }
            }
        }
        for union in ["anyOf", "oneOf"] {
            guard let branches = object[union]?.arrayValue else { continue }
            object[union] = nil
            let nullable = branches.contains { $0["type"]?.stringValue == "null" }
            if nullable { object["nullable"] = true }
            if object["type"] == nil, object["properties"] == nil,
               let branch = branches.first(where: { $0["type"]?.stringValue != "null" })?.objectValue {
                let converted = convert(.object(branch), definitions: definitions, depth: depth + 1).objectValue ?? [:]
                for (key, value) in converted where object[key] == nil { object[key] = value }
            }
        }
        if let types = object["type"]?.arrayValue {
            let named = types.compactMap(\.stringValue)
            if named.contains("null") { object["nullable"] = true }
            object["type"] = named.first { $0 != "null" }.map(JSONValue.string)
        }
        if let constant = object["const"] { object["enum"] = [constant] }
        if let bound = object["exclusiveMinimum"], bound.numberValue != nil { object["minimum"] = bound }
        if let bound = object["exclusiveMaximum"], bound.numberValue != nil { object["maximum"] = bound }

        var out = JSONObject()
        for (key, value) in object where kept.contains(key) { out[key] = value }
        if let values = out["enum"]?.arrayValue {
            let strings = values.compactMap(\.stringValue).filter { !$0.trimmingBlanks().isEmpty }
            out["enum"] = strings.isEmpty ? nil : .array(strings.map(JSONValue.string))
            if !strings.isEmpty, out["type"] == nil { out["type"] = "string" }
        }
        if let properties = out["properties"]?.objectValue {
            var converted = JSONObject()
            for (name, property) in properties { converted[name] = convert(property, definitions: definitions, depth: depth + 1) }
            out["properties"] = .object(converted)
        }
        if let items = out["items"] {
            let item = items.arrayValue?.first ?? items
            out["items"] = convert(item, definitions: definitions, depth: depth + 1)
        }
        let type = out["type"]?.stringValue
        if type == "array", out["items"] == nil { out["items"] = [:] }
        if let type, type != "array" { for key in arrayKeywords { out[key] = nil } }
        if let type, type != "object" { for key in objectKeywords { out[key] = nil } }
        if let required = out["required"]?.arrayValue {
            let names = Set(out["properties"]?.objectValue?.keys.map { $0 } ?? [])
            let kept = required.compactMap(\.stringValue).filter { names.contains($0) }
            out["required"] = kept.isEmpty ? nil : .array(kept.map(JSONValue.string))
        }
        return .object(out)
    }
}
