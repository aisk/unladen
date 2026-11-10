// What accounts' plans have left in each of their windows (five hours, a
// week, a month), as the providers report it: Antigravity through Code
// Assist, GLM Coding Plan keys of Zhipu (open.bigmodel.cn) and Z.ai through
// their monitor API, Kimi Code, MiniMax, OpenCode Go, Command Code and
// Ollama Cloud plan keys through their usage queries; and what is left to
// spend on pay-as-you-go accounts that tell a key their balance (DeepSeek,
// Kimi's API, OpenRouter, StepFun, ModelScope, AiHubMix, and the credits of
// Command Code and Ollama Cloud). A ChatGPT plan used through OpenAI's API reports none:
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
    /// What is left to spend, with its currency: "¥110.00".
    var balance: String?
    /// What the balance is made of: "granted ¥10.00 · topped up ¥100.00".
    var balanceDetail: String?
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
            "balance": balance.map(JSONValue.string) ?? .null,
            "balance_detail": balanceDetail.map(JSONValue.string) ?? .null,
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
            return results.compactMap { $0 }.filter { !$0.windows.isEmpty || $0.balance != nil || $0.error != nil }
        }
    }

    // MARK: Readers

    enum Reader: Sendable {
        case antigravity
        case chatGPT
        /// A Zhipu or Z.ai key; `coding`: its endpoints are the Coding
        /// Plan's, so a key without a plan is worth saying so.
        case glm(host: String, coding: Bool)
        /// A Kimi Code membership's key, at its `/coding/v1` address.
        case kimiCode(base: String)
        /// A MiniMax key: a plan's is told its windows, a pay-as-you-go
        /// one is not, and shows nothing.
        case miniMax(host: String)
        /// An OpenCode Go key, told its 5-hour, weekly and monthly windows.
        case openCodeGo
        /// A Command Code key: a plan's is told its 5-hour and weekly
        /// windows, a pay-as-you-go one none, and shows nothing.
        case commandCode
        /// An Ollama Cloud key: a plan's included allowance this period; a
        /// key with none shows nothing.
        case ollamaCloud
        /// A pay-as-you-go account that tells a key its balance.
        case balance(BalanceQuota.Source)

        static let glmHosts: Set<String> = ["open.bigmodel.cn", "api.z.ai"]
        static let kimiHosts: Set<String> = ["api.kimi.com", "api.kimi.ai"]
        static let miniMaxHosts: Set<String> = ["api.minimax.io", "api.minimaxi.com", "api.minimax.cn"]

        static func of(provider: Provider, key: UpstreamKey) -> Reader? {
            switch key.signIn {
            case .antigravity: return .antigravity
            case .chatgpt: return .chatGPT
            case nil: break
            }
            guard !key.secret.isEmpty else { return nil }
            let bases = provider.endpoints.map(\.baseURL)
            for base in bases {
                let host = QuotaReader.host(of: base)
                if glmHosts.contains(host) { return .glm(host: host, coding: bases.contains { $0.contains("/coding") }) }
                if kimiHosts.contains(host), let root = QuotaReader.prefix(of: base, through: "/coding") {
                    return .kimiCode(base: root + "/v1")
                }
                if miniMaxHosts.contains(host) { return .miniMax(host: host) }
                if host == "opencode.ai", base.contains("/go/") { return .openCodeGo }
                if host == "api.commandcode.ai" { return .commandCode }
                if host == "ollama.com" { return .ollamaCloud }
                if let source = BalanceQuota.Source.of(host: host) { return .balance(source) }
            }
            return nil
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
                // Off the coding endpoints, a key without a plan shows
                // nothing; one that cannot be read still says why.
                do {
                    let (plan, windows) = try await GLMQuota.read(host: host, key: key.secret, transport: gateway.transport)
                    quota.plan = plan
                    quota.windows = windows
                    if windows.isEmpty, coding { quota.error = "This key has no Coding Plan." }
                } catch is QuotaReader.Failure where !coding {
                } catch {
                    quota.error = "\(error)"
                }
            case .kimiCode(let base):
                do {
                    let (status, reply) = try await QuotaReader.get(base + "/usages", bearer: key.secret, transport: gateway.transport)
                    quota.windows = try KimiCodeQuota.parse(reply, status: status)
                } catch {
                    quota.error = "\(error)"
                }
            case .miniMax(let host):
                do {
                    let (status, reply) = try await QuotaReader.get(
                        "https://\(host)/v1/token_plan/remains", bearer: key.secret, transport: gateway.transport,
                    )
                    quota.windows = try MiniMaxQuota.parse(reply, status: status)
                } catch is QuotaReader.Failure {
                    // A pay-as-you-go key, told it has no plan, shows nothing.
                } catch {
                    quota.error = "\(error)"
                }
            case .openCodeGo, .commandCode, .ollamaCloud, .balance:
                let address: String
                let parse: (inout AccountQuota, JSONValue, Int) throws -> Void
                switch self {
                case .openCodeGo:
                    address = OpenCodeGoQuota.address
                    parse = { quota, reply, status in quota.windows = try OpenCodeGoQuota.parse(reply, status: status) }
                case .commandCode:
                    address = CommandCodeQuota.address
                    parse = { quota, reply, status in
                        (quota.plan, quota.windows) = try CommandCodeQuota.parse(reply, status: status)
                        quota.balance = CommandCodeQuota.balance(reply)
                    }
                case .ollamaCloud:
                    address = OllamaCloudQuota.address
                    parse = { quota, reply, status in
                        quota.windows = try OllamaCloudQuota.parse(reply, status: status)
                        quota.balance = OllamaCloudQuota.balance(reply)
                    }
                case .balance(let source):
                    address = source.address
                    parse = { quota, reply, status in (quota.balance, quota.balanceDetail) = try source.parse(reply, status: status) }
                default:
                    return quota
                }
                do {
                    let (status, reply) = try await QuotaReader.get(address, bearer: key.secret, transport: gateway.transport)
                    try parse(&quota, reply, status)
                } catch {
                    quota.error = "\(error)"
                }
            }
            return quota
        }
    }

    /// `GET` of an address, with `bearer` as the key or, when `nil`, `key`
    /// bare: the reply's status and its JSON.
    static func get(_ address: String, bearer: String? = nil, key: String? = nil, transport: any HTTPTransport) async throws -> (Int, JSONValue) {
        guard let url = BaseURL(address) else { throw Failure(description: "not an address: \(address)") }
        var request = HTTPRequest(method: .get, scheme: url.scheme, authority: url.authority, path: url.path.isEmpty ? "/" : url.path)
        request.headerFields[.authorization] = bearer.map { "Bearer " + $0 } ?? key
        request.headerFields[.accept] = "application/json"
        let sent = request
        let (status, bytes) = try await within(timeout) {
            let response = try await transport.send(sent, body: nil)
            return (response.status.code, try await response.body.collect(upTo: 1 << 20))
        }
        return (status, (try? JSONValue(parsing: bytes)) ?? .null)
    }

    /// `address` up to and including the first `part` in it.
    static func prefix(of address: String, through part: String) -> String? {
        var index = address.startIndex
        while index < address.endIndex {
            if address[index...].hasPrefix(part) { return String(address[..<address.index(index, offsetBy: part.count)]) }
            index = address.index(after: index)
        }
        return nil
    }

    /// A window's name by its length in minutes: "5 hours", "7 days",
    /// "Month".
    static func name(minutes: Int) -> String {
        switch minutes {
        case 28 * 1440...31 * 1440: "Month"
        case 1440: "Day"
        case let m where m > 1440 && m % 1440 == 0: "\(m / 1440) days"
        case let m where m >= 60 && m % 60 == 0: "\(m / 60) hours"
        case let m where m > 0: "\(m) minutes"
        default: "Allowance"
        }
    }

    /// A number given as a number or as text.
    static func number(_ value: JSONValue?) -> Double? {
        if let n = value?.numberValue { return n.double }
        return value?.stringValue.flatMap { Double($0.filter { $0 != " " }) }
    }

    /// A time given as RFC 3339 text or as Unix seconds or milliseconds.
    static func milliseconds(_ value: JSONValue?) -> Int64? {
        if let text = value?.stringValue { return milliseconds(rfc3339: text) }
        guard let n = value?.numberValue?.double, n > 0 else { return nil }
        return Int64(n > 1e11 ? n : n * 1000)
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
        let (status, reply) = try await QuotaReader.get("https://\(host)/api/monitor/usage/quota/limit", key: key, transport: transport)
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

// MARK: - Kimi Code

enum KimiCodeQuota {
    /// Reads `/coding/v1/usages`:
    ///
    ///     {"usage": {"limit": "100", "used": "12", "resetTime": "2026-09-30T05:24:18.44Z"},
    ///      "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
    ///                  "detail": {"limit": "100", "remaining": "88", "resetTime": "…"}}],
    ///      "usages": {"limit_5h": {"used_ratio": 0.43, "reset_time": "…"}, "limit_7d": {…}, "limit_month_total": {…}}}
    ///
    /// `usage` is the week, each of `limits` a shorter window, numbers as
    /// text or numbers, used or remaining. A plan on a monthly allowance
    /// tells shares in `usages` (camelCase too); a window told both ways is
    /// taken from there. `limit_month_code` is the month only when
    /// `limit_month_total` is not given.
    static func parse(_ reply: JSONValue, status: Int) throws -> [QuotaWindow] {
        guard status == 200 else {
            throw QuotaReader.Failure(description: reply["error"]?["message"]?.stringValue ?? reply["message"]?.stringValue ?? "HTTP \(status)")
        }
        var windows: [(minutes: Int, window: QuotaWindow)] = []
        func counted(_ detail: JSONValue?, minutes: Int) {
            guard let detail, let limit = QuotaReader.number(detail["limit"]), limit > 0 else { return }
            guard let used = QuotaReader.number(detail["used"]) ?? QuotaReader.number(detail["remaining"]).map({ limit - $0 }) else { return }
            let reset = ["resetTime", "resetAt", "reset_at", "reset_time"].lazy.compactMap { QuotaReader.milliseconds(detail[$0]) }.first
            windows.append((minutes, QuotaWindow(name: QuotaReader.name(minutes: minutes), used: min(max(used / limit * 100, 0), 100), resetsAt: reset)))
        }
        for limit in reply["limits"]?.arrayValue ?? [] {
            let window = limit["window"]
            let n = Int(QuotaReader.number(window?["duration"]) ?? 0)
            let unit = window?["timeUnit"]?.stringValue ?? ""
            let minutes = unit.contains("MINUTE") ? n : unit.contains("HOUR") ? n * 60 : unit.contains("DAY") ? n * 1440
                : unit.contains("WEEK") ? n * 7 * 1440 : unit.contains("MONTH") ? n * 30 * 1440 : 0
            counted(limit["detail"] ?? window, minutes: minutes)
        }
        counted(reply["usage"], minutes: 7 * 1440)

        let usages = reply["usages"]
        var shares: [(minutes: Int, window: QuotaWindow)] = []
        for (key, camel, minutes) in [
            ("limit_5h", "limit5h", 300), ("limit_7d", "limit7d", 7 * 1440),
            ("limit_month_total", "limitMonthTotal", 30 * 1440), ("limit_month_code", "limitMonthCode", 30 * 1440),
        ] {
            guard let share = usages?[key] ?? usages?[camel], !shares.contains(where: { $0.minutes == minutes }),
                  let ratio = QuotaReader.number(share["used_ratio"]) ?? QuotaReader.number(share["usedRatio"]), ratio.isFinite
            else { continue }
            let reset = ["reset_time", "resetTime", "reset_at", "resetAt"].lazy.compactMap { QuotaReader.milliseconds(share[$0]) }.first
            shares.append((minutes, QuotaWindow(name: QuotaReader.name(minutes: minutes), used: min(max(ratio * 100, 0), 100), resetsAt: reset)))
        }
        if !shares.isEmpty {
            windows.removeAll { window in shares.contains { $0.minutes == window.minutes } }
            windows += shares
        }
        guard !windows.isEmpty else { throw QuotaReader.Failure(description: "no usage in the reply") }
        // Shortest first; one of no known length last.
        return windows.enumerated().sorted { a, b in
            let (x, y) = (a.element.minutes == 0 ? Int.max : a.element.minutes, b.element.minutes == 0 ? Int.max : b.element.minutes)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element.window)
    }
}

// MARK: - MiniMax

enum MiniMaxQuota {
    /// Reads `/v1/token_plan/remains`:
    ///
    ///     {"model_remains": [{"model_name": "general", "start_time": …, "end_time": …,
    ///        "current_interval_remaining_percent": 88, "current_interval_status": 1,
    ///        "weekly_start_time": …, "weekly_end_time": …, "current_weekly_remaining_percent": 95, …}],
    ///      "base_resp": {"status_code": 0, "status_msg": "success"}}
    ///
    /// Each bucket has a short window and a week; status 2 is used up, 3
    /// unlimited (or not in the plan). Buckets other than `general` (video,
    /// speech…) are counted in items: `…_total_count` and `…_usage_count`,
    /// the latter seen holding either what is used or what remains, taken
    /// as whichever the percentage agrees with.
    static func parse(_ reply: JSONValue, status: Int) throws -> [QuotaWindow] {
        guard status == 200, let base = reply["base_resp"] else { throw QuotaReader.Failure(description: "HTTP \(status)") }
        guard base["status_code"]?.numberValue?.int ?? 0 == 0 else {
            throw QuotaReader.Failure(description: base["status_msg"]?.stringValue ?? "refused")
        }
        var windows: [QuotaWindow] = []
        for bucket in reply["model_remains"]?.arrayValue ?? [] {
            let model = bucket["model_name"]?.stringValue?.filter { $0 != " " } ?? ""
            guard !model.isEmpty else { continue }
            for (prefix, weekly) in [("current_interval", false), ("current_weekly", true)] {
                let state = bucket[prefix + "_status"]?.numberValue?.int ?? 0
                let left = QuotaReader.number(bucket[prefix + "_remaining_percent"])
                if state == 3 || left == nil && state != 2 { continue }
                let start = QuotaReader.milliseconds(bucket[weekly ? "weekly_start_time" : "start_time"])
                let end = QuotaReader.milliseconds(bucket[weekly ? "weekly_end_time" : "end_time"])
                var window = QuotaWindow(
                    name: weekly ? "7 days" : start.flatMap { s in end.map { QuotaReader.name(minutes: Int(($0 - s) / 60000)) } } ?? "Allowance",
                    used: state == 2 ? 100 : min(max(100 - (left ?? 0), 0), 100), resetsAt: end,
                )
                if model.lowercased() != "general" { window.group = model.prefix(1).uppercased() + model.dropFirst() }
                if let total = QuotaReader.number(bucket[prefix + "_total_count"]), total > 0,
                   let count = QuotaReader.number(bucket[prefix + "_usage_count"]), count >= 0, count <= total, let left {
                    let asUsed = abs((total - count) / total * 100 - left), asLeft = abs(count / total * 100 - left)
                    if min(asUsed, asLeft) <= 1 {
                        let used = state == 2 ? total : asUsed < asLeft ? count : total - count
                        window.detail = "\(Int(used)) / \(Int(total))"
                    }
                }
                windows.append(window)
            }
        }
        return windows
    }
}

// MARK: - OpenCode Go

enum OpenCodeGoQuota {
    static let address = "https://opencode.ai/inference/go/v1/usage"

    /// Reads
    ///
    ///     {"usage": {"rolling": {"status": "ok", "percent": 37, "resetsAt": "2026-08-26T14:12:03.000Z"},
    ///                "weekly": {…}, "monthly": {"status": "rate-limited", "percent": 100, …}}}
    ///
    /// A window at 0% gives now plus its length as `resetsAt`, a time
    /// nothing happens at, so it is left out.
    static func parse(_ reply: JSONValue, status: Int) throws -> [QuotaWindow] {
        guard status == 200 else {
            throw QuotaReader.Failure(description: reply["error"]?["message"]?.stringValue ?? "HTTP \(status)")
        }
        var windows: [QuotaWindow] = []
        for (key, name) in [("rolling", "5 hours"), ("weekly", "7 days"), ("monthly", "Month")] {
            guard let window = reply["usage"]?[key], let percent = QuotaReader.number(window["percent"]) else { continue }
            let used = min(max(percent, 0), 100)
            windows.append(QuotaWindow(
                name: name, used: used, resetsAt: used > 0 ? QuotaReader.milliseconds(window["resetsAt"]) : nil,
            ))
        }
        guard !windows.isEmpty else { throw QuotaReader.Failure(description: "no usage in the reply") }
        return windows
    }
}

// MARK: - Command Code

enum CommandCodeQuota {
    static let address = "https://api.commandcode.ai/alpha/billing/credits"

    /// Plans by the start of their id, longest first.
    static let plans: [(id: String, name: String)] = [
        ("individual-provider", "Provider"), ("individual-pro-v1", "Pro"), ("individual-goat", "GOAT"),
        ("individual-ultra", "Ultra"), ("individual-max", "Max"), ("individual-pro", "Pro"), ("individual-go", "Go"),
        ("teams-pro", "Teams Pro"),
    ]

    /// Reads
    ///
    ///     {"credits": {"planId": "individual-goat-monthly", "monthlyCredits": 41.2, …},
    ///      "windowLimits": {"limited": true,
    ///        "fiveHour": {"used": 3.1, "cap": 10, "resetAt": 1790000000000},
    ///        "weekly": {"used": 12, "cap": 40, "resetAt": 1790400000000}}}
    ///
    /// A window without a cap is not limited, and not shown.
    static func parse(_ reply: JSONValue, status: Int) throws -> (String?, [QuotaWindow]) {
        guard status == 200 else {
            throw QuotaReader.Failure(description: reply["error"]?["message"]?.stringValue ?? "HTTP \(status)")
        }
        let id = (reply["credits"]?["planId"]?.stringValue ?? "").lowercased().replacing("_", with: "-")
        let plan = plans.first { id.hasPrefix($0.id) }?.name
        var windows: [QuotaWindow] = []
        for (key, name) in [("fiveHour", "5 hours"), ("weekly", "7 days")] {
            guard let window = reply["windowLimits"]?[key], let used = QuotaReader.number(window["used"]),
                  let cap = QuotaReader.number(window["cap"]), cap > 0
            else { continue }
            windows.append(QuotaWindow(
                name: name, used: min(max(used / cap * 100, 0), 100), resetsAt: QuotaReader.milliseconds(window["resetAt"]),
            ))
        }
        return (plan, windows)
    }

    /// The dollars left: the month's credits and the bought and free ones.
    static func balance(_ reply: JSONValue) -> String? {
        let amounts = ["monthlyCredits", "purchasedCredits", "freeCredits"].compactMap { QuotaReader.number(reply["credits"]?[$0]) }
        return amounts.isEmpty ? nil : BalanceQuota.money("$", amounts.reduce(0) { $0 + max($1, 0) })
    }
}

// MARK: - Ollama Cloud

enum OllamaCloudQuota {
    static let address = "https://ollama.com/api/balance"

    /// Reads
    ///
    ///     {"included": {"balance_usd": 72.5, "allowance_usd": 100,
    ///        "period": {"from": "2026-09-15T09:30:00Z", "until": "2026-10-15T09:30:00Z"}},
    ///      "purchased": {"balance_usd": 25.0}}
    ///
    /// or, on an early plan, limits as what is left of them:
    ///
    ///     {"included": {"session": {"remaining_percent": 75, "resets_at": "…"},
    ///                   "weekly": {"remaining_percent": 40, "resets_at": "…"}}}
    ///
    /// Credits bought on top are spent once the allowance is.
    static func parse(_ reply: JSONValue, status: Int) throws -> [QuotaWindow] {
        guard status == 200 else {
            throw QuotaReader.Failure(description: reply["error"]?.stringValue ?? reply["error"]?["message"]?.stringValue ?? "HTTP \(status)")
        }
        guard let included = reply["included"], included.objectValue != nil else { return [] }
        var windows: [QuotaWindow] = []
        for (key, name) in [("session", "Session"), ("weekly", "7 days")] {
            guard let limit = included[key], let left = QuotaReader.number(limit["remaining_percent"]) else { continue }
            windows.append(QuotaWindow(name: name, used: min(max(100 - left, 0), 100), resetsAt: QuotaReader.milliseconds(limit["resets_at"])))
        }
        if let allowance = QuotaReader.number(included["allowance_usd"]), allowance > 0,
           let left = QuotaReader.number(included["balance_usd"]) {
            let used = min(max(allowance - left, 0), allowance)
            let from = QuotaReader.milliseconds(included["period"]?["from"])
            let until = QuotaReader.milliseconds(included["period"]?["until"])
            windows.append(QuotaWindow(
                name: from.flatMap { f in until.map { QuotaReader.name(minutes: Int(($0 - f) / 60000)) } } ?? "Allowance",
                used: used / allowance * 100, resetsAt: until, detail: "$\(dollars(used)) / $\(dollars(allowance))",
            ))
        }
        return windows
    }

    static func dollars(_ value: Double) -> String { BalanceQuota.decimals(value) }

    /// The credits bought on top of the plan, spent once its allowance is.
    static func balance(_ reply: JSONValue) -> String? {
        QuotaReader.number(reply["purchased"]?["balance_usd"]).map { BalanceQuota.money("$", $0) }
    }
}

// MARK: - Balances

enum BalanceQuota {
    /// Where a pay-as-you-go account's balance is asked, with the key as a
    /// Bearer, and how its reply reads.
    enum Source: Sendable, Equatable {
        case deepSeek
        /// Kimi's API: China's in yuan, the international one in dollars.
        case moonshot(host: String, sign: String)
        case openRouter
        /// StepFun, pay as you go or a Step Plan's key (what it spends past
        /// the plan).
        case stepFun(host: String, sign: String)
        case modelScope
        case aiHubMix

        static func of(host: String) -> Source? {
            switch host {
            case "api.deepseek.com": .deepSeek
            case "api.moonshot.cn": .moonshot(host: host, sign: "¥")
            case "api.moonshot.ai": .moonshot(host: host, sign: "$")
            case "openrouter.ai": .openRouter
            case "api.stepfun.com": .stepFun(host: host, sign: "¥")
            case "api.stepfun.ai": .stepFun(host: host, sign: "$")
            case "api-inference.modelscope.cn": .modelScope
            case "aihubmix.com": .aiHubMix
            default: nil
            }
        }

        var address: String {
            switch self {
            case .deepSeek: "https://api.deepseek.com/user/balance"
            case .moonshot(let host, _): "https://\(host)/v1/users/me/balance"
            case .openRouter: "https://openrouter.ai/api/v1/credits"
            case .stepFun(let host, _): "https://\(host)/v1/accounts"
            case .modelScope: "https://modelscope.cn/openapi/v1/magicubes/balance"
            case .aiHubMix: "https://aihubmix.com/dashboard/billing/remain"
            }
        }

        func parse(_ reply: JSONValue, status: Int) throws -> (balance: String, detail: String?) {
            guard status == 200 else { throw QuotaReader.Failure(description: BalanceQuota.message(reply) ?? "HTTP \(status)") }
            func amount(_ value: JSONValue?) throws -> Double {
                guard let value = QuotaReader.number(value) else {
                    throw QuotaReader.Failure(description: BalanceQuota.message(reply) ?? "no balance in the reply")
                }
                return value
            }
            switch self {
            case .deepSeek:
                return try BalanceQuota.deepSeek(reply)
            case .moonshot(_, let sign):
                return (money(sign, try amount(reply["data"]?["available_balance"])), nil)
            case .openRouter:
                let left = try amount(reply["data"]?["total_credits"]) - (QuotaReader.number(reply["data"]?["total_usage"]) ?? 0)
                return (money("$", left), nil)
            case .stepFun(_, let sign):
                return (money(sign, try amount(reply["balance"])), nil)
            case .modelScope:
                // What running tasks have frozen is not available.
                return (BalanceQuota.decimals(try amount(reply["data"]?["available_balance"]), places: 0) + " 魔粒", nil)
            case .aiHubMix:
                // What is left on the key, despite the name; -1: the key
                // has no limit, and the account's balance is not told to a key.
                let left = try amount(reply["total_usage"])
                guard left >= 0 else {
                    throw QuotaReader.Failure(description: "This key has no limit; AiHubMix tells a key only what is left on it.")
                }
                return (money("$", left), nil)
            }
        }

        private func money(_ sign: String, _ value: Double) -> String { BalanceQuota.money(sign, value) }
    }

    /// Reads
    ///
    ///     {"is_available": true, "balance_infos": [{"currency": "CNY", "total_balance": "110.00",
    ///       "granted_balance": "10.00", "topped_up_balance": "100.00"}]}
    ///
    /// The currencies come in no fixed order: those with money left go
    /// first, then by code, so a card does not swap them between reads.
    static func deepSeek(_ reply: JSONValue) throws -> (balance: String, detail: String?) {
        var amounts: [(code: String, total: Double, granted: Double?, topped: Double?)] = []
        for info in reply["balance_infos"]?.arrayValue ?? [] {
            guard let total = QuotaReader.number(info["total_balance"]) else { continue }
            amounts.append(((info["currency"]?.stringValue ?? "").uppercased(), total,
                            QuotaReader.number(info["granted_balance"]), QuotaReader.number(info["topped_up_balance"])))
        }
        guard !amounts.isEmpty else { throw QuotaReader.Failure(description: message(reply) ?? "no balance in the reply") }
        amounts.sort { ($0.total > 0) != ($1.total > 0) ? $0.total > 0 : $0.code < $1.code }
        let balance = amounts.map { money(sign($0.code), $0.total) }.joined(separator: " · ")
        let parts = amounts.compactMap { a -> String? in
            guard let granted = a.granted, granted != 0, let topped = a.topped else { return nil }
            return "granted \(money(sign(a.code), granted)) · topped up \(money(sign(a.code), topped))"
        }
        return (balance, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    static func sign(_ code: String) -> String {
        switch code {
        case "CNY", "RMB": "¥"
        case "USD": "$"
        case "": ""
        default: code + " "
        }
    }

    static func money(_ sign: String, _ value: Double) -> String {
        (value < 0 ? "-" : "") + sign + decimals(abs(value))
    }

    /// `value` with `places` decimals (0 or 2): 27.5 → "27.50".
    static func decimals(_ value: Double, places: Int = 2) -> String {
        guard places > 0 else { return "\(Int(value.rounded()))" }
        let cents = Int((value * 100).rounded())
        let rest = cents % 100
        return "\(cents / 100)." + (rest < 10 ? "0" : "") + "\(rest)"
    }

    static func message(_ reply: JSONValue) -> String? {
        reply["error"]?["message"]?.stringValue ?? reply["error"]?.stringValue ?? reply["message"]?.stringValue
    }
}
