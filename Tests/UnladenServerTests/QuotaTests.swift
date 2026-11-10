import Foundation
import HTTPTypes
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

@Suite struct GLMQuotaTests {
    /// A Z.ai GLM Coding Plan key's reply.
    static let planReply = """
        {"code":200,"msg":"Operation successful","data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":12,"nextResetTime":1794238216261},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":27,"nextResetTime":1794746717997},
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":3,"remaining":997,"percentage":0,
           "nextResetTime":1795659013998,"usageDetails":[{"modelCode":"search-prime","usage":3}]}],
          "level":"pro"},"success":true}
        """

    @Test func readsThePlanAndItsWindows() throws {
        let (plan, windows) = try GLMQuota.parse(try JSONValue(parsing: Array(Self.planReply.utf8)), status: 200)
        #expect(plan == "Pro")
        #expect(windows == [
            QuotaWindow(name: "5 hours", used: 12, resetsAt: 1_794_238_216_261),
            QuotaWindow(name: "7 days", used: 27, resetsAt: 1_794_746_717_997),
            QuotaWindow(name: "MCP calls · month", used: 0, resetsAt: 1_795_659_013_998, detail: "3 / 1000"),
        ])
    }

    @Test func aRefusalIsItsMessage() throws {
        let refused = try JSONValue(parsing: Array(#"{"code":1001,"msg":"Authorization token is invalid","success":false}"#.utf8))
        #expect(throws: QuotaReader.Failure.self) { try GLMQuota.parse(refused, status: 200) }
        do {
            _ = try GLMQuota.parse(refused, status: 200)
        } catch {
            #expect("\(error)" == "Authorization token is invalid")
        }
    }

    @Test func aGLMKeyIsReadWithTheBareKey() async throws {
        let text = """
            {"accounts": {"zai": {"endpoints": {"chat": "https://api.z.ai/api/coding/paas/v4"}, "key": "zk"},
                          "openai": "sk"}}
            """
        let loaded = try ConfigFile.parse(text, file: "c.jsonc") { _ in nil }
        let upstream = MockUpstream { request in
            #expect(request.request.authority == "api.z.ai")
            #expect(request.request.path == "/api/monitor/usage/quota/limit")
            #expect(request.request.headerFields[.authorization] == "zk")
            return reply(GLMQuotaTests.planReply)
        }
        let gateway = Gateway(configuration: loaded.gateway, transport: upstream.transport)
        let quotas = await gateway.quotas.read(gateway: gateway, refresh: false)
        #expect(quotas.map(\.provider) == ["zai"])
        #expect(quotas.first?.plan == "Pro")
        #expect(quotas.first?.windows.count == 3)
        // Kept a minute.
        _ = await gateway.quotas.read(gateway: gateway, refresh: false)
        #expect(upstream.requests.count == 1)
    }

    @Test func aKeyWithoutAPlanOffTheCodingEndpointsShowsNothing() async throws {
        let text = #"{"accounts": {"zai": {"endpoints": {"chat": "https://api.z.ai/api/paas/v4"}, "key": "zk"}}}"#
        let loaded = try ConfigFile.parse(text, file: "c.jsonc") { _ in nil }
        let upstream = MockUpstream { _ in reply(#"{"code":200,"data":{"limits":[]},"success":true}"#) }
        let gateway = Gateway(configuration: loaded.gateway, transport: upstream.transport)
        #expect(await gateway.quotas.read(gateway: gateway, refresh: false).isEmpty)
    }

    @Test func hosts() {
        #expect(QuotaReader.host(of: "https://api.z.ai/api/v1") == "api.z.ai")
        #expect(QuotaReader.host(of: "https://Open.BigModel.cn:443/api") == "open.bigmodel.cn")
        #expect(QuotaReader.host(of: "api.z.ai") == "api.z.ai")
    }
}

@Suite struct AntigravityQuotaTests {
    static let summary = """
        {"groups": [{"buckets": [
          {"bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly", "resetTime": "2026-11-16T14:32:43Z", "remainingFraction": 0.75},
          {"bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h", "resetTime": "2026-11-09T19:32:43Z"}],
          "displayName": "Claude and GPT models", "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS"}]}
        """
    static let models = """
        {"models": {
          "gemini-3-flash": {"quotaInfo": {"remainingFraction": 1, "resetTime": "2026-11-09T19:32:44Z"}},
          "gemini-3.1-flash-lite": {"quotaInfo": {"remainingFraction": 0.4, "resetTime": "2026-11-09T18:00:00.500Z"}},
          "claude-opus-5-5-high": {"quotaInfo": {"remainingFraction": 1, "resetTime": "2026-11-09T19:32:44Z"}},
          "gpt-oss-120b-medium": {"quotaInfo": {"remainingFraction": 1}},
          "chat_20706": {"quotaInfo": {"remainingFraction": 0}},
          "gemini-2.5-pro": {"quotaInfo": {"remainingFraction": 0}}
        }}
        """

    @Test func groupsThenTheTightestModelOfEachOtherFamily() throws {
        let windows = AntigravityQuota.combined(
            summary: try JSONValue(parsing: Array(Self.summary.utf8)), models: try JSONValue(parsing: Array(Self.models.utf8)),
        )
        #expect(windows.map(\.name) == ["7 days", "5 hours", "gemini-3.1-flash-lite"])
        #expect(windows.map(\.group) == ["Claude and GPT models", "Claude and GPT models", "Gemini models"])
        #expect(windows[0].used == 25)
        // None left said by leaving the fraction out.
        #expect(windows[1].used == 100)
        #expect(abs(windows[2].used - 60) < 0.001)
        #expect(windows[0].resetsAt == 1_794_839_563_000)
        #expect(windows[2].resetsAt == 1_794_247_200_500)
    }

    @Test func withoutTheSummaryEveryFamilyIsByModel() throws {
        let windows = AntigravityQuota.combined(summary: nil, models: try JSONValue(parsing: Array(Self.models.utf8)))
        #expect(windows.map(\.group) == ["Claude models", "Gemini models", "GPT models"])
        #expect(windows.map(\.name) == ["claude-opus-5-5-high", "gemini-3.1-flash-lite", "gpt-oss-120b-medium"])
    }
}

@Suite struct KimiCodeQuotaTests {
    @Test func countedWindowsThenTheWeek() throws {
        let reply = try JSONValue(parsing: Array("""
            {"usage": {"limit": "100", "used": "12", "resetTime": "2026-11-16T14:32:43Z"},
             "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
                         "detail": {"limit": 100, "remaining": "88", "resetTime": "2026-11-09T19:32:43Z"}}]}
            """.utf8))
        let windows = try KimiCodeQuota.parse(reply, status: 200)
        #expect(windows.map(\.name) == ["5 hours", "7 days"])
        #expect(windows.map(\.used) == [12, 12])
        #expect(windows[1].resetsAt == 1_794_839_563_000)
    }

    @Test func sharesStandForTheWindowsTheyTell() throws {
        let reply = try JSONValue(parsing: Array("""
            {"usage": {"limit": "100", "used": "12"},
             "usages": {"limit_5h": {"used_ratio": 0.5, "reset_time": 1794247200},
                        "limitMonthTotal": {"usedRatio": "0.25"}, "limit_month_code": {"used_ratio": 0.9}}}
            """.utf8))
        let windows = try KimiCodeQuota.parse(reply, status: 200)
        #expect(windows.map(\.name) == ["5 hours", "7 days", "Month"])
        #expect(windows.map(\.used) == [50, 12, 25])
        #expect(windows[0].resetsAt == 1_794_247_200_000)
    }

    @Test func readsAtTheCodingAddress() async throws {
        let text = #"{"accounts": {"kimi-code": "kk"}}"#
        let loaded = try ConfigFile.parse(text, file: "c.jsonc") { _ in nil }
        let upstream = MockUpstream { request in
            #expect(request.request.authority == "api.kimi.ai")
            #expect(request.request.path == "/coding/v1/usages")
            #expect(request.request.headerFields[.authorization] == "Bearer kk")
            return reply(#"{"usage": {"limit": 10, "used": 1}}"#)
        }
        let gateway = Gateway(configuration: loaded.gateway, transport: upstream.transport)
        let quotas = await gateway.quotas.read(gateway: gateway, refresh: false)
        #expect(quotas.map(\.provider) == ["kimi-code"])
        #expect(quotas.first?.windows.map(\.name) == ["7 days"])
    }
}

@Suite struct MiniMaxQuotaTests {
    @Test func theGeneralBucketAndACountedOne() throws {
        let reply = try JSONValue(parsing: Array("""
            {"model_remains": [
              {"model_name": "general", "start_time": 1794229200000, "end_time": 1794247200000,
               "current_interval_remaining_percent": 88, "current_interval_status": 1,
               "weekly_start_time": 1794229200, "weekly_end_time": 1794834000, "current_weekly_remaining_percent": 95, "current_weekly_status": 1},
              {"model_name": "video", "start_time": 1794229200000, "end_time": 1794315600000,
               "current_interval_remaining_percent": 20, "current_interval_status": 1,
               "current_interval_total_count": 5, "current_interval_usage_count": 1, "current_weekly_status": 3},
              {"model_name": "speech", "current_interval_status": 3, "current_weekly_status": 3}],
             "base_resp": {"status_code": 0, "status_msg": "success"}}
            """.utf8))
        let windows = try MiniMaxQuota.parse(reply, status: 200)
        #expect(windows.map(\.name) == ["5 hours", "7 days", "Day"])
        #expect(windows.map(\.group) == [nil, nil, "Video"])
        #expect(windows.map(\.used) == [12, 5, 80])
        #expect(windows[1].resetsAt == 1_794_834_000_000)
        // 1 of 5 left, so 4 used.
        #expect(windows[2].detail == "4 / 5")
    }

    @Test func aPayAsYouGoKeyShowsNothing() async throws {
        let text = #"{"accounts": {"minimax": "mk"}}"#
        let loaded = try ConfigFile.parse(text, file: "c.jsonc") { _ in nil }
        let upstream = MockUpstream { request in
            #expect(request.request.authority == "api.minimax.io")
            #expect(request.request.path == "/v1/token_plan/remains")
            return reply(#"{"base_resp": {"status_code": 1004, "status_msg": "no token plan"}}"#)
        }
        let gateway = Gateway(configuration: loaded.gateway, transport: upstream.transport)
        #expect(await gateway.quotas.read(gateway: gateway, refresh: false).isEmpty)
    }

    @Test func aFailedReadSaysWhy() async throws {
        struct Down: Error, CustomStringConvertible { var description: String { "connection refused" } }
        let loaded = try ConfigFile.parse(#"{"accounts": {"minimax": "mk"}}"#, file: "c.jsonc") { _ in nil }
        let upstream = MockUpstream { _ in throw Down() }
        let gateway = Gateway(configuration: loaded.gateway, transport: upstream.transport)
        let quotas = await gateway.quotas.read(gateway: gateway, refresh: false)
        #expect(quotas.map(\.error) == ["connection refused"])
    }
}

@Suite struct PlanQuotaTests {
    private func parsed(_ text: String) throws -> JSONValue { try JSONValue(parsing: Array(text.utf8)) }

    @Test func openCodeGoWindows() throws {
        let windows = try OpenCodeGoQuota.parse(parsed("""
            {"usage": {"rolling": {"status": "ok", "percent": 37, "resetsAt": "2026-08-26T14:12:03.000Z"},
                       "weekly": {"status": "ok", "percent": 0, "resetsAt": "2026-08-30T00:00:00.000Z"},
                       "monthly": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-09-01T00:00:00Z"}}}
            """), status: 200)
        #expect(windows.map(\.name) == ["5 hours", "7 days", "Month"])
        #expect(windows.map(\.used) == [37, 0, 100])
        // A window at 0% has no reset time worth showing.
        #expect(windows[1].resetsAt == nil && windows[0].resetsAt != nil)
    }

    @Test func commandCodePlanAndWindows() throws {
        let (plan, windows) = try CommandCodeQuota.parse(parsed("""
            {"credits": {"planId": "individual_goat_monthly", "monthlyCredits": 41.2},
             "windowLimits": {"limited": true, "fiveHour": {"used": 3, "cap": 10, "resetAt": 1790000000000},
                              "weekly": {"used": 12, "cap": 0}}}
            """), status: 200)
        #expect(plan == "GOAT")
        #expect(windows.map(\.name) == ["5 hours"])
        #expect(windows.first?.used == 30)
        #expect(windows.first?.resetsAt == 1_790_000_000_000)
    }

    @Test func ollamaCloudAllowance() throws {
        let windows = try OllamaCloudQuota.parse(parsed("""
            {"included": {"balance_usd": 72.5, "allowance_usd": 100,
               "period": {"from": "2026-09-15T09:30:00Z", "until": "2026-10-15T09:30:00Z"}},
             "purchased": {"balance_usd": 25.0}}
            """), status: 200)
        #expect(windows.map(\.name) == ["Month"])
        #expect(abs((windows.first?.used ?? 0) - 27.5) < 0.001)
        #expect(windows.first?.detail == "$27.50 / $100.00")
        let early = try OllamaCloudQuota.parse(parsed("""
            {"included": {"session": {"remaining_percent": 75, "resets_at": "2026-10-01T07:00:00Z"},
                          "weekly": {"remaining_percent": 40}}}
            """), status: 200)
        #expect(early.map(\.name) == ["Session", "7 days"])
        #expect(early.map(\.used) == [25, 60])
        #expect(try OllamaCloudQuota.parse(parsed(#"{"purchased": {"balance_usd": 5}}"#), status: 200).isEmpty)
    }

    @Test func aKeyWithoutAPlanShowsNothing() async throws {
        let loaded = try ConfigFile.parse(#"{"accounts": {"commandcode": "ck", "opencode-go": "ok"}}"#, file: "c.jsonc") { _ in nil }
        let upstream = MockUpstream { request in
            if request.request.authority == "api.commandcode.ai" {
                #expect(request.request.path == "/alpha/billing/credits")
                #expect(request.request.headerFields[.authorization] == "Bearer ck")
                return reply(#"{"credits": {"planId": null}, "windowLimits": {"limited": false}}"#)
            }
            #expect(request.request.authority == "opencode.ai")
            #expect(request.request.path == "/inference/go/v1/usage")
            return reply(#"{"usage": {"rolling": {"percent": 5, "resetsAt": "2026-11-10T08:00:00Z"}}}"#)
        }
        let gateway = Gateway(configuration: loaded.gateway, transport: upstream.transport)
        let quotas = await gateway.quotas.read(gateway: gateway, refresh: false)
        #expect(quotas.map(\.provider) == ["opencode-go"])
    }
}
