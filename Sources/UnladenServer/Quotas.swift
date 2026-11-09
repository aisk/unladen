// What accounts' plans have left in each of their windows (five hours, a
// week, a month), as the providers report it: Antigravity through Code
// Assist, GLM Coding Plan keys of Zhipu (open.bigmodel.cn) and Z.ai through
// their monitor API. A ChatGPT plan used through OpenAI's API reports none:
// OpenAI shows it only on chatgpt.com. Read when the panel asks, at most
// once a minute per account.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import HTTPTypes
import NIOConcurrencyHelpers
@_spi(Wire) import UnladenCore

/// One window of an account's allowance.
struct QuotaWindow: Sendable, Equatable {
    /// "5 hours", "7 days", "MCP calls · month", or a model's id.
    var name: String
    /// The models the window is for, when it is not the whole account's
    /// (Antigravity's "Claude and GPT models").
    var group: String?
    /// 0–100.
    var used: Double
    /// When the window starts again, Unix time in milliseconds.
    var resetsAt: Int64?
    /// A count, when the provider gives one: "12 / 1000".
    var detail: String?

    var json: JSONValue {
        [
            "name": .string(name),
            "group": group.map(JSONValue.string) ?? .null,
            "used": JSONNumber((used * 10).rounded() / 10).map(JSONValue.number) ?? .null,
            "resets_at": resetsAt.map { .number(JSONNumber($0)) } ?? .null,
            "detail": detail.map(JSONValue.string) ?? .null,
        ]
    }
}

/// An account's plan and its windows, or why they cannot be shown.
struct AccountQuota: Sendable, Equatable {
    var provider: String
    var account: String
    var plan: String?
    var windows: [QuotaWindow] = []
    var error: String?
    /// Where the provider shows what the gateway cannot read.
    var seeAt: String?
    /// Unix time in milliseconds.
    var readAt: Int64

    var json: JSONValue {
        [
            "provider": .string(provider),
            "account": .string(account),
            "plan": plan.map(JSONValue.string) ?? .null,
            "windows": .array(windows.map(\.json)),
            "error": error.map(JSONValue.string) ?? .null,
            "see_at": seeAt.map(JSONValue.string) ?? .null,
            "read_at": .number(JSONNumber(readAt)),
        ]
    }
}

/// Accounts' allowances, read when asked and kept a minute: the providers'
/// usage endpoints are rate limited.
final class QuotaReader: Sendable {
    static let lifetime: Int64 = 60 * 1000
    /// How soon a refresh asked for by hand may read an account again.
    static let refreshGap: Int64 = 10 * 1000
    static let timeout: Duration = .seconds(20)
    static let chatGPTUsage = "https://chatgpt.com/codex/settings/usage"

    private let entries = NIOLockedValueBox([String: AccountQuota]())

    init() {}

    /// Forgets what was read (the configuration changed).
    func forget() {
        entries.withLockedValue { $0 = [:] }
    }

    /// The allowance of every account that reports one, in the order of
    /// the providers and their pools; `refresh` reads again what is more
    /// than a few seconds old.
    func read(gateway: Gateway, refresh: Bool) async -> [AccountQuota] {
        let configuration = gateway.configuration
        var accounts: [(provider: String, key: UpstreamKey, reader: Reader)] = []
        for id in configuration.registry.providers.keys.sorted() {
            guard let provider = configuration.registry[id], let pool = configuration.keyPools[id] else { continue }
            for key in pool.keys {
                if let reader = Reader.of(provider: provider, key: key) { accounts.append((id, key, reader)) }
            }
        }
        let now = LocalDay.nowMilliseconds()
        let maxAge = refresh ? Self.refreshGap : Self.lifetime
        return await withTaskGroup(of: (Int, AccountQuota).self) { group in
            for (index, account) in accounts.enumerated() {
                let cacheKey = account.provider + "/" + account.key.name
                if let kept = entries.withLockedValue({ $0[cacheKey] }), now - kept.readAt < maxAge {
                    group.addTask { (index, kept) }
                    continue
                }
                group.addTask {
                    let quota = await account.reader.read(provider: account.provider, key: account.key, gateway: gateway)
                    self.entries.withLockedValue { $0[cacheKey] = quota }
                    return (index, quota)
                }
            }
            var results = [AccountQuota?](repeating: nil, count: accounts.count)
            for await (index, quota) in group { results[index] = quota }
            // A key with no plan, on endpoints not the plan's, shows nothing.
            return results.compactMap { $0 }.filter { !$0.windows.isEmpty || $0.error != nil }
        }
    }

    // MARK: Readers

    enum Reader: Sendable {
        case antigravity
        case chatGPT
        /// A Zhipu or Z.ai key; `coding`: its endpoints are the Coding
        /// Plan's, so a key without a plan is worth saying so.
        case glm(host: String, coding: Bool)

        static let glmHosts: Set<String> = ["open.bigmodel.cn", "api.z.ai"]

        static func of(provider: Provider, key: UpstreamKey) -> Reader? {
            switch key.signIn {
            case .antigravity: return .antigravity
            case .chatgpt: return .chatGPT
            case nil: break
            }
            guard !key.secret.isEmpty else { return nil }
            let bases = provider.endpoints.map(\.baseURL)
            guard let host = bases.lazy.map(QuotaReader.host(of:)).first(where: glmHosts.contains) else { return nil }
            return .glm(host: host, coding: bases.contains { $0.contains("/coding") || $0.contains("/anthropic") })
        }

        func read(provider: String, key: UpstreamKey, gateway: Gateway) async -> AccountQuota {
            var quota = AccountQuota(provider: provider, account: key.name, readAt: LocalDay.nowMilliseconds())
            switch self {
            case .chatGPT:
                quota.plan = gateway.signIns.credentials(provider: provider, account: key.name)?.plan
                quota.error = "OpenAI shows this plan's usage only on its own site."
                quota.seeAt = QuotaReader.chatGPTUsage
            case .antigravity:
                let credentials = gateway.signIns.credentials(provider: provider, account: key.name)
                quota.plan = credentials?.plan
                do {
                    let token = try await gateway.signIns.token(provider: provider, account: key.name, transport: gateway.transport)
                    quota.windows = try await AntigravityQuota.windows(
                        token: token, project: credentials?.project ?? "", transport: gateway.transport,
                    )
                } catch {
                    quota.error = "\(error)"
                }
            case .glm(let host, let coding):
                do {
                    let (plan, windows) = try await GLMQuota.read(host: host, key: key.secret, transport: gateway.transport)
                    quota.plan = plan
                    quota.windows = windows
                    if windows.isEmpty { quota.error = "This key has no Coding Plan." }
                } catch {
                    quota.error = "\(error)"
                }
                if quota.windows.isEmpty, !coding { quota.error = nil }
            }
            return quota
        }
    }

    /// The host of an address: `https://api.z.ai/api/v1` → `api.z.ai`.
    static func host(of address: String) -> String {
        let parts = address.split(separator: "://", maxSplits: 1, omittingEmptySubsequences: false)
        let rest = parts.count == 2 ? parts[1] : Substring(address)
        let end = rest.firstIndex { $0 == "/" || $0 == ":" || $0 == "?" } ?? rest.endIndex
        return rest[..<end].lowercased()
    }

    /// An RFC 3339 time, in Unix milliseconds.
    static func milliseconds(rfc3339 text: String?) -> Int64? {
        guard let text else { return nil }
        let styles = [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()]
        for style in styles {
            if let date = try? style.parse(text) { return Int64((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        return nil
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }
}

// MARK: - Antigravity

enum AntigravityQuota {
    /// The windows of the model groups that share an allowance
    /// (`retrieveUserQuotaSummary`: a five-hour and a weekly window each),
    /// then, for the models no group covers, one window per family: its
    /// models' tightest (`fetchAvailableModels`' `quotaInfo`).
    static func windows(token: String, project: String, transport: any HTTPTransport) async throws -> [QuotaWindow] {
        let body: JSONValue = ["project": .string(project)]
        async let summary = try? CodeAssist.call("retrieveUserQuotaSummary", body: body, token: token, transport: transport)
        let models = try await CodeAssist.call("fetchAvailableModels", body: body, token: token, transport: transport)
        return combined(summary: await summary, models: models)
    }

    static func combined(summary: JSONValue?, models: JSONValue) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        var covered: [String] = []
        for group in summary?["groups"]?.arrayValue ?? [] {
            guard let name = group["displayName"]?.stringValue, !name.isEmpty else { continue }
            var any = false
            for bucket in group["buckets"]?.arrayValue ?? [] where bucket["disabled"]?.boolValue != true {
                let window = switch bucket["window"]?.stringValue?.lowercased() {
                case "5h": "5 hours"
                case "weekly": "7 days"
                default: bucket["displayName"]?.stringValue ?? bucket["window"]?.stringValue ?? bucket["bucketId"]?.stringValue ?? ""
                }
                guard !window.isEmpty else { continue }
                windows.append(QuotaWindow(
                    name: window, group: name, used: used(remaining: bucket["remainingFraction"]),
                    resetsAt: QuotaReader.milliseconds(rfc3339: bucket["resetTime"]?.stringValue),
                ))
                any = true
            }
            if any { covered.append((name + " " + (group["description"]?.stringValue ?? "")).lowercased()) }
        }

        // The rest, by family, in Antigravity's order.
        var families: [String] = []
        var members: [String: [(id: String, used: Double, resetsAt: Int64?)]] = [:]
        for id in CodeAssist.modelIDs(models) {
            guard let info = models["models"]?[id]?["quotaInfo"], info.objectValue != nil else { continue }
            let family = String(id.prefix { $0 != "-" }).lowercased()
            if covered.contains(where: { $0.contains(family) }) { continue }
            if members[family] == nil { families.append(family) }
            members[family, default: []].append(
                (id, used(remaining: info["remainingFraction"]), QuotaReader.milliseconds(rfc3339: info["resetTime"]?.stringValue)),
            )
        }
        for family in families {
            let list = members[family] ?? []
            guard let tightest = list.max(by: { $0.used < $1.used }) else { continue }
            let same = list.count > 1 && list.allSatisfy { $0.used == tightest.used }
            let familyName = family == "gpt" ? "GPT" : family.prefix(1).uppercased() + family.dropFirst()
            windows.append(QuotaWindow(
                name: same ? "\(list.count) models" : tightest.id,
                group: familyName + " models",
                used: tightest.used, resetsAt: tightest.resetsAt,
            ))
        }
        return windows
    }

    /// A fraction left (0–1) as a share used; none said is none left.
    static func used(remaining: JSONValue?) -> Double {
        guard let fraction = remaining?.numberValue?.double else { return 100 }
        return min(max((1 - fraction) * 100, 0), 100)
    }
}

// MARK: - GLM Coding Plan

enum GLMQuota {
    /// `GET /api/monitor/usage/quota/limit`, with the bare key as the
    /// authorization: the plan's level and its windows.
    static func read(host: String, key: String, transport: any HTTPTransport) async throws -> (plan: String?, windows: [QuotaWindow]) {
        var request = HTTPRequest(method: .get, scheme: "https", authority: host, path: "/api/monitor/usage/quota/limit")
        request.headerFields[.authorization] = key
        request.headerFields[.accept] = "application/json"
        let request2 = request
        let (status, bytes) = try await Gateway.within(QuotaReader.timeout) {
            let response = try await transport.send(request2, body: nil)
            return (response.status.code, try await response.body.collect(upTo: 1 << 20))
        }
        let reply = (try? JSONValue(parsing: bytes)) ?? .null
        return try parse(reply, status: status)
    }

    /// Reads
    ///
    ///     {"success": true, "data": {"level": "pro", "limits": [
    ///       {"type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 12, "nextResetTime": 1794238216261},
    ///       {"type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 27, "nextResetTime": …},
    ///       {"type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 1000, "currentValue": 0, "percentage": 0, …}]}}
    ///
    /// Unit 3 is hours, 6 weeks and 5 months. `TIME_LIMIT` counts the
    /// month's MCP tool calls (search, web reader), not the models.
    static func parse(_ reply: JSONValue, status: Int) throws -> (plan: String?, windows: [QuotaWindow]) {
        let message = reply["msg"]?.stringValue ?? reply["error"]?["message"]?.stringValue
        guard status == 200 else { throw QuotaReader.Failure(description: message ?? "HTTP \(status)") }
        guard reply["success"]?.boolValue != false, let data = reply["data"], data.objectValue != nil else {
            throw QuotaReader.Failure(description: message ?? "no plan in the reply")
        }
        var windows: [QuotaWindow] = []
        for limit in data["limits"]?.arrayValue ?? [] {
            let number = limit["number"]?.numberValue?.int ?? 0
            let unit = limit["unit"]?.numberValue?.int
            var window = QuotaWindow(
                name: "Allowance", used: min(max(limit["percentage"]?.numberValue?.double ?? 0, 0), 100),
                resetsAt: limit["nextResetTime"]?.numberValue?.int.map(Int64.init),
            )
            if limit["type"]?.stringValue?.uppercased() == "TIME_LIMIT" {
                window.name = "MCP calls · month"
                if let total = limit["usage"]?.numberValue?.int {
                    window.detail = "\(limit["currentValue"]?.numberValue?.int ?? 0) / \(total)"
                }
            } else {
                switch unit {
                case 3: window.name = "\(number > 0 ? number : 5) hours"
                case 6: window.name = "\(7 * max(number, 1)) days"
                case 5: window.name = number > 1 ? "\(number) months" : "Month"
                default: break
                }
            }
            windows.append(window)
        }
        let plan = data["level"]?.stringValue.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (plan, windows)
    }
}
