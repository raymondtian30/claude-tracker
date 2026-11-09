// Ported from tests/test_app_state.py, test for test (app.py's pure helpers).

import Foundation
import Testing
@testable import TrackerCore

private let EXISTING: JSONObject = [
    "grand_total": 3_600_000_000,
    "file_offsets": ["/Users/me/.claude/projects/p/s.jsonl": 1234],
    "daily": ["2026-11-07": ["models": JSONObject(), "projects": JSONObject()]],
    "daily_backfilled": true,
    "first_seen_at": "2026-11-07",
    "title_mode": "today",
    "menu_bar_font_size": 11,
    "leaderboard_enabled": true,
    "leaderboard_view": "day",
    "panel_tab": "cost",
    "scan_interval_seconds": 60,
    "start_at_login": false,
]

@Test func existingInstallKeepsPreferences() {
    var state = EXISTING

    AppState.initToolState(&state, freshInstall: false)

    for (key, value) in EXISTING {
        #expect(jsonEqual(state[key], value), "\(key)")
    }
    #expect(jsonEqual(state["enabled_tools"], ["claude_code"]))
    #expect(state["combine_tools"] == nil)  // "All AIs" is picked in the panel now
    #expect(state.string("selected_tool") == "claude_code")
    #expect(state.bool("onboarding_done") == true)
}

@Test func freshInstallStartsWithNoTools() {
    var state = JSONObject()

    AppState.initToolState(&state, freshInstall: true)

    #expect(jsonEqual(state["enabled_tools"], [String]()))
    #expect(state.bool("onboarding_done") == false)
}

@Test func initIsIdempotentAndKeepsChoices() {
    var state: JSONObject = ["enabled_tools": ["codex"], "selected_tool": "codex", "onboarding_done": true]

    AppState.initToolState(&state, freshInstall: false)
    AppState.initToolState(&state, freshInstall: false)

    #expect(jsonEqual(state, ["enabled_tools": ["codex"], "selected_tool": "codex", "onboarding_done": true]))
}

@Test func combineSwitchThatWasOnBecomesAllAIsInTheDropdown() {
    var state: JSONObject = ["enabled_tools": ["claude_code", "codex"], "combine_tools": true,
                             "selected_tool": "codex", "onboarding_done": true]

    AppState.initToolState(&state, freshInstall: false)

    #expect(jsonEqual(state, ["enabled_tools": ["claude_code", "codex"], "selected_tool": "all",
                              "onboarding_done": true]))
}

@Test func combineSwitchThatWasOffChangesNothing() {
    var state: JSONObject = ["enabled_tools": ["claude_code"], "combine_tools": false,
                             "selected_tool": "claude_code", "onboarding_done": true]

    AppState.initToolState(&state, freshInstall: false)

    #expect(state.string("selected_tool") == "claude_code")
    #expect(state["combine_tools"] == nil)
}

@Test func menuBarLabelUsesToolIconOrCoin() {
    #expect(AppState.menuBarLabel("all", "3.8B", hasIcon: true) == ("🪙 3.8B", false))
    #expect(AppState.menuBarLabel("codex", "39.4M", hasIcon: true) == (" 39.4M", true))
    #expect(AppState.menuBarLabel("codex", "39.4M", hasIcon: false) == ("🪙 39.4M", false))
    #expect(AppState.menuBarLabel("codex", nil, hasIcon: true) == ("", true))  // icon-only mode
    #expect(AppState.menuBarLabel("all", nil, hasIcon: false) == ("🪙", false))
}

@Test func providerSettingsDefaultOffWithoutTouchingPreferences() {
    var state = EXISTING

    AppState.initProviderState(&state)

    for (key, value) in EXISTING {
        #expect(jsonEqual(state[key], value), "\(key)")
    }
    #expect(jsonEqual(state["enabled_providers"], [String]()))
    #expect(jsonEqual(state["provider_keys"], [String]()))
    state["enabled_providers"] = ["kimi"]
    AppState.initProviderState(&state)
    #expect(jsonEqual(state["enabled_providers"], ["kimi"]))
}
