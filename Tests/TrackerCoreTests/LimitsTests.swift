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

    #expect(messages == ["Codex (5-hour) usage reached 75%."])
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
    #expect(messages == ["Codex (5-hour) usage reached 75%."])

    (messages, above) = Limits.alertsToSend([level(percent: 85.0)], thresholds: [75, 90],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages == [])

    (messages, above) = Limits.alertsToSend([level(percent: 91.0)], thresholds: [75, 90],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages == ["Codex (5-hour) usage reached 90%."])
    #expect(above.sorted() == ["codex:five_hour@75", "codex:five_hour@90"])

    (messages, above) = Limits.alertsToSend([level(percent: 80.0)], thresholds: [75, 90],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages == [] && above == ["codex:five_hour@75"])  // 90 can alert again
}

@Test func jumpingPastSeveralThresholdsSendsOneAlert() {
    let (messages, above) = Limits.alertsToSend([level(percent: 95.0)], thresholds: [75, 90],
                                                windowsOn: ["five_hour"], above: [])

    #expect(messages == ["Codex (5-hour) usage reached 90%."])
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
    #expect(messages == ["Codex (5-hour) usage reached 75%. Resets at 3:30 PM."])

    (messages, _) = Limits.alertsToSend([level(resetsAt: later)], thresholds: [75],
                                        windowsOn: ["five_hour"], above: [], now: NOW)
    #expect(messages == ["Codex (5-hour) usage reached 75%. Resets on Nov 20."])
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

// MARK: - Milestone alerts: carrying keys and seeding

private func claudeLevel(_ kind: String = "weekly", percent: Double = 80.0) -> Level {
    Level(id: "claude_code:\(kind)", name: "Claude Code", kind: kind, window: "weekly", label: "Weekly",
          percent: percent, resetsAt: nil)
}

private let bothWindows = ["five_hour", "weekly"]

@Test func keySurvivesPassWhereLevelIsMissingAndUnknown() {
    let (messages, above) = Limits.alertsToSend([], thresholds: [75], windowsOn: bothWindows,
                                                above: ["claude_code:weekly@75"],
                                                unknownIDPrefixes: ["claude_code:"])
    #expect(messages == [])
    #expect(above == ["claude_code:weekly@75"])
}

@Test func launchWithLevelOverThresholdSendsNothing() {
    let (messages, above) = Limits.alertsToSend([level()], thresholds: [50, 75], windowsOn: ["five_hour"],
                                                above: [], seeding: true)
    #expect(messages == [])
    #expect(above == ["codex:five_hour@50", "codex:five_hour@75"])
}

@Test func seedingWritesKeysButSendsNothing() {
    let (messages, above) = Limits.alertsToSend([claudeLevel(percent: 100.0)], thresholds: [75],
                                                windowsOn: bothWindows, above: [], seeding: true)
    #expect(messages == [])
    #expect(above == ["claude_code:weekly@75"])
}

@Test func crossingAfterSeedingSends() {
    var (messages, above) = Limits.alertsToSend([level(percent: 40.0)], thresholds: [75],
                                                windowsOn: ["five_hour"], above: [], seeding: true)
    #expect(messages == [] && above == [])

    (messages, above) = Limits.alertsToSend([level(percent: 80.0)], thresholds: [75],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages.count == 1)
    #expect(above == ["codex:five_hour@75"])
}

@Test func fallbackLevelFirstSeenAfterLaunchAlerts() {
    var (messages, above) = Limits.alertsToSend([], thresholds: [75], windowsOn: bothWindows, above: [],
                                                seeding: true)
    #expect(messages == [] && above == [])

    // A log-only limit reached after launch is not silenced by the seed.
    let hit = Level(id: "claude_code:weekly_opus", name: "Claude Code", kind: "weekly_opus",
                    window: "weekly", label: "Weekly", percent: 100.0, resetsAt: NOW + 60, reached: true)
    (messages, above) = Limits.alertsToSend([hit], thresholds: [75], windowsOn: bothWindows, above: above,
                                            now: NOW)
    #expect(messages.count == 1)
    #expect(above == ["claude_code:weekly_opus@75"])
}

@Test func fallbackHitResetHitAgainAlerts() {
    let hit = Level(id: "claude_code:five_hour", name: "Claude Code", window: "five_hour", label: "5-hour",
                    percent: 100.0, resetsAt: NOW + 60, reached: true)
    var (messages, above) = Limits.alertsToSend([hit], thresholds: [75], windowsOn: bothWindows, above: [],
                                                now: NOW)
    #expect(messages.count == 1)

    // The window ended: Percentages are off, so the fallback list is authoritative and the key goes.
    (messages, above) = Limits.alertsToSend([], thresholds: [75], windowsOn: bothWindows, above: above)
    #expect(messages == [] && above == [])

    (messages, above) = Limits.alertsToSend([hit], thresholds: [75], windowsOn: bothWindows, above: above,
                                            now: NOW)
    #expect(messages.count == 1)
}

private func claudeState(percentages: Bool, limits: [JSONObject]) -> JSONObject {
    ["enabled_tools": ["claude_code", "codex"], "claude_usage_enabled": percentages,
     "claude_usage": ["limits": limits, "error": NSNull(), "fetched_at": NOW],
     "sources": ["codex": ["files": ["f": ["size": 1, "mtime": 1, "daily": JSONObject(),
                                           "limits": ["at": "2026-11-08T11:00:00Z", "rate_limits": [
                                               "primary": ["used_percent": 1.0, "window_minutes": 300,
                                                           "resets_at": NOW + 600]]]]]]]]
}

@Test func emptyFetchWithPercentagesOffDropsKeys() {
    let state = claudeState(percentages: false, limits: [])
    let prefixes = Limits.unknownIDPrefixes(state, now: NOW)
    let (_, above) = Limits.alertsToSend([], thresholds: [75], windowsOn: bothWindows,
                                         above: ["claude_code:weekly@75"], unknownIDPrefixes: prefixes)
    #expect(above == [])
}

@Test func fetchedLevelVanishingDropsKeys() {
    // A successful fetch without the weekly limit (plan change): absence means gone.
    let fiveHour: JSONObject = ["kind": "five_hour", "window": "five_hour", "label": "5-hour",
                                "percent": 10.0, "resets_at": NOW + 600]
    let state = claudeState(percentages: true, limits: [fiveHour])
    let prefixes = Limits.unknownIDPrefixes(state, now: NOW)
    let levels = Limits.planLevels(state, toolKeys: ["claude_code"], now: NOW)
    let (_, above) = Limits.alertsToSend(levels, thresholds: [75], windowsOn: bothWindows,
                                         above: ["claude_code:weekly@75"], unknownIDPrefixes: prefixes)
    #expect(above == [])
}

@Test func dropBelowThenCrossSendsAgain() {
    var (messages, above) = Limits.alertsToSend([level(percent: 80.0)], thresholds: [75],
                                                windowsOn: ["five_hour"], above: [])
    #expect(messages.count == 1)
    (messages, above) = Limits.alertsToSend([level(percent: 60.0)], thresholds: [75],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages == [] && above == [])
    (messages, above) = Limits.alertsToSend([level(percent: 80.0)], thresholds: [75],
                                            windowsOn: ["five_hour"], above: above)
    #expect(messages.count == 1)
}

@Test func resetToZeroClearsKeys() {
    let (messages, above) = Limits.alertsToSend([level(percent: 0.0)], thresholds: [50, 75],
                                                windowsOn: ["five_hour"],
                                                above: ["codex:five_hour@50", "codex:five_hour@75"],
                                                unknownIDPrefixes: ["codex:"])
    #expect(messages == [] && above == [])  // present, so unknown does not apply
}

@Test func toolDisabledKeepsKeys() {
    let state: JSONObject = ["enabled_tools": ["claude_code"]]
    let prefixes = Limits.unknownIDPrefixes(state, now: NOW)
    let (messages, above) = Limits.alertsToSend([], thresholds: [75], windowsOn: bothWindows,
                                                above: ["codex:five_hour@75"], unknownIDPrefixes: prefixes)
    #expect(messages == [])
    #expect(above == ["codex:five_hour@75"])
}

@Test func switchOffThenOnSendsNothingWhenKeyPresent() {
    let keys = ["codex:five_hour@75"]
    var (messages, above) = Limits.alertsToSend([level()], thresholds: [75], windowsOn: [], above: keys)
    #expect(messages == [])
    #expect(above == keys)  // the id is present with its switch off: keep

    (messages, above) = Limits.alertsToSend([level()], thresholds: [75], windowsOn: ["five_hour"], above: above)
    #expect(messages == [])
    #expect(above == keys)
}

@Test func severalThresholdsGiveOneMessage() {
    let (messages, above) = Limits.alertsToSend([level(percent: 96.0)], thresholds: [75, 90, 95],
                                                windowsOn: ["five_hour"], above: [])
    #expect(messages.count == 1)
    #expect(above == ["codex:five_hour@75", "codex:five_hour@90", "codex:five_hour@95"])
}

@Test func unknownPrefixesFromState() {
    // Tool disabled.
    #expect(Limits.unknownIDPrefixes(["enabled_tools": ["claude_code"], "claude_usage_enabled": false],
                                     now: NOW).contains("codex:"))
    // Percentages on with an empty fetch: Claude Code's levels are unknown.
    let on = claudeState(percentages: true, limits: [])
    #expect(Limits.unknownIDPrefixes(on, now: NOW).contains("claude_code:"))
    // Percentages off: the fallback list is authoritative.
    let off = claudeState(percentages: false, limits: [])
    #expect(!Limits.unknownIDPrefixes(off, now: NOW).contains("claude_code:"))
    // No Codex record.
    var noCodex = on
    noCodex["sources"] = nil
    #expect(Limits.unknownIDPrefixes(noCodex, now: NOW).contains("codex:"))
    #expect(!Limits.unknownIDPrefixes(on, now: NOW).contains("codex:"))
}

@Test func displayNameAllTools() {
    func name(_ id: String, _ tool: String = "", _ kind: String? = nil, _ window: String,
              _ label: String = "Saved") -> String {
        Limits.displayName(Level(id: id, name: tool, kind: kind, window: window, label: label,
                                 percent: 1, resetsAt: nil))
    }
    #expect(name("claude_code:five_hour", "Claude Code", "five_hour", "five_hour") == "Claude Code (5-hour)")
    #expect(name("claude_code:weekly", "Claude Code", "weekly", "weekly") == "Claude Code (Weekly)")
    #expect(name("claude_code:weekly_opus", "Claude Code", "weekly_opus", "weekly") == "Claude Code (Weekly, Opus)")
    #expect(name("claude_code:weekly_sonnet", "Claude Code", "weekly_sonnet", "weekly") == "Claude Code (Weekly, Sonnet)")
    #expect(name("claude_code:foo", "Claude Code", "foo", "weekly") == "Claude Code (Weekly)")
    #expect(name("codex:monthly", "Codex", nil, "monthly") == "Codex (Monthly)")
    #expect(name("codex:weekly", "Codex", nil, "weekly") == "Codex (Weekly)")
    #expect(name("codex:weekly", "", nil, "weekly") == "Codex (Weekly)")
    #expect(name("mystery:weekly", "", nil, "weekly") == "mystery (Weekly)")
    #expect(name("codex:x", "Codex", nil, "odd", "Odd window") == "Codex (Odd window)")
}

@Test func savedLabelAndLevelIdUnchanged() {
    let levels = Limits.planLevels(["claude_usage_enabled": false,
                                    "claude_limit_hits": ["seven_day_opus": NOW + 60]], toolKeys: ["claude_code"],
                                   now: NOW)
    #expect(levels.map(\.id) == ["claude_code:weekly_opus"])
    #expect(levels.map(\.label) == ["Weekly"])
}

@Test func notificationTextMonthly() {
    let monthly = Level(id: "codex:monthly", name: "Codex", window: "monthly", label: "Monthly", percent: 80,
                        resetsAt: LocalTime.timestamp(2026, 11, 20, 18, 46))
    let (messages, _) = Limits.alertsToSend([monthly], thresholds: [75], windowsOn: ["monthly"], above: [], now: NOW)
    #expect(messages == ["Codex (Monthly) usage reached 75%. Resets on Nov 20."])
}

@Test func savedFableLimitAlertsUnderItsOwnName() {
    let fable: JSONObject = ["kind": "weekly_fable", "window": "weekly", "label": "Weekly · Fable",
                             "percent": 80.0, "resets_at": NSNull()]
    let state: JSONObject = ["claude_usage": claudeUsage(["limits": [fable]])]
    let levels = Limits.planLevels(state, toolKeys: ["claude_code"], now: NOW)
    #expect(levels.map(\.id) == ["claude_code:weekly_fable"])
    #expect(Limits.displayName(levels[0]) == "Claude Code (Weekly, Fable)")
    let (messages, _) = Limits.alertsToSend(levels, thresholds: [75], windowsOn: ["weekly"], above: [], now: NOW)
    #expect(messages == ["Claude Code (Weekly, Fable) usage reached 75%."])
}

@Test func displayNameCapitalizesEveryWordOfAModelKind() {
    let level = Level(id: "claude_code:weekly_fable_pro", name: "Claude Code", kind: "weekly_fable_pro",
                      window: "weekly", label: "Weekly", percent: 1, resetsAt: nil)
    #expect(Limits.displayName(level) == "Claude Code (Weekly, Fable Pro)")
}

@Test func aLimitInAnUnknownWindowShowsButNeverAlerts() {
    let daily: JSONObject = ["kind": "daily_fable", "window": "daily", "label": "Daily · Fable",
                             "percent": 99.0, "resets_at": NSNull()]
    let state: JSONObject = ["claude_usage": claudeUsage(["limits": [daily]])]
    let levels = Limits.planLevels(state, toolKeys: ["claude_code"], now: NOW)
    #expect(levels.map(\.id) == ["claude_code:daily_fable"])
    #expect(!Limits.limitWindows(state, toolKeys: ["claude_code"], now: NOW).contains("daily"))
    let (messages, _) = Limits.alertsToSend(levels, thresholds: [50], windowsOn: ["five_hour", "weekly", "monthly"],
                                            above: [], now: NOW)
    #expect(messages.isEmpty)
}

// MARK: Free resets

@Test func freeResetsAreUnavailableTodayWithAReasonAndNeverANumber() {
    let resets = FreeResets.current([:], now: 0)
    guard case .unavailable(let reason) = resets else { Issue.record("expected unavailable"); return }
    #expect(!reason.isEmpty)
    #expect(!reason.contains { $0.isNumber })
}

@Test func theFreeResetLineShowsUnavailableWithItsReason() {
    let card = PanelModel.freeResetsCard(.unavailable(reason: "No source."), now: 0)
    #expect(card.items == [.row(label: "Free resets remaining", value: "Unavailable"), .note("No source.")])
}

@Test func aRealCountWouldShowAsTheNumberWithItsRenewalDate() {
    let renews = LocalTime.timestamp(2026, 11, 20, 18, 46)
    let now = LocalTime.timestamp(2026, 11, 8, 12, 0)
    let card = PanelModel.freeResetsCard(.available(count: 2, renewsAt: renews), now: now)
    #expect(card.items == [.row(label: "Free resets remaining", value: "2"), .note("Renews Nov 20")])
    #expect(PanelModel.freeResetsCard(.available(count: 0, renewsAt: nil), now: now).items
            == [.row(label: "Free resets remaining", value: "0")])
}

@Test func theFreeResetLineIsOnTheLimitsTabOfClaudeCodeAndAllAIsOnly() {
    func titles(_ key: String, enabled: [String]) -> Bool {
        let state: JSONObject = ["enabled_tools": enabled, "grand_total": 0]
        let panel = PanelModel.buildPanel(Tools.toolView(state, key), state: state, sessions: [], friends: [],
                                          showLeaderboard: false, today: Day(2026, 11, 8))
        let limits = panel.first { $0.key == "limits" }!
        return limits.cards.contains { $0.items.contains(.row(label: "Free resets remaining", value: "Unavailable")) }
    }
    #expect(titles("claude_code", enabled: ["claude_code"]))
    #expect(titles("all", enabled: ["claude_code", "codex"]))
    #expect(!titles("codex", enabled: ["codex"]))
    #expect(!titles("all", enabled: ["codex"]))
}


@Test func aLateAlertStillNamesTheThresholdThatWasCrossed() {
    // Claude's percentages arrive every few minutes: by the time 50% is seen the limit may be at 54%.
    let (messages, _) = Limits.alertsToSend([level(percent: 54.0)], thresholds: [50], windowsOn: ["five_hour"], above: [])
    #expect(messages == ["Codex (5-hour) usage reached 50%."])
}

@Test func theAlertNamesTheHighestThresholdCrossedAtOnce() {
    let (messages, _) = Limits.alertsToSend([level(percent: 83.0)], thresholds: [50, 75, 90], windowsOn: ["five_hour"],
                                            above: [])
    #expect(messages == ["Codex (5-hour) usage reached 75%."])
}

@Test func aFullLimitSaysOneHundredWhateverTheThreshold() {
    var full = level(percent: 100.0)
    full.reached = true
    let (messages, _) = Limits.alertsToSend([full], thresholds: [75], windowsOn: ["five_hour"], above: [])
    #expect(messages == ["Codex (5-hour) usage reached 100%."])
}
