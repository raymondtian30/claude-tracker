// Ported from tests/test_usage_stats.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private func entry(model: String = "claude-opus-5-5", ts: String = "2026-07-29T12:00:00.000Z",
                   cwd: String = "/Users/me/proj", _ usage: [String: Int] = [:]) -> JSONObject {
    var base: [String: Int] = [
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
    ]
    base.merge(usage) { _, new in new }
    return [
        "type": "assistant",
        "timestamp": ts,
        "cwd": cwd,
        "message": ["model": model, "usage": base],
    ]
}

private typealias NamedTotal = UsageStats.NamedTotal
private typealias DayTotal = UsageStats.DayTotal

@Test func splitUsageSeparates1hCacheWrites() {
    let parts = UsageStats.splitUsage([
        "input_tokens": 1,
        "output_tokens": 2,
        "cache_creation_input_tokens": 30,
        "cache_read_input_tokens": 4,
        "cache_creation": ["ephemeral_1h_input_tokens": 20, "ephemeral_5m_input_tokens": 10],
    ])
    #expect(parts == [
        "input": 1,
        "output": 2,
        "cache_write_5m": 10,
        "cache_write_1h": 20,
        "cache_read": 4,
    ])
}

@Test func splitUsageWithoutDetailCountsWritesAs5m() {
    let parts = UsageStats.splitUsage(["cache_creation_input_tokens": 7])
    #expect(parts["cache_write_5m"] == 7)
    #expect(parts["cache_write_1h"] == 0)
}

@Test func projectLabelFoldsWorktreesAndShortensHome() {
    let home = "/Users/me"
    #expect(UsageStats.projectLabel("/Users/me/app/.claude/worktrees/agent-abc", home: home) == "~/app")
    #expect(UsageStats.projectLabel("/Users/me", home: home) == "~")
    #expect(UsageStats.projectLabel("/opt/x", home: home) == "/opt/x")
    #expect(UsageStats.projectLabel(nil, home: home) == "Unknown")
}

@Test func recordEntrySkipsZeroUsageAndMissingTimestamp() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, entry(model: "<synthetic>"))
    var noTs = entry(["input_tokens": 5])
    noTs["timestamp"] = nil
    UsageStats.recordEntry(&daily, noTs)
    #expect(daily.isEmpty)
}

@Test func aggregationsAcrossDaysModelsAndProjects() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, entry(ts: "2026-07-29T12:00:00.000Z", cwd: "/a", ["input_tokens": 10]))
    UsageStats.recordEntry(&daily, entry(model: "claude-sonnet-5-5", ts: "2026-07-29T13:00:00.000Z",
                                         cwd: "/b", ["output_tokens": 5]))
    UsageStats.recordEntry(&daily, entry(ts: "2026-07-20T12:00:00.000Z", cwd: "/a",
                                         ["cache_read_input_tokens": 100]))

    let models = UsageStats.modelsAllTime(daily)
    #expect(UsageStats.modelTotals(models) == [NamedTotal("claude-opus-5-5", 110),
                                               NamedTotal("claude-sonnet-5-5", 5)])
    #expect(UsageStats.categoryTotals(models)["cache_read"] == 100)
    let july29 = Day(2026, 7, 29)
    #expect(UsageStats.totalInRange(daily, july29, july29) == 15)
    #expect(UsageStats.topProjects(daily, Day(2026, 7, 1), july29) == [NamedTotal("/a", 110),
                                                                       NamedTotal("/b", 5)])
    #expect(UsageStats.biggestDay(daily) == DayTotal(Day(2026, 7, 20), 100))
}

@Test func historyWindows() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, entry(ts: "2026-07-28T12:00:00.000Z", ["input_tokens": 1]))
    UsageStats.recordEntry(&daily, entry(ts: "2026-07-23T12:00:00.000Z", ["input_tokens": 10]))
    UsageStats.recordEntry(&daily, entry(ts: "2026-07-02T12:00:00.000Z", ["input_tokens": 100]))
    UsageStats.recordEntry(&daily, entry(ts: "2026-06-15T12:00:00.000Z", ["input_tokens": 1000]))

    let stats = UsageStats.history(daily, today: Day(2026, 7, 29))

    #expect(stats.yesterday == 1)
    #expect(stats.last7Days == 11)
    #expect(stats.thisMonth == 111)
    #expect(stats.biggestDay == DayTotal(Day(2026, 6, 15), 1000))
}

@Test func biggestDayNoneWhenEmpty() {
    #expect(UsageStats.biggestDay([:]) == nil)
}

@Test func topProjectsFoldsSubfoldersIntoParentProject() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, entry(cwd: "/x/game", ["input_tokens": 10]))
    UsageStats.recordEntry(&daily, entry(cwd: "/x/game/tools", ["input_tokens": 5]))
    UsageStats.recordEntry(&daily, entry(cwd: "/x/gamer", ["input_tokens": 1]))
    let july29 = Day(2026, 7, 29)
    #expect(UsageStats.topProjects(daily, july29, july29) == [NamedTotal("/x/game", 15),
                                                              NamedTotal("/x/gamer", 1)])
}

@Test func dailySeriesFillsMissingDaysWithZero() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, entry(ts: "2026-07-28T12:00:00.000Z", ["input_tokens": 4]))
    let series = UsageStats.dailySeries(daily, Day(2026, 7, 29), 3)
    #expect(series == [DayTotal(Day(2026, 7, 27), 0), DayTotal(Day(2026, 7, 28), 4),
                       DayTotal(Day(2026, 7, 29), 0)])
}

private func parts(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
                   cacheRead: Int = 0) -> [String: Int] {
    ["input": input, "output": output, "cache_write_5m": cacheWrite5m, "cache_write_1h": cacheWrite1h,
     "cache_read": cacheRead]
}

@Test func addUsageCreatesAndSumsBuckets() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "gpt-x", project: "~/a",
                        parts: parts(input: 3, output: 2))
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "gpt-x", project: "~/a",
                        parts: parts(cacheRead: 5), cost: 0.25)

    let day = daily.object("2026-07-29")
    #expect(jsonEqual(dig(day, "models", "gpt-x"), parts(input: 3, output: 2, cacheRead: 5)))
    #expect(jsonEqual(day?["projects"], ["~/a": 10]))
    #expect(jsonEqual(day?["recorded_cost"], ["gpt-x": 0.25]))
}

@Test func mergeDailySumsAcrossTools() {
    var a = JSONObject(), b = JSONObject()
    UsageStats.addUsage(&a, day: Day(2026, 7, 29), model: "claude-opus-5-5", project: "~/p",
                        parts: parts(input: 1))
    UsageStats.addUsage(&b, day: Day(2026, 7, 29), model: "claude-opus-5-5", project: "~/p",
                        parts: parts(input: 2), cost: 1.0)
    UsageStats.addUsage(&b, day: Day(2026, 7, 28), model: "gpt-x", project: "~/q", parts: parts(output: 4))

    let merged = UsageStats.mergeDaily([a, b])

    #expect(JSON.int(dig(merged, "2026-07-29", "models", "claude-opus-5-5", "input")) == 3)
    #expect(JSON.int(dig(merged, "2026-07-29", "projects", "~/p")) == 3)
    #expect(jsonEqual(dig(merged, "2026-07-29", "recorded_cost"), ["claude-opus-5-5": 1.0]))
    #expect(JSON.int(dig(merged, "2026-07-28", "models", "gpt-x", "output")) == 4)
    #expect(JSON.int(dig(a, "2026-07-29", "models", "claude-opus-5-5", "input")) == 1)  // inputs untouched
}

@Test func mergeMaxDailyNeverShrinks() {
    var saved = JSONObject(), current = JSONObject()
    UsageStats.addUsage(&saved, day: Day(2026, 7, 29), model: "m", project: "~/p",
                        parts: parts(input: 10), cost: 2.0)
    UsageStats.addUsage(&current, day: Day(2026, 7, 29), model: "m", project: "~/p",
                        parts: parts(input: 4, output: 7), cost: 1.0)
    UsageStats.addUsage(&current, day: Day(2026, 7, 30), model: "m", project: "~/p", parts: parts(input: 1))

    let merged = UsageStats.mergeMaxDaily(saved, current)

    #expect(JSON.int(dig(merged, "2026-07-29", "models", "m", "input")) == 10)
    #expect(JSON.int(dig(merged, "2026-07-29", "models", "m", "output")) == 7)
    #expect(JSON.int(dig(merged, "2026-07-29", "projects", "~/p")) == 11)
    #expect(JSON.double(dig(merged, "2026-07-29", "recorded_cost", "m")) == 2.0)
    #expect(JSON.int(dig(merged, "2026-07-30", "models", "m", "input")) == 1)
}

@Test func recordedCostInRange() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 7, 28), model: "m", project: "~/p", parts: parts(input: 1), cost: 1.5)
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "m", project: "~/p", parts: parts(input: 1), cost: 0.5)
    UsageStats.addUsage(&daily, day: Day(2026, 7, 1), model: "m", project: "~/p", parts: parts(input: 1), cost: 9.0)

    #expect(UsageStats.recordedCostInRange(daily, Day(2026, 7, 28), Day(2026, 7, 29)) == ["m": 2.0])
}

@Test func addUsageRecordsProjectsPerModel() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "gpt-5", project: "~/a",
                        parts: ["input": 3, "output": 2])
    UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "claude-opus-5-5", project: "~/a",
                        parts: ["input": 1])
    UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "gpt-5", project: "~/b", parts: ["input": 4])

    #expect(jsonEqual(dig(daily, "2026-11-08", "model_projects"), [
        "gpt-5": ["~/a": 5, "~/b": 4],
        "claude-opus-5-5": ["~/a": 1],
    ]))
}

@Test func mergeDailySumsModelProjects() {
    var a = JSONObject(), b = JSONObject()
    UsageStats.addUsage(&a, day: Day(2026, 11, 8), model: "gpt-5", project: "~/a", parts: ["input": 3])
    UsageStats.addUsage(&b, day: Day(2026, 11, 8), model: "gpt-5", project: "~/a", parts: ["input": 4])

    #expect(jsonEqual(dig(UsageStats.mergeDaily([a, b]), "2026-11-08", "model_projects"),
                      ["gpt-5": ["~/a": 7]]))
}

@Test func filterDailyKeepsOnlyMatchingModelsAndTheirProjects() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "gpt-5", project: "~/a",
                        parts: ["input": 3], cost: 0.5)
    UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "claude-opus-5-5", project: "~/b",
                        parts: ["input": 9], cost: 2.0)

    let kept = UsageStats.filterDaily(daily) { $0.hasPrefix("gpt") }

    let bucket = kept.object("2026-11-08")
    #expect(bucket?.object("models").map { Array($0.keys) } == ["gpt-5"])
    #expect(jsonEqual(bucket?["projects"], ["~/a": 3]))
    #expect(jsonEqual(bucket?["recorded_cost"], ["gpt-5": 0.5]))
}

@Test func filterDailyOldBucketWithoutModelProjects() {
    let parts: JSONObject = ["input": 5, "output": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0]
    let onlyGpt: JSONObject = ["2026-11-01": ["models": ["gpt-5": parts], "projects": ["~/a": 5]]]
    let mixed: JSONObject = ["2026-11-01": ["models": ["gpt-5": parts, "claude-opus-5-5": parts],
                                            "projects": ["~/a": 10]]]

    let keep = { (model: String) in model.hasPrefix("gpt") }
    #expect(jsonEqual(dig(UsageStats.filterDaily(onlyGpt, keepModel: keep), "2026-11-01", "projects"),
                      ["~/a": 5]))
    // Can't tell which project the gpt tokens came from: leave projects out.
    #expect(jsonEqual(dig(UsageStats.filterDaily(mixed, keepModel: keep), "2026-11-01", "projects"),
                      JSONObject()))
    #expect(jsonEqual(dig(UsageStats.filterDaily(mixed, keepModel: keep), "2026-11-01", "models"),
                      ["gpt-5": parts]))
}

@Test func filterDailyDropsDaysWithNoMatchingModels() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "claude-opus-5-5", project: "~/b",
                        parts: ["input": 9])

    #expect(UsageStats.filterDaily(daily) { $0.hasPrefix("gpt") }.isEmpty)
}

// Folding: `~`, `/` and an empty label are never a parent, so they can't
// absorb every other label.

private func daily(_ days: [(Day, [String: Int])]) -> JSONObject {
    var daily = JSONObject()
    for (day, projects) in days {
        for (project, tokens) in projects {
            UsageStats.addUsage(&daily, day: day, model: "claude-opus-5-5", project: project,
                                parts: ["input_tokens": tokens])
        }
    }
    return daily
}

private func rows(_ daily: JSONObject) -> [NamedTotal] {
    UsageStats.topProjects(daily, Day(2026, 11, 1), Day(2026, 11, 9))
}

@Test func foldSkipsHomeAndRoot() {
    let data = daily([(Day(2026, 11, 8), ["~": 1, "~/a": 20, "~/b": 30])])
    #expect(rows(data) == [NamedTotal("~/b", 30), NamedTotal("~/a", 20), NamedTotal("~", 1)])
    let root = daily([(Day(2026, 11, 8), ["/": 1, "/x/a": 20, "/y": 30])])
    #expect(rows(root) == [NamedTotal("/y", 30), NamedTotal("/x/a", 20), NamedTotal("/", 1)])
}

@Test func homeRowIsSeparate() {
    let data = daily([(Day(2026, 11, 8), ["~": 5, "~/a": 20, "~/": 1])])
    #expect(rows(data) == [NamedTotal("~/a", 20), NamedTotal("~", 5), NamedTotal("~/", 1)])
}

@Test func foldStillFoldsRealSubfolders() {
    let data = daily([(Day(2026, 11, 8), ["~/a": 10, "~/a/b": 5, "~/ab": 1])])
    #expect(rows(data) == [NamedTotal("~/a", 15), NamedTotal("~/ab", 1)])
}

@Test func topProjectsOverAWeekWithAHomeDay() {
    let data = daily([
        (Day(2026, 11, 3), ["~/Downloads/game": 300]),
        (Day(2026, 11, 6), ["~/Desktop/comp": 100]),
        (Day(2026, 11, 8), ["~": 2]),
    ])
    #expect(rows(data) == [NamedTotal("~/Downloads/game", 300), NamedTotal("~/Desktop/comp", 100),
                           NamedTotal("~", 2)])
}
