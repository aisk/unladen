import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

private let adminToken = "admin-token-0123456789"

private let sample = """
// Hand-written, with comments.
{
  "listen": "127.0.0.1:4141",
  "panel": { "token": "\(adminToken)" },
  "accounts": {
    "deepseek": "sk-literal-one",
    "env": { "provider": "deepseek", "key": "${DEEPSEEK_KEY}" },
  },
  "models": { "*": "deepseek/deepseek-chat", "gpt-*": "deepseek" },
  "clients": { "me": { "key": "client-secret", "models": "*" } },
  "advanced": {
    "strict": true,
    "head_timeout": "off",
    "max_request_bytes": 1048576,
    "pools": { "deepseek": "rotate" },
  },
}
"""

private let environment: @Sendable (String) -> String? = { $0 == "DEEPSEEK_KEY" ? "sk-from-env" : nil }

@Suite struct ConfigDocumentTests {
    @Test func readingHidesLiteralKeysAndKeepsReferences() throws {
        let snapshot = try ConfigDocument.read(sample)
        let document = snapshot.document
        let hidden = ConfigDocument.placeholder(for: "sk-literal-one")
        #expect(document["accounts"]?["deepseek"] == .string(hidden))
        #expect(document["accounts"]?["env"]?["key"] == "${DEEPSEEK_KEY}")
        #expect(document["accounts"]?["env"]?["provider"] == "deepseek")
        #expect(document["clients"]?["me"]?["key"] == .string(ConfigDocument.placeholder(for: "client-secret")))
        #expect(document["panel"]?["token"] == .string(ConfigDocument.placeholder(for: adminToken)))
        #expect(snapshot.secrets[hidden] == "sk-literal-one")
        #expect(document["advanced"]?["strict"] == true)
        #expect(document["advanced"]?["max_request_bytes"] == 1_048_576)
        #expect(document["advanced"]?["head_timeout"] == "off")
        #expect(document["models"]?["gpt-*"] == "deepseek")
        #expect(!String(decoding: document.encoded(), as: UTF8.self).contains("sk-literal-one"))
    }

    @Test func writingBackGivesTheSameConfiguration() throws {
        let snapshot = try ConfigDocument.read(sample)
        let text = try ConfigDocument.text(from: snapshot.document, secrets: snapshot.secrets)
        let before = try ConfigFile.parse(sample, environment: environment)
        let after = try ConfigFile.parse(text, environment: environment)
        #expect(after.server == before.server)
        #expect(after.gateway.strict && after.gateway.headTimeout == nil)
        #expect(after.gateway.keyPools["deepseek"]?.keys == before.gateway.keyPools["deepseek"]?.keys)
        #expect(after.gateway.keyPools["deepseek"]?.strategy == .rotate)
        #expect(after.gateway.routes.all.map(\.name) == before.gateway.routes.all.map(\.name))
        #expect(after.gateway.clientKeys == before.gateway.clientKeys)
        #expect(after.gateway.adminToken == adminToken)
        // `${VAR}` stays a reference in the file.
        #expect(text.contains("${DEEPSEEK_KEY}"))
        #expect(!text.contains("sk-from-env"))
    }

    @Test func writtenTextIsIndentedJSON() throws {
        let document: JSONValue = [
            "listen": "127.0.0.1:4141",
            "panel": ["token": "${UNLADEN_ADMIN_TOKEN}"],
            "models": ["*": "deepseek/deepseek-chat"],
            "clients": ["ci": ["key": "${CI_KEY}", "models": ["fast", "claude-*"]]],
            "accounts": [:],
            "dropped": nil,
        ]
        let text = try ConfigDocument.text(from: document, secrets: [:])
        #expect(text == """
        {
          "listen": "127.0.0.1:4141",
          "panel": { "token": "${UNLADEN_ADMIN_TOKEN}" },
          "models": { "*": "deepseek/deepseek-chat" },
          "clients": {
            "ci": { "key": "${CI_KEY}", "models": ["fast", "claude-*"] }
          },
          "accounts": {}
        }

        """)
        #expect(try ConfigDocument.read(text).document["clients"] == document["clients"])
    }

    @Test func anUnknownPlaceholderIsRefused() {
        let document: JSONValue = ["accounts": ["deepseek": .string(ConfigDocument.placeholder(for: "other"))]]
        #expect(throws: ConfigError.self) { try ConfigDocument.text(from: document, secrets: [:]) }
    }
}

@Suite struct ConfigManagerTests {
    private func makeManager(_ text: String = sample) throws -> (ConfigManager, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unladen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("config.jsonc").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let loaded = try ConfigFile.parse(text, environment: environment)
        let gateway = Gateway(configuration: loaded.gateway, transport: MockUpstream { _ in reply("{}") }.transport)
        let manager = ConfigManager(
            path: path, overrides: ConfigOverrides(), server: loaded.server, gateway: gateway,
            logger: Logger(label: "test"), environment: environment,
        )
        return (manager, path)
    }

    @Test func savingWritesTheFileAndServesIt() throws {
        let (manager, path) = try makeManager()
        let snapshot = try manager.document()
        var document = try #require(snapshot.document.objectValue)
        var models = try #require(document["models"]?.objectValue)
        models["fast"] = "deepseek/deepseek-chat"
        document["models"] = .object(models)

        let outcome = manager.save(.object(document), baseHash: snapshot.hash)
        guard case .saved(let hash, _) = outcome else { Issue.record("not saved: \(outcome)"); return }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(ConfigDocument.hash(text) == hash)
        #expect(text.contains("sk-literal-one"))
        #expect(manager.gateway.configuration.routes.named("fast") != nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o640)
    }

    @Test func aStaleHashIsAConflict() throws {
        let (manager, path) = try makeManager()
        let snapshot = try manager.document()
        try (sample + "\n// edited by hand\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(manager.save(snapshot.document, baseHash: snapshot.hash) == .conflict(hash: try manager.document().hash))
    }

    @Test func anInvalidDocumentLeavesTheFile() throws {
        let (manager, path) = try makeManager()
        let snapshot = try manager.document()
        var document = try #require(snapshot.document.objectValue)
        document["models"] = ["x": "nowhere/model"]
        guard case .invalid = manager.save(.object(document), baseHash: snapshot.hash) else { Issue.record("saved"); return }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == sample)
    }

    @Test func removingTheAdminTokenIsRefused() throws {
        let (manager, _) = try makeManager()
        let snapshot = try manager.document()
        var document = try #require(snapshot.document.objectValue)
        _ = document.removeValue(forKey: "panel")
        guard case .invalid(let error) = manager.save(.object(document), baseHash: snapshot.hash) else { Issue.record("saved"); return }
        #expect(error.message.contains("panel.token"))
    }
}

@Suite struct AdminRouteTests {
    private func app(_ manager: ConfigManager) -> some ApplicationProtocol {
        Application(router: buildRouter(gateway: manager.gateway, manager: manager), configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    }

    private func makeManager(_ text: String) throws -> ConfigManager {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("unladen-\(UUID().uuidString).jsonc").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = try ConfigFile.parse(text, environment: environment)
        let gateway = Gateway(configuration: loaded.gateway, transport: MockUpstream { _ in reply("{}") }.transport)
        return ConfigManager(path: path, overrides: ConfigOverrides(), server: loaded.server, gateway: gateway, logger: Logger(label: "test"), environment: environment)
    }

    @Test func withoutATokenThePanelDoesNotExist() async throws {
        let manager = try makeManager(#"{ "models": { "*": "deepseek/deepseek-chat" } }"#)
        try await app(manager).test(.router) { client in
            let page = try await client.execute(uri: "/admin", method: .get)
            let api = try await client.execute(uri: "/admin/api/config", method: .get)
            #expect(page.status == .notFound && api.status == .notFound)
        }
    }

    @Test func theApiNeedsTheToken() async throws {
        let manager = try makeManager(sample)
        try await app(manager).test(.router) { client in
            let page = try await client.execute(uri: "/admin", method: .get)
            let missing = try await client.execute(uri: "/admin/api/status", method: .get)
            // A client key is not the admin token.
            let wrong = try await client.execute(uri: "/admin/api/status", method: .get, headers: [.authorization: "Bearer client-secret"])
            #expect(page.status == .ok)
            #expect(missing.status == .unauthorized && wrong.status == .unauthorized)
        }
    }

    @Test func readAndSaveOverHTTP() async throws {
        let manager = try makeManager(sample)
        let headers: HTTPFields = [.authorization: "Bearer \(adminToken)", .contentType: "application/json"]
        try await app(manager).test(.router) { client in
            let read = try await client.execute(uri: "/admin/api/config", method: .get, headers: headers)
            #expect(read.status == .ok)
            let json = try JSONValue(parsing: Array(read.body.readableBytesView))
            #expect(!String(buffer: read.body).contains("sk-literal-one"))
            let save: JSONValue = ["document": try #require(json["document"]), "hash": try #require(json["hash"])]
            let saved = try await client.execute(uri: "/admin/api/config", method: .put, headers: headers, body: ByteBuffer(bytes: save.encoded()))
            #expect(saved.status == .ok)
            let again = try await client.execute(uri: "/admin/api/config", method: .put, headers: headers, body: ByteBuffer(bytes: save.encoded()))
            #expect(again.status == .conflict)

            let status = try await client.execute(uri: "/admin/api/status", method: .get, headers: headers)
            let body = String(buffer: status.body)
            #expect(status.status == .ok)
            #expect(body.contains(#""name":"env""#))
            #expect(!body.contains("sk-"))
        }
    }
}
