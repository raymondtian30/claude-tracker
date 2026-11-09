// Ported from tests/test_limits.py, test for test.
//
// Python's limit dicts are `Limits.Level` structs here. A dict from
// codex_limits has no "id"/"name"/"kind"/"reached" keys; the struct's
// defaults ("" / nil / false) stand for those missing keys.

import Foundation
import Testing
@testable import TrackerCore

private typealias Level = Limits.Level

private let NOW = LocalTime.timestamp(2026, 11, 8, 12, 0, 0)

@Test func windowForMinutes() {
    #expect(Limits.windowForMinutes(300) == "five_hour")
    #expect(Limits.windowForMinutes(10080) == "weekly")
    #expect(Limits.windowForMinutes(43200) == "monthly")
}

@Test func codexLimitsFromItsRateLimitRecord() {
    let record: JSONObject = [
        "primary": ["used_percent": 83.0, "window_minutes": 300, "resets_at": NOW + 600],
        "secondary": ["used_percent": 40.5, "window_minutes": 10080, "resets_at": NOW + 9999],
        "plan_type": "plus",
    ]

    #expect(Limits.codexLimits(record, now: NOW) == [
        Level(window: "five_hour", label: "5-hour", percent: 83.0, resetsAt: NOW + 600),
        Level(window: "weekly", label: "Weekly", percent: 40.5, resetsAt: NOW + 9999),
    ])
}

@Test func codexLimitWhoseWindowHasResetReadsZero() {
    let record: JSONObject = [
        "primary": ["used_percent": 83.0, "window_minutes": 43200, "resets_at": NOW - 1],
        "secondary": NSNull(),
    ]

    #expect(Limits.codexLimits(record, now: NOW) == [
        Level(window: "monthly", label: "Monthly", percent: 0.0, resetsAt: nil),
    ])
}

@Test func codexLimitsWithoutARecord() {
    #expect(Limits.codexLimits(nil, now: NOW) == [])
}

@Test func claudeLimitReachedUntilItResets() {
    let hits: JSONObject = ["five_hour": NOW + 3600, "seven_day": NOW - 10]

    #expect(Limits.reachedClaudeLimits(hits, now: NOW) == [
        Level(window: "five_hour", label: "5-hour", percent: 100.0, resetsAt: NOW + 3600, reached: true),
    ])

    let model: JSONObject = ["seven_day_opus": NOW + 60]
    #expect(Limits.reachedClaudeLimits(model, now: NOW) == [
        Level(kind: "weekly_opus", window: "weekly", label: "Weekly", percent: 100.0,
              resetsAt: NOW + 60, reached: true),
    ])
}

@Test func fallbackOpusAndSonnetIdsMatchFetched() {
    let hits: JSONObject = ["seven_day_opus": NOW + 60, "seven_day_sonnet": NOW + 60,
                            "seven_day": NOW + 60]
    let levels = Limits.planLevels(["claude_usage_enabled": false, "claude_limit_hits": hits],
                                   toolKeys: ["claude_code"], now: NOW)

    #expect(levels.map(\.id) == ["claude_code:weekly", "claude_code:weekly_opus", "claude_code:weekly_sonnet"])
    #expect(Limits.claudeLimitKinds == ["seven_day_opus": "weekly_opus", "seven_day_sonnet": "weekly_sonnet"])
}

private func claudeUsage(_ changes: JSONObject = [:]) -> JSONObject {
    let limits: [JSONObject] = [
        ["kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 23.0,
         "resets_at": NOW + 600],
        ["kind": "weekly", "window": "weekly", "label": "Weekly", "percent": 41.0,
         "resets_at": NOW - 1],
    ]
    var usage: JSONObject = ["limits": limits, "error": NSNull(), "fetched_at": NOW]
    usage.merge(changes) { _, new in new }
    return usage
}

@Test func claudeLimitsUseAnthropicsPercentages() {
    let state: JSONObject = ["claude_usage": claudeUsage(), "claude_limit_hits": ["five_hour": NOW + 60]]

    let found = Limits.claudeLimits(state, now: NOW)
    #expect(found.map(\.kind) == ["five_hour", "weekly"])
    #expect(found.map(\.percent) == [23.0, 0.0])
    #expect(found.map(\.resetsAt) == [NOW + 600, nil])  // weekly's reset time passed: 0% until the next fetch
}

@Test func claudeLimitsFallBackToTheLogsWithoutPercentages() {
    let hits: JSONObject = ["five_hour": NOW + 60]

    for var state: JSONObject in [["claude_usage": claudeUsage(["limits": [Any](), "error": "offline"])],
                                  ["claude_usage": claudeUsage(), "claude_usage_enabled": false]] {
        state["claude_limit_hits"] = hits
        #expect(Limits.claudeLimits(state, now: NOW).map(\.percent) == [100.0])
    }
}

private func level(id: String = "codex:five_hour", window: String = "five_hour", percent: Double = 80.0,
                   resetsAt: Double? = nil) -> Level {
    Level(id: id, name: "Codex", window: window, label: "5-hour", percent: percent, resetsAt: resetsAt)
}

@Test func alertOnceWhenCrossingTheThreshold() {
    var (messages, above) = Limits.alertsToSend([level()], thresholds: [75], windowsOn: ["five_hour"], above: [])

    #expect(messages == ["Codex: 5-hour usage is at 80%."])
    #expect(above == ["codex:five_hour@75"])

    (messages, above) = Limits.alertsToSend([level(percent: 90.0)], thresholds: [75], windowsOn: ["five_hour"],
                                            above: above)
    #expect(messages == [])  // already told

    (messages, above) = Limits.alertsToSend([level(percent: 10.0)], thresholds: [75], windowsOn: ["five_hour"],
                                            above: above)
    #expect(above == [])  // dropped below (e.g. the window reset): ready to alert again
}

@Test func alertAgainAtEachHigherThreshold() {
    var (messages, above) = Limits.alertsToSend([level(percent: 76.0)], thresholds: [75, 90],
                                                windowsOn: ["five_hour"], above: [])
    #expect(messages == ["Codex: 5-hour usage is at 76%."])

    (messages, above) = Limits.alertsToSend([level(percent: 85.0)], thresholds: [75, 90],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages == [])

    (messages, above) = Limits.alertsToSend([level(percent: 91.0)], thresholds: [75, 90],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages == ["Codex: 5-hour usage is at 91%."])
    #expect(above.sorted() == ["codex:five_hour@75", "codex:five_hour@90"])

    (messages, above) = Limits.alertsToSend([level(percent: 80.0)], thresholds: [75, 90],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages == [] && above == ["codex:five_hour@75"])  // 90 can alert again
}

@Test func jumpingPastSeveralThresholdsSendsOneAlert() {
    let (messages, above) = Limits.alertsToSend([level(percent: 95.0)], thresholds: [75, 90],
                                                windowsOn: ["five_hour"], above: [])

    #expect(messages == ["Codex: 5-hour usage is at 95%."])
    #expect(above.sorted() == ["codex:five_hour@75", "codex:five_hour@90"])
}

@Test func migrateAlertStateKeepsTheOldSingleThreshold() {
    var state: JSONObject = ["alert_threshold": 80, "alerts_above": ["codex:five_hour"]]

    Limits.migrateAlertState(&state)

    #expect(jsonEqual(state, ["alert_thresholds": [80], "alerts_above": ["codex:five_hour@80"]]))
}

@Test func migrateAlertStateDefaultsAndLeavesNewStateAlone() {
    var state = JSONObject()
    Limits.migrateAlertState(&state)
    #expect(jsonEqual(state, ["alert_thresholds": [75], "alerts_above": [String]()]))

    state = ["alert_thresholds": [75, 90], "alerts_above": ["x@90"]]
    Limits.migrateAlertState(&state)
    #expect(jsonEqual(state, ["alert_thresholds": [75, 90], "alerts_above": ["x@90"]]))
}

@Test func alertsOnlyForChosenWindows() {
    let (messages, above) = Limits.alertsToSend([level(window: "weekly")], thresholds: [75],
                                                windowsOn: ["five_hour"], above: [])

    #expect(messages == [] && above == [])
}

@Test func alertSaysWhenItResets() {
    let today = LocalTime.timestamp(2026, 11, 8, 15, 30)
    let later = LocalTime.timestamp(2026, 11, 20, 18, 46)

    var (messages, _) = Limits.alertsToSend([level(resetsAt: today)], thresholds: [75],
                                            windowsOn: ["five_hour"], above: [], now: NOW)
    #expect(messages == ["Codex: 5-hour usage is at 80%. Resets at 3:30 PM."])

    (messages, _) = Limits.alertsToSend([level(resetsAt: later)], thresholds: [75],
                                        windowsOn: ["five_hour"], above: [], now: NOW)
    #expect(messages == ["Codex: 5-hour usage is at 80%. Resets on Nov 20."])
}

private func codexState(used: Double = 83.0, resetsAt: Double = NOW + 600, windowMinutes: Int = 300) -> JSONObject {
    let limits: JSONObject = ["at": "2026-11-08T11:00:00Z", "rate_limits": [
        "primary": ["used_percent": used, "window_minutes": windowMinutes, "resets_at": resetsAt],
        "secondary": NSNull()]]
    return ["sources": ["codex": ["files": ["f": ["size": 1, "mtime": 1, "daily": JSONObject(),
                                                  "limits": limits]]]]]
}

@Test func planLevelsForCodexAndClaude() {
    var state = codexState()
    state["claude_limit_hits"] = ["five_hour": NOW + 60]

    let levels = Limits.planLevels(state, toolKeys: ["claude_code", "codex", "opencode"], now: NOW)

    #expect(levels.map(\.id) == ["claude_code:five_hour", "codex:five_hour"])
    #expect(levels.map(\.name) == ["Claude Code", "Codex"])
    #expect(levels.map(\.percent) == [100.0, 83.0])
}

@Test func planLevelsGiveEachClaudeLimitItsOwnId() {
    var usage = claudeUsage()
    usage["limits"] = (usage.array("limits") ?? []) + [
        ["kind": "weekly_opus", "window": "weekly", "label": "Weekly · Opus", "percent": 5.0,
         "resets_at": NSNull()] as JSONObject,
    ]

    let levels = Limits.planLevels(["claude_usage": usage], toolKeys: ["claude_code"], now: NOW)

    #expect(levels.map(\.id) == ["claude_code:five_hour", "claude_code:weekly", "claude_code:weekly_opus"])
}

@Test func limitWindowsAreOnlyTheOnesAToolHas() {
    // Python edits the fixture's nested dict in place; here the fixture
    // builder takes the window length instead.
    let freeCodex = codexState(windowMinutes: 43200)

    #expect(Limits.limitWindows([:], toolKeys: ["claude_code"], now: NOW) == ["five_hour", "weekly"])
    #expect(Limits.limitWindows(freeCodex, toolKeys: ["codex"], now: NOW) == ["monthly"])
    #expect(Limits.limitWindows(freeCodex, toolKeys: ["claude_code", "codex"], now: NOW) == [
        "five_hour", "weekly", "monthly"])
    #expect(Limits.limitWindows([:], toolKeys: ["codex", "opencode"], now: NOW) == [])
}

@Test func levelsForAlertsCoverTheEnabledToolsPlanLimits() {
    var state = codexState()
    state["enabled_tools"] = ["codex"]

    let levels = Limits.levelsForAlerts(state, now: NOW)

    #expect(levels.map { "\($0.id) \(Int($0.percent.rounded()))" } == ["codex:five_hour 83"])
}
