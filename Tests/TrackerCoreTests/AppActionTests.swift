// The app controller's action parsing (app.py's handle_action dispatch).
// app.py had no tests for this; these pin down that every action string the
// panel, Settings and the panel chrome send is understood.

import Foundation
import Testing
@testable import TrackerCore

@Test func chromeActions() {
    #expect(AppAction.parse("quit", .none) == .quit)
    #expect(AppAction.parse("open_settings", .none) == .openSettings)
    #expect(AppAction.parse("select_tool", .index(2)) == .selectTool(index: 2))
    #expect(AppAction.parse("select_tool", .none) == nil)
}

@Test func buttonsWithoutValues() {
    let cases: [(String, AppAction)] = [
        ("leaderboard_setup", .leaderboardSetup), ("leaderboard_share", .leaderboardShare),
        ("leaderboard_add", .leaderboardAdd), ("leaderboard_push", .leaderboardPush),
        ("leaderboard_pull", .leaderboardPull), ("alert_test", .alertTest),
        ("projects_expand", .projectsExpand), ("check_updates", .checkUpdates),
        ("open_repo", .openRepo), ("welcome_done", .welcomeDone),
    ]
    for (action, expected) in cases {
        #expect(AppAction.parse(action, .none) == expected, "\(action)")
    }
}

@Test func pickersReadTheirOptionLists() {
    #expect(AppAction.parse("title_mode", .index(1)) == .titleMode(PanelModel.titleModes[1].key))
    #expect(AppAction.parse("leaderboard_view", .index(1)) == .leaderboardView(PanelModel.leaderboardViews[1].key))
    #expect(AppAction.parse("menu_bar_font_size", .index(0)) == .menuBarFontSize(10))
    #expect(AppAction.parse("appearance", .index(2)) == .appearance(PanelSpeeds.appearances[2].key))
    #expect(AppAction.parse("panel_animation", .index(0)) == .panelAnimation("off"))
    #expect(AppAction.parse("scan_interval", .index(4)) == .scanInterval(seconds: 300))
    #expect(AppAction.parse("scan_interval", .index(1), scanIntervals: [7, 9]) == .scanInterval(seconds: 9))
}

@Test func pickOutsideTheOptionsIsIgnored() {
    #expect(AppAction.parse("title_mode", .index(99)) == nil)
    #expect(AppAction.parse("scan_interval", .index(-1)) == nil)
    #expect(AppAction.parse("menu_bar_font_size", .bool(true)) == nil)
    #expect(AppAction.parse("alert_thresholds", .indices([0, 99])) == nil)
}

@Test func alertThresholdsAreReadAsPercents() {
    #expect(AppAction.parse("alert_thresholds", .indices([0, 3])) == .alertThresholds([50, 75]))
    #expect(AppAction.parse("alert_thresholds", .indices([])) == .alertThresholds([]))
}

@Test func switchesCarryOnOff() {
    #expect(AppAction.parse("alerts_enabled", .bool(false)) == .alertsEnabled(false))
    #expect(AppAction.parse("claude_usage_enabled", .bool(true)) == .claudeUsageEnabled(true))
    #expect(AppAction.parse("login", .bool(false)) == .login(false))
    #expect(AppAction.parse("leaderboard_enabled", .bool(true)) == .leaderboardEnabled(true))
    #expect(AppAction.parse("tool:codex", .bool(true)) == .tool(key: "codex", on: true))
    #expect(AppAction.parse("welcome_tool:gemini_cli", .bool(false)) == .welcomeTool(key: "gemini_cli", on: false))
    #expect(AppAction.parse("alert_window:five_hour", .bool(true)) == .alertWindow(window: "five_hour", on: true))
}

@Test func providerActionsOnlyForKnownProviders() {
    #expect(AppAction.parse("provider:openai", .bool(true)) == .provider(key: "openai", on: true))
    #expect(AppAction.parse("provider:nobody", .bool(true)) == nil)
    #expect(AppAction.parse("provider_key:kimi", .none) == .providerKey("kimi"))
    #expect(AppAction.parse("provider_key_remove:deepseek", .none) == .providerKeyRemove("deepseek"))
    #expect(AppAction.parse("provider_key:nobody", .none) == nil)
}

@Test func unknownActionsAreIgnored() {
    #expect(AppAction.parse("", .none) == nil)
    #expect(AppAction.parse("something_new", .bool(true)) == nil)
}

@Test func onlyDialogActionsClosePanelFirst() {
    #expect(AppAction.leaderboardSetup.opensDialog)
    #expect(AppAction.providerKey("openai").opensDialog)
    #expect(AppAction.providerKeyRemove("openai").opensDialog)
    #expect(!AppAction.leaderboardPush.opensDialog)
    #expect(!AppAction.checkUpdates.opensDialog)
}

@Test func parsesToggleRow() {
    #expect(AppAction.parse("toggle_row:limit:claude_code:weekly", .none) == .toggleRow(id: "limit:claude_code:weekly"))
}

@Test func toggleRowIdWithColons() {
    #expect(AppAction.parse("toggle_row:proj:/a:b/c", .none) == .toggleRow(id: "proj:/a:b/c"))
    #expect(AppAction.parse("toggle_row:", .none) == nil)
}

@Test func roundTwoActions() {
    #expect(AppAction.parse("show_effort", .bool(true)) == .showEffort(true))
    #expect(AppAction.parse("show_effort", .bool(false)) == .showEffort(false))
    #expect(AppAction.parse("chart_days", .index(0)) == .chartDays(7))
    #expect(AppAction.parse("chart_days", .index(2)) == .chartDays(30))
    #expect(AppAction.parse("chart_days", .index(3)) == .chartAll)
    #expect(AppAction.parse("chart_days", .index(4)) == .chartCustom)
    #expect(AppAction.parse("chart_days", .index(5)) == nil)
    #expect(AppAction.parse("chart_from", .text("2026-07-01")) == .chartFrom(Day(2026, 7, 1)))
    #expect(AppAction.parse("chart_to", .text("2026-07-20")) == .chartTo(Day(2026, 7, 20)))
    #expect(AppAction.parse("chart_from", .text("tomorrow")) == nil)
    #expect(AppAction.parse("chart_to", .none) == nil)
    #expect(AppAction.parse("currency", .index(0)) == .currency("USD"))
    #expect(AppAction.parse("currency", .index(Pricing.currencies.count)) == nil)
    #expect(AppAction.parse("currency", .none) == nil)
}
