import Foundation
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// Records one ended request of `session` to `activity`.
private func record(
    _ activity: Activity, session: String = "s-1", subagent: String? = nil, model: String = "fast", route: String? = "fast",
    targets: [String] = ["zai/glm", "kilo/glm"], served: String?, tokens: TokenCounts? = nil, started: Int64 = LocalDay.nowMilliseconds(),
) {
    let tracker = activity.begin(RequestRecord(
        started: started, origin: RequestOrigin(program: "Claude Code", session: session, subagent: subagent),
        clientProtocol: "messages", model: model, stream: true,
    ))
    activity.update(tracker.id) { record in
        record.route = route
        record.targets = targets
        if let served {
            record.served = served
            record.provider = String(served.split(separator: "/")[0])
            record.account = "a"
        }
    }
    tracker.finish(status: served == nil ? 503 : 200, tokens: tokens)
}

@Suite struct SessionAndUsageViewTests {
    @Test func aSessionKeepsItsTurnsInOrderAndReadsThemBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("unladen-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let activity = Activity(log: UsageLog(directory: directory))
        record(activity, served: "zai/glm", tokens: TokenCounts(input: 100, output: 5, cacheRead: 0, cacheWrite: 90))
        record(activity, served: "kilo/glm", tokens: TokenCounts(input: 120, output: 5))
        record(activity, subagent: "agent-1", served: nil)

        let turns = try #require(activity.session("s-1")?.turns)
        #expect(turns.map(\.served) == ["zai/glm", "kilo/glm", nil])
        #expect(turns.map(\.target) == [1, 2, nil])
        #expect(turns.map(\.subagent) == [nil, nil, "agent-1"])
        #expect(turns.map(\.failed) == [false, false, true])
        #expect(turns[0].tokens?.cacheWrite == 90)

        let restored = Activity(log: UsageLog(directory: directory))
        restored.restore()
        #expect(restored.session("s-1")?.turns == turns)
    }

    @Test func aSessionKeepsItsLatestTurns() {
        let activity = Activity()
        for _ in 0..<(SessionSummary.turnLimit + 5) { record(activity, served: "zai/glm") }
        #expect(activity.session("s-1")?.turns.count == SessionSummary.turnLimit)
        #expect(activity.session("s-1")?.requests == SessionSummary.turnLimit + 5)
    }

    @Test func placementsAreListedBySession() throws {
        let placements = Placements()
        let main = try #require(Placements.conversation(RequestOrigin(program: "x", session: "s-1"), model: "Opus"))
        let agent = try #require(Placements.conversation(RequestOrigin(program: "x", session: "s-1", subagent: "a-1"), model: "haiku"))
        let other = try #require(Placements.conversation(RequestOrigin(program: "x", session: "s-10"), model: "opus"))
        placements.answering("zai/glm", estimate: nil, lifetime: .seconds(3600), for: placements.ticket(for: main))
        placements.answering("kilo/glm", estimate: nil, for: placements.ticket(for: agent))
        placements.answering("kilo/glm", estimate: nil, for: placements.ticket(for: other))

        let listed = placements.placements(ofSession: "s-1").sorted { $0.model < $1.model }
        #expect(listed.map(\.model) == ["haiku", "opus"])
        #expect(listed.map(\.subagent) == ["a-1", nil])
        #expect(listed.map(\.placement.reference) == ["kilo/glm", "zai/glm"])
        #expect(listed.map(\.placement.lifetime) == [.seconds(300), .seconds(3600)])
    }

    @Test func usageShowsEachRoutesTargetsAndFallbacks() throws {
        let activity = Activity()
        record(activity, served: "zai/glm", tokens: TokenCounts(input: 10, output: 1))
        record(activity, served: "zai/glm", tokens: TokenCounts(input: 10, output: 1))
        record(activity, served: "kilo/glm", tokens: TokenCounts(input: 30, output: 3))
        record(activity, model: "zai/glm", route: nil, targets: [], served: "zai/glm", tokens: TokenCounts(input: 1, output: 1))

        let usage = AdminActivity.usage(activity.usage(days: 1), days: 1)
        let routes = try #require(usage["routes"]?.arrayValue)
        #expect(routes.compactMap { $0["name"]?.stringValue } == ["fast", "(none)"])
        let fast = routes[0]
        #expect(fast["requests"]?.numberValue?.int == 3)
        #expect(fast["fallbacks"]?.numberValue?.int == 1)
        let targets = try #require(fast["targets"]?.arrayValue)
        #expect(targets.compactMap { $0["model"]?.stringValue } == ["zai/glm", "kilo/glm"])
        #expect(targets.compactMap { $0["requests"]?.numberValue?.int } == [2, 1])
        #expect(usage["total"]?["name"] == nil)
        #expect(usage["total"]?["requests"]?.numberValue?.int == 4)

        // By hour for a day: the requests fall in this hour's slot.
        let trend = try #require(usage["trend"])
        #expect(trend["slots"]?.arrayValue?.count == 24)
        let hour = LocalDay(milliseconds: LocalDay.nowMilliseconds()).hour
        let fastLine = try #require(trend["routes"]?.arrayValue?.first)
        #expect(fastLine["requests"]?.arrayValue?[hour].numberValue?.int == 3)
        #expect(fastLine["tokens"]?.arrayValue?[hour].numberValue?.int == 55)
    }

    @Test func usageOverDaysIsByDayEndingToday() throws {
        let activity = Activity()
        let now = LocalDay.nowMilliseconds()
        record(activity, served: "zai/glm", tokens: TokenCounts(input: 10, output: 1), started: now - 2 * 86_400_000)
        record(activity, served: "zai/glm", tokens: TokenCounts(input: 20, output: 2), started: now)

        let usage = AdminActivity.usage(activity.usage(days: 7, now: now), days: 7, now: now)
        let slots = try #require(usage["trend"]?["slots"]?.arrayValue?.compactMap { $0.numberValue?.int })
        #expect(slots.count == 7)
        #expect(slots.last == LocalDay(milliseconds: now).key)
        let line = try #require(usage["trend"]?["accounts"]?.arrayValue?.first?["tokens"]?.arrayValue?.compactMap { $0.numberValue?.int })
        #expect(line == [0, 0, 0, 0, 11, 0, 22])
    }
}
