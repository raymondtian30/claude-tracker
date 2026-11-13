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
private typealias RangePoint = UsageStats.RangePoint

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

@Test func hourlyTotalsMergeAndFilterByModel() {
    let day = Day(2026, 7, 29)
    var a = JSONObject(), b = JSONObject()
    UsageStats.addUsage(&a, day: day, model: "gpt-x", project: "~/a", parts: parts(input: 5),
                        at: LocalTime.timestamp(2026, 7, 29, 9))
    UsageStats.addUsage(&b, day: day, model: "gpt-x", project: "~/b", parts: parts(output: 7),
                        at: LocalTime.timestamp(2026, 7, 29, 9))
    UsageStats.addUsage(&b, day: day, model: "claude-y", project: "~/b", parts: parts(input: 3),
                        at: LocalTime.timestamp(2026, 7, 29, 15))
    let merged = UsageStats.mergeDaily([a, b])
    let hours = UsageStats.hourlySeries(merged, day: day)
    #expect(hours.count == 24 && hours[9] == 12 && hours[15] == 3)
    #expect(hours.reduce(0, +) == 15)
    let gptOnly = UsageStats.filterDaily(merged) { $0 == "gpt-x" }
    #expect(UsageStats.hourlySeries(gptOnly, day: day)[9] == 12)
    #expect(UsageStats.hourlySeries(gptOnly, day: day)[15] == 0)
    #expect(UsageStats.hourlySeries(UsageStats.mergeMaxDaily(a, b), day: day)[9] == 7)
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

// Effort: Claude Code's `effort` on assistant entries, and merging, filtering
// and reading the per-day `efforts` maps.

private func effortEntry(_ effort: Any?, perTurn: Any? = nil, model: String = "claude-opus-5-5",
                         tokens: Int = 10) -> JSONObject {
    var e = entry(model: model, ["input_tokens": tokens])
    if let effort = effort { e["effort"] = effort }
    if let perTurn = perTurn { e["perTurnEffort"] = perTurn }
    return e
}

private let july29 = Day(2026, 7, 29)

private func claudeEfforts(_ daily: JSONObject) -> Any? {
    dig(daily, "2026-07-29", "efforts")
}

@Test func claudeEffortField() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, effortEntry("high"))
    UsageStats.recordEntry(&daily, effortEntry("medium", tokens: 5))
    UsageStats.recordEntry(&daily, effortEntry("high", tokens: 1))

    #expect(jsonEqual(claudeEfforts(daily), ["claude-opus-5-5": ["high": 11, "medium": 5]]))
}

@Test func claudePerTurnEffortFallback() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, effortEntry(nil, perTurn: "xhigh"))

    #expect(jsonEqual(claudeEfforts(daily), ["claude-opus-5-5": ["xhigh": 10]]))
}

@Test func claudeBothEffortFieldsPresentAndDifferentUsesEffort() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, effortEntry("medium", perTurn: "high"))

    #expect(jsonEqual(claudeEfforts(daily), ["claude-opus-5-5": ["medium": 10]]))
}

@Test func claudeEntryWithoutEffortLeavesNoEffortsKey() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, effortEntry(nil))
    UsageStats.recordEntry(&daily, effortEntry(NSNull(), perTurn: NSNull()))
    UsageStats.recordEntry(&daily, effortEntry("not an effort!"))

    #expect(claudeEfforts(daily) == nil)
}

@Test func wrongTypedEffortsReadAsNone() {
    for bad: Any in ["high", ["high"], 5, NSNull(), ["claude-opus-5-5": "high"], ["claude-opus-5-5": ["high": "x"]]] {
        var daily = JSONObject()
        UsageStats.recordEntry(&daily, effortEntry(nil))
        var bucket = daily.object("2026-07-29")!
        bucket["efforts"] = bad
        daily["2026-07-29"] = bucket
        #expect(UsageStats.effortsInRange(daily, july29, july29).values.allSatisfy { $0.isEmpty })
        // Merging and filtering must not trap on it either.
        _ = UsageStats.mergeDaily([daily, daily])
        _ = UsageStats.filterDaily(daily) { _ in true }
    }
}

@Test func combineBucketsKeepsEffortsSumAndMax() {
    var a = JSONObject(), b = JSONObject()
    UsageStats.recordEntry(&a, effortEntry("high", tokens: 10))
    UsageStats.recordEntry(&b, effortEntry("high", tokens: 4))
    UsageStats.recordEntry(&b, effortEntry("low", tokens: 3))

    #expect(jsonEqual(claudeEfforts(UsageStats.mergeDaily([a, b])),
                      ["claude-opus-5-5": ["high": 14, "low": 3]]))
    #expect(jsonEqual(claudeEfforts(UsageStats.mergeMaxDaily(a, b)),
                      ["claude-opus-5-5": ["high": 10, "low": 3]]))
}

@Test func filterDailyKeepsEffortsOfKeptModels() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, effortEntry("high", model: "claude-opus-5-5"))
    UsageStats.recordEntry(&daily, effortEntry("low", model: "gpt-5.6-luna"))

    let filtered = UsageStats.filterDaily(daily) { $0.hasPrefix("claude") }

    #expect(jsonEqual(claudeEfforts(filtered), ["claude-opus-5-5": ["high": 10]]))
}

@Test func effortsInRangeMatchesModelsInRange() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, effortEntry("high", tokens: 10))
    UsageStats.recordEntry(&daily, effortEntry("medium", tokens: 5))
    UsageStats.recordEntry(&daily, effortEntry(nil, tokens: 2))  // no effort

    let efforts = UsageStats.effortsInRange(daily, july29, july29)
    #expect(efforts == ["claude-opus-5-5": ["high": 10, "medium": 5]])
    #expect(UsageStats.effortsAllTime(daily) == efforts)
    let total = UsageStats.modelTotals(UsageStats.modelsInRange(daily, july29, july29)).first!.tokens
    #expect(total == 17)  // the 2 without an effort are the remainder
    #expect(UsageStats.effortsInRange(daily, Day(2026, 7, 30), Day(2026, 7, 30)).isEmpty)
}

// MARK: - Chart ranges

private func dailyWith(_ tokensByDay: [(String, Int)]) -> JSONObject {
    var daily = JSONObject()
    for (iso, tokens) in tokensByDay {
        UsageStats.recordEntry(&daily, entry(ts: "\(iso)T12:00:00.000Z", ["input_tokens": tokens]))
    }
    return daily
}

@Test func earliestDayIsTheOldestBucket() {
    #expect(UsageStats.earliestDay(JSONObject()) == nil)
    #expect(UsageStats.earliestDay(dailyWith([("2026-07-29", 1), ("2026-03-02", 1), ("bad", 1)])) == Day(2026, 3, 2))
}

@Test func rangeSeriesIsOnePointPerDayWhenItFits() {
    let daily = dailyWith([("2026-07-28", 4)])
    let series = UsageStats.rangeSeries(daily, from: Day(2026, 7, 27), to: Day(2026, 7, 29))
    #expect(series == [RangePoint(Day(2026, 7, 27), Day(2026, 7, 27), 0), RangePoint(Day(2026, 7, 28), Day(2026, 7, 28), 4),
                       RangePoint(Day(2026, 7, 29), Day(2026, 7, 29), 0)])
}

@Test func rangeSeriesGroupsLongRangesAndKeepsEveryToken() {
    let first = Day(2026, 1, 1)
    let daily = dailyWith([("2026-01-01", 5), ("2026-04-10", 7), ("2026-07-29", 11)])
    let series = UsageStats.rangeSeries(daily, from: first, to: Day(2026, 7, 29), maxPoints: 60)
    #expect(series.count <= 60 && series.count > 20)
    #expect(series.first?.start == first && series.last?.end == Day(2026, 7, 29))
    #expect(series.reduce(0) { $0 + $1.tokens } == 23)
    // Groups follow each other with no gap and no overlap.
    for (a, b) in zip(series, series.dropFirst()) { #expect(a.end.adding(days: 1) == b.start) }
}

@Test func rangeSeriesOfOneDayAndOfAnEmptyRange() {
    let daily = dailyWith([("2026-07-29", 3)])
    #expect(UsageStats.rangeSeries(daily, from: Day(2026, 7, 29), to: Day(2026, 7, 29))
            == [RangePoint(Day(2026, 7, 29), Day(2026, 7, 29), 3)])
    #expect(UsageStats.rangeSeries(daily, from: Day(2026, 7, 30), to: Day(2026, 7, 29)).isEmpty)
}

@Test func topProjectsNeverFoldIntoContainerFolders() {
    var daily = JSONObject()
    let day = Day(2026, 11, 10)
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Downloads", parts: ["input": 3])
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Downloads/FPS Game", parts: ["input": 100])
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Downloads/FPS Game/tools", parts: ["input": 7])
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Desktop", parts: ["input": 2])
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Desktop/app", parts: ["input": 50])
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/game", parts: ["input": 10])
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/game/tools", parts: ["input": 5])
    #expect(UsageStats.topProjects(daily, day, day) == [
        NamedTotal("~/Downloads/FPS Game", 107), NamedTotal("~/Desktop/app", 50), NamedTotal("~/game", 15),
        NamedTotal("~/Downloads", 3), NamedTotal("~/Desktop", 2),
    ])
}

@Test func containerFoldersMatchWithOrWithoutTrailingSlash() {
    #expect(UsageStats.isContainerFolder("~/Downloads"))
    #expect(UsageStats.isContainerFolder("~/Downloads/"))
    #expect(!UsageStats.isContainerFolder("~/Downloads/FPS Game"))
    #expect(!UsageStats.isContainerFolder("~/game"))
}

@Test func aContainerFoldersOwnRowSaysItIsTheFolderItself() {
    var daily = JSONObject()
    let day = Day(2026, 11, 10)
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Downloads/FPS Game", parts: ["input": 100])
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Downloads", parts: ["input": 3])
    let view = Tools.View(key: "claude_code", name: "Claude Code", daily: daily, grandTotal: 103, error: nil)
    let tab = PanelModel.buildPanel(view, state: [:], sessions: [], friends: [], showLeaderboard: false, today: day)
        .first { $0.key == "projects" }!
    let labels = tab.cards.flatMap(\.items).compactMap { item -> String? in
        if case let .bar(label, _, _, _, _) = item { return label }
        return nil
    }
    #expect(labels == ["FPS Game", "Downloads (folder itself)"])
}

@Test func theICloudFoldersNeverTakeInTheirProjects() {
    var daily = JSONObject()
    let day = Day(2026, 11, 10)
    UsageStats.addUsage(&daily, day: day, model: "m", project: "~/Library/Mobile Documents", parts: ["input": 1])
    UsageStats.addUsage(&daily, day: day, model: "m",
                        project: "~/Library/Mobile Documents/com~apple~CloudDocs/app", parts: ["input": 9])
    #expect(UsageStats.topProjects(daily, day, day).count == 2)
}
