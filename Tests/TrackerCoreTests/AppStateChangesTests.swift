// app.py's state changes and decisions that don't need AppKit (Settings
// switches, which view is shown, what's due to be fetched, the leaderboard's
// bookkeeping). app.py had no tests for these.

import Foundation
import Testing
@testable import TrackerCore

private let NOW = LocalTime.timestamp(2026, 11, 8, 12)

// MARK: - AIs

@Test func toolSwitchesKeepToolOrder() {
    var state: JSONObject = ["enabled_tools": ["gemini_cli"]]

    AppState.setToolEnabled(&state, "claude_code", true)
    AppState.setToolEnabled(&state, "codex", true)
    #expect(jsonEqual(state["enabled_tools"], ["claude_code", "codex", "gemini_cli"]))

    AppState.setToolEnabled(&state, "codex", false)
    #expect(jsonEqual(state["enabled_tools"], ["claude_code", "gemini_cli"]))
}

@Test func providerSwitchesKeepProviderOrder() {
    var state: JSONObject = ["enabled_providers": ["kimi"]]

    AppState.setProviderEnabled(&state, "openai", true)
    #expect(jsonEqual(state["enabled_providers"], ["openai", "kimi"]))

    AppState.setProviderEnabled(&state, "kimi", false)
    #expect(jsonEqual(state["enabled_providers"], ["openai"]))
}

@Test func welcomeChoiceAddsAtTheEndAndRemoves() {
    #expect(AppState.welcomeChoice(["codex"], "claude_code", true) == ["codex", "claude_code"])
    #expect(AppState.welcomeChoice(["codex", "claude_code"], "codex", false) == ["claude_code"])
    #expect(AppState.welcomeChoice(["codex"], "codex", true) == ["codex"])
}

@Test func finishingWelcomeTracksChosenToolsInOrder() {
    var state: JSONObject = ["enabled_tools": [String](), "selected_tool": "claude_code", "onboarding_done": false]

    AppState.finishWelcome(&state, chosen: ["gemini_cli", "codex"])

    #expect(jsonEqual(state["enabled_tools"], ["codex", "gemini_cli"]))
    #expect(state.string("selected_tool") == "codex")
    #expect(state.bool("onboarding_done") == true)
}

@Test func finishingWelcomeWithNothingChosenKeepsTheSelection() {
    var state: JSONObject = ["enabled_tools": [String](), "selected_tool": "claude_code", "onboarding_done": false]

    AppState.finishWelcome(&state, chosen: [])

    #expect(jsonEqual(state["enabled_tools"], [String]()))
    #expect(state.string("selected_tool") == "claude_code")
    #expect(state.bool("onboarding_done") == true)
}

@Test func addingAKeyDropsNumbersFromTheOldKey() {
    var state: JSONObject = ["provider_keys": ["kimi"],
                             "accounts": ["openai": ["rows": [Any]()], "kimi": ["rows": [Any]()]]]

    AppState.addProviderKey(&state, "openai")

    #expect(jsonEqual(state["provider_keys"], ["openai", "kimi"]))
    #expect(jsonEqual(state["accounts"], ["kimi": ["rows": [Any]()]]))
}

@Test func removingAKeyForgetsItsNumbers() {
    var state: JSONObject = ["provider_keys": ["openai", "kimi"], "accounts": ["openai": ["rows": [Any]()]]]

    AppState.removeProviderKey(&state, "openai")

    #expect(jsonEqual(state["provider_keys"], ["kimi"]))
    #expect(jsonEqual(state["accounts"], JSONObject()))
}

// MARK: - Alerts

@Test func alertWindowSwitchesKeepWindowOrder() {
    var state: JSONObject = ["alert_windows": ["weekly"]]

    AppState.setAlertWindow(&state, "five_hour", true)
    #expect(jsonEqual(state["alert_windows"], ["five_hour", "weekly"]))

    AppState.setAlertWindow(&state, "weekly", false)
    #expect(jsonEqual(state["alert_windows"], ["five_hour"]))
}

@Test func atLeastOneThresholdStaysPicked() {
    var state: JSONObject = ["alert_thresholds": [75]]

    #expect(!AppState.setAlertThresholds(&state, []))
    #expect(jsonEqual(state["alert_thresholds"], [75]))

    #expect(AppState.setAlertThresholds(&state, [50, 90]))
    #expect(jsonEqual(state["alert_thresholds"], [50, 90]))
}

@Test func turningOffAnthropicPercentagesForgetsThem() {
    var state: JSONObject = ["claude_usage_enabled": true, "claude_usage": ["limits": [Any]()]]

    AppState.setClaudeUsageEnabled(&state, false)

    #expect(state.bool("claude_usage_enabled") == false)
    #expect(state["claude_usage"] == nil)
}

private func alertState(enabled: Bool = true) -> JSONObject {
    ["alerts_enabled": enabled, "enabled_tools": ["claude_code"], "claude_usage_enabled": false,
     "claude_limit_hits": ["five_hour": NOW + 3600], "alert_thresholds": [75],
     "alert_windows": ["five_hour", "weekly"], "alerts_above": [String]()]
}

@Test func reachedLimitAlertsOnceAndIsRemembered() {
    var state = alertState()

    let first = AppState.checkAlerts(&state, now: NOW)
    #expect(first.messages.count == 1)
    #expect(first.messages.first?.hasPrefix("Claude Code (5-hour) usage is at 100%.") == true)
    #expect(first.changed)
    #expect(jsonEqual(state["alerts_above"], ["claude_code:five_hour@75"]))

    let second = AppState.checkAlerts(&state, now: NOW)
    #expect(second.messages.isEmpty)
    #expect(!second.changed)
}

@Test func fetchErrorCarriesKeys() {
    var state = alertState()
    state["claude_usage_enabled"] = true
    state["claude_limit_hits"] = nil
    state["claude_usage"] = ["limits": [Any](), "error": "offline", "fetched_at": NOW]
    state["alerts_above"] = ["claude_code:five_hour@75", "claude_code:weekly@75"]

    let result = AppState.checkAlerts(&state, now: NOW)

    #expect(result.messages.isEmpty)
    #expect(!result.changed)
    #expect(jsonEqual(state["alerts_above"], ["claude_code:five_hour@75", "claude_code:weekly@75"]))
}

@Test func checkAlertsSeedingSendsNothingAndSavesKeys() {
    var state = alertState()

    let seeded = AppState.checkAlerts(&state, now: NOW, seeding: true)
    #expect(seeded.messages.isEmpty)
    #expect(seeded.changed)
    #expect(jsonEqual(state["alerts_above"], ["claude_code:five_hour@75"]))

    let later = AppState.checkAlerts(&state, now: NOW)
    #expect(later.messages.isEmpty && !later.changed)
}

@Test func noAlertsWhenTurnedOff() {
    var state = alertState(enabled: false)

    let result = AppState.checkAlerts(&state, now: NOW)

    #expect(result.messages.isEmpty && !result.changed)
    #expect(jsonEqual(state["alerts_above"], [String]()))
}

// MARK: - Which view

private func twoTools(selected: String) -> JSONObject {
    ["enabled_tools": ["claude_code", "codex"], "enabled_providers": [String](), "selected_tool": selected,
     "grand_total": 5, "daily": JSONObject()]
}

@Test func selectedToolIsShown() {
    let view = AppState.currentView(twoTools(selected: "claude_code"), detected: ["claude_code", "codex"])

    #expect(view.key == "claude_code")
    #expect(view.grandTotal == 5)
}

@Test func allAIsCombinesTools() {
    let view = AppState.currentView(twoTools(selected: "all"), detected: ["claude_code", "codex"])

    #expect(view.key == "all")
    #expect(view.views?.map(\.key) == ["claude_code", "codex"])
}

@Test func missingSelectionFallsBackToTheFirstToolNotAllAIs() {
    let view = AppState.currentView(twoTools(selected: "gemini_cli"), detected: ["claude_code", "codex"])

    #expect(view.key == "claude_code")
}

@Test func selectedProviderShowsItsView() {
    var state = twoTools(selected: "openai")
    state["enabled_providers"] = ["openai"]

    #expect(AppState.currentView(state, detected: ["claude_code", "codex"]).key == "openai")
}

@Test func nothingToShowIsTheCombinedView() {
    let state: JSONObject = ["enabled_tools": [String](), "selected_tool": "claude_code"]

    #expect(AppState.currentView(state, detected: []).key == "all")
}

@Test func sessionsAndPluginsFollowTheView() {
    let enabled = ["claude_code", "codex"]

    #expect(AppState.sessionTools("codex", enabled: enabled) == ["codex"])
    #expect(AppState.sessionTools("all", enabled: enabled) == enabled)
    #expect(AppState.sessionTools("openai", enabled: enabled) == [])
    #expect(AppState.showsPlugins("claude_code", enabled: enabled))
    #expect(AppState.showsPlugins("all", enabled: enabled))
    #expect(!AppState.showsPlugins("all", enabled: ["codex"]))
    #expect(!AppState.showsPlugins("codex", enabled: enabled))
}

@Test func menuBarCountFollowsTitleMode() {
    let today = Day(2026, 11, 8)
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: today, model: "claude-opus-4-5", project: "p", parts: ["input": 1500])
    let view = Tools.View(key: "claude_code", name: "Claude Code", daily: daily, grandTotal: 2_500_000, error: nil)

    #expect(AppState.menuBarCount(view, titleMode: "lifetime", today: today) == "2.5M")
    #expect(AppState.menuBarCount(view, titleMode: nil, today: today) == "2.5M")
    #expect(AppState.menuBarCount(view, titleMode: "today", today: today) == "1.5K")
    #expect(AppState.menuBarCount(view, titleMode: "icon", today: today) == nil)
}

// MARK: - Background fetches

@Test func accountsAreFetchedWhenDueOrForced() {
    let fresh = Accounts.isoSeconds(NOW - 60)
    let state: JSONObject = [
        "enabled_providers": ["openai", "deepseek", "kimi"], "provider_keys": ["openai", "deepseek", "kimi"],
        "accounts": ["openai": ["attempted_at": fresh], "deepseek": ["attempted_at": fresh]],
    ]

    #expect(AppState.accountsToFetch(state, inFlight: [], now: NOW) == ["kimi"])
    #expect(AppState.accountsToFetch(state, inFlight: [], force: "openai", now: NOW) == ["openai", "kimi"])
    #expect(AppState.accountsToFetch(state, inFlight: ["kimi"], now: NOW) == [])
}

@Test func accountsNeedAKeyAndTheProviderOn() {
    let state: JSONObject = ["enabled_providers": ["openai"], "provider_keys": ["kimi"]]

    #expect(AppState.accountsToFetch(state, inFlight: [], force: "kimi", now: NOW) == [])
}

@Test func failedAccountFetchIsShapedLikeAResult() {
    let result = AppState.failedAccountResult("the key is no longer in the Keychain", now: NOW)

    #expect(jsonEqual(result, [
        "daily": JSONObject(), "cost": JSONObject(), "rows": [Any](), "notes": [Any](),
        "error": "the key is no longer in the Keychain", "fetched_at": "2026-11-08T12:00:00",
    ] as JSONObject))
}

@Test func claudePercentagesAreFetchedEveryFiveMinutesWhileOn() {
    let on: JSONObject = ["claude_usage_enabled": true, "enabled_tools": ["claude_code"]]
    var recent = on
    recent["claude_usage"] = ["fetched_at": NOW - 60]
    var off = on
    off["claude_usage_enabled"] = false

    #expect(AppState.claudeUsageDue(on, inFlight: false, now: NOW))
    #expect(!AppState.claudeUsageDue(on, inFlight: true, now: NOW))
    #expect(!AppState.claudeUsageDue(recent, inFlight: false, now: NOW))
    #expect(AppState.claudeUsageDue(recent, inFlight: false, now: NOW + 300))
    #expect(!AppState.claudeUsageDue(off, inFlight: false, now: NOW))
    #expect(!AppState.claudeUsageDue(["claude_usage_enabled": true, "enabled_tools": ["codex"]],
                                     inFlight: false, now: NOW))
}

// MARK: - Leaderboard

@Test func leaderboardPayloadNamesAnonymousWithoutAName() {
    let today = Day(2026, 11, 8)

    #expect(jsonEqual(
        AppState.leaderboardPayload(["grand_total": 99, "leaderboard_name": NSNull()], yesterdayTokens: 7, today: today),
        ["name": "Anonymous", "total_tokens": 99, "yesterday_tokens": 7, "updated_at": "2026-11-08"] as JSONObject))
    #expect(AppState.leaderboardPayload(["grand_total": 1, "leaderboard_name": "Ray"], yesterdayTokens: 0,
                                        today: today).string("name") == "Ray")
}

@Test func addingAFriendTwiceDoesNothing() {
    let friends: [JSONObject] = [["gist_id": "a", "name": "A", "total_tokens": 5, "yesterday_tokens": 1]]

    #expect(AppState.addingFriend(friends, gistID: "a") == nil)
    let added = AppState.addingFriend(friends, gistID: "b")
    #expect(jsonEqual(added?.last, ["gist_id": "b", "name": "b", "total_tokens": 0, "yesterday_tokens": 0]))
    #expect(added?.count == 2)
}

private struct Offline: Error {}

@Test func pullingUpdatesReachableFriendsAndKeepsTheRest() {
    let friends: [JSONObject] = [
        ["gist_id": "a", "name": "A", "total_tokens": 5, "yesterday_tokens": 1],
        ["gist_id": "b", "name": "B", "total_tokens": 6, "yesterday_tokens": 2],
        ["gist_id": "c", "name": "C"],
    ]
    let gists: [String: Any] = ["a": ["name": "Alice", "total_tokens": 50, "yesterday_tokens": 10],
                                "c": ["total_tokens": 3]]

    let pulled = AppState.pulledFriends(friends) { id in
        guard let gist = gists[id] else { throw Offline() }
        return gist
    }

    #expect(jsonEqual(pulled, [
        ["gist_id": "a", "name": "Alice", "total_tokens": 50, "yesterday_tokens": 10],
        ["gist_id": "b", "name": "B", "total_tokens": 6, "yesterday_tokens": 2],
        ["gist_id": "c", "name": "C", "total_tokens": 3, "yesterday_tokens": 0],
    ]))
}

@Test func leaderboardSyncsOnceADayWhileOn() {
    let today = Day(2026, 11, 8)

    #expect(AppState.leaderboardSyncDue(["my_gist_id": "g", "last_leaderboard_sync_date": "2026-11-07"], today: today))
    #expect(!AppState.leaderboardSyncDue(["my_gist_id": "g", "last_leaderboard_sync_date": "2026-11-08"], today: today))
    #expect(!AppState.leaderboardSyncDue(["my_gist_id": NSNull()], today: today))
    #expect(!AppState.leaderboardSyncDue(["my_gist_id": "g", "leaderboard_enabled": false], today: today))
}

// MARK: - Chart range

@Test func pickingDaysAllOrCustomSetsTheChartMode() {
    var state: JSONObject = [:]
    let today = Day(2026, 7, 29)

    AppState.applyChart(.chartDays(30), to: &state, today: today)
    #expect(state["chart_mode"] as? String == "days" && state["chart_days"] as? Int == 30)

    AppState.applyChart(.chartAll, to: &state, today: today)
    #expect(state["chart_mode"] as? String == "all" && state["chart_days"] as? Int == 30)

    // Custom starts as the last 30 days, and keeps what was applied after that.
    AppState.applyChart(.chartCustom, to: &state, today: today)
    #expect(state["chart_mode"] as? String == "custom")
    #expect(state["chart_from"] as? String == "2026-06-30" && state["chart_to"] as? String == "2026-07-29")
    AppState.applyChart(.chartRange(Day(2026, 7, 1), Day(2026, 7, 10)), to: &state, today: today)
    AppState.applyChart(.chartAll, to: &state, today: today)
    AppState.applyChart(.chartCustom, to: &state, today: today)
    #expect(state["chart_from"] as? String == "2026-07-01" && state["chart_to"] as? String == "2026-07-10")
}

@Test func appliedDatesStayInOrderAndInsideTheDaysWithUsage() {
    let today = Day(2026, 7, 29), first = Day(2026, 7, 10)
    var state: JSONObject = ["chart_mode": "custom"]

    // Backwards dates swap; the end stops at today.
    AppState.applyChart(.chartRange(Day(2026, 7, 25), Day(2026, 7, 12)), to: &state, today: today)
    #expect(state["chart_from"] as? String == "2026-07-12" && state["chart_to"] as? String == "2026-07-25")
    AppState.applyChart(.chartRange(Day(2026, 7, 12), Day(2027, 1, 1)), to: &state, today: today)
    #expect(state["chart_to"] as? String == "2026-07-29")

    // Nothing before the first day with usage.
    AppState.applyChart(.chartRange(Day(2025, 10, 8), Day(2026, 7, 20)), to: &state, today: today, earliest: first)
    #expect(state["chart_from"] as? String == "2026-07-10" && state["chart_to"] as? String == "2026-07-20")
    AppState.applyChart(.chartRange(Day(2025, 10, 8), Day(2025, 11, 8)), to: &state, today: today, earliest: first)
    #expect(state["chart_from"] as? String == "2026-07-10" && state["chart_to"] as? String == "2026-07-10")
}

@Test func chartActionsLeaveOtherActionsAlone() {
    var state: JSONObject = ["a": 1]
    AppState.applyChart(.quit, to: &state, today: Day(2026, 7, 29))
    #expect(state.count == 1)
}

@Test func theLeaderboardTabShowsInEveryViewWhenTurnedOn() {
    let on: JSONObject = ["leaderboard_enabled": true]
    let off: JSONObject = ["leaderboard_enabled": false]
    let views = ["claude_code", "codex", "opencode", "gemini_cli", "all"] + Providers.providerNames.keys.sorted()
    #expect(views.count > 5)  // includes the company views
    for view in views {
        #expect(AppState.showsLeaderboard(view, state: on), "\(view) should show it")
        #expect(!AppState.showsLeaderboard(view, state: off), "\(view) should not show it")
    }
}
