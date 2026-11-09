// app.py's start-up: the settings TokenCounterApp.__init__ adds to state.json,
// and where the app finds its files. app.py had no tests for these; they
// pin down the same keys and defaults.

import Foundation
import Testing
@testable import TrackerCore

private let TODAY = Day(2026, 11, 8)

@Test func freshInstallGetsEveryDefault() {
    var state = JSONObject()

    AppState.applyLaunchDefaults(&state, freshInstall: true, today: TODAY)

    #expect(jsonEqual(state, [
        "enabled_tools": [String](), "selected_tool": "claude_code", "onboarding_done": false,
        "enabled_providers": [String](), "provider_keys": [String](),
        "first_seen_at": "2026-11-08", "start_at_login": true, "scan_interval_seconds": 15,
        "leaderboard_view": "total", "my_gist_id": NSNull(), "leaderboard_name": NSNull(),
        "last_leaderboard_sync_date": NSNull(), "title_mode": "lifetime", "menu_bar_font_size": 12,
        "panel_animation": "normal", "appearance": "auto", "alerts_enabled": true,
        "alert_thresholds": [75], "alerts_above": [String](),
        "alert_windows": ["five_hour", "weekly", "monthly"], "claude_usage_enabled": true,
    ] as JSONObject))
}

@Test func existingSettingsAreKept() {
    let saved: JSONObject = [
        "grand_total": 42, "first_seen_at": "2025-01-02", "start_at_login": false,
        "scan_interval_seconds": 60, "leaderboard_view": "day", "my_gist_id": "abc",
        "title_mode": "icon", "menu_bar_font_size": 14, "panel_animation": "slow", "appearance": "dark",
        "alerts_enabled": false, "alert_thresholds": [50, 90], "alerts_above": ["x@50"],
        "alert_windows": ["weekly"], "claude_usage_enabled": false, "enabled_tools": ["codex"],
        "selected_tool": "codex", "onboarding_done": true,
    ]
    var state = saved

    AppState.applyLaunchDefaults(&state, freshInstall: false, today: TODAY)

    for (key, value) in saved {
        #expect(jsonEqual(state[key], value), "\(key)")
    }
}

@Test func oldKeysAreDroppedAndTheOldThresholdMigrated() {
    var state: JSONObject = [
        "budgets": ["daily": 5], "stats_tab": "cost", "panel_tab": "models", "first_seen_at": NSNull(),
        "alert_threshold": 90, "alerts_above": ["claude_code:five_hour"],
    ]

    AppState.applyLaunchDefaults(&state, freshInstall: false, today: TODAY)

    #expect(state["budgets"] == nil && state["stats_tab"] == nil && state["panel_tab"] == nil)
    #expect(state["alert_threshold"] == nil)
    #expect(jsonEqual(state["alert_thresholds"], [90]))
    #expect(jsonEqual(state["alerts_above"], ["claude_code:five_hour@90"]))
    #expect(state.string("first_seen_at") == "2026-11-08")  // null becomes the first launch
    #expect(jsonEqual(state["enabled_tools"], ["claude_code"]))  // an existing install
}

@Test func launchDefaultsAreIdempotent() {
    var once = JSONObject()
    AppState.applyLaunchDefaults(&once, freshInstall: true, today: TODAY)
    var twice = once

    AppState.applyLaunchDefaults(&twice, freshInstall: false, today: Day(2027, 1, 1))

    #expect(jsonEqual(once, twice))
}

@Test func projectFolderComesFromInfoPlistThenEnvironmentThenCurrentFolder() {
    let env = [AppState.projectDirEnvironment: "/tmp/from-env"]

    #expect(AppState.projectDirectory(infoValue: "/Users/me/claude-tracker", environment: env,
                                      currentDirectory: "/cwd").path == "/Users/me/claude-tracker")
    #expect(AppState.projectDirectory(infoValue: nil, environment: env, currentDirectory: "/cwd").path
                == "/tmp/from-env")
    #expect(AppState.projectDirectory(infoValue: "", environment: [:], currentDirectory: "/cwd").path == "/cwd")
}

@Test func filesLiveInTheProjectFolder() {
    let files = AppState.Files(projectDir: URL(fileURLWithPath: "/p", isDirectory: true))

    #expect(files.state.path == "/p/state.json")
    #expect(files.friends.path == "/p/friends.json")
    #expect(files.lock.path == "/p/.claude-tracker.lock")
}

@Test func bundlePathIsTheRunningAppElseTheInstallFolder() {
    let dest = URL(fileURLWithPath: "/Applications")

    #expect(AppState.bundlePath(running: URL(fileURLWithPath: "/X/Claude Tracker.app"), defaultDest: dest).path
                == "/X/Claude Tracker.app")
    #expect(AppState.bundlePath(running: URL(fileURLWithPath: "/repo/.build/debug"), defaultDest: dest).path
                == "/Applications/Claude Tracker.app")
}

@Test func defaultDestIsApplicationsWhenWritable() {
    #expect(AppState.defaultDest(applicationsWritable: true, home: "/Users/me").path == "/Applications")
    #expect(AppState.defaultDest(applicationsWritable: false, home: "/Users/me").path == "/Users/me/Applications")
}

@Test func spawnDetachedRunsInItsOwnSession() throws {
    let pid = try Subprocess.spawnDetached(["/bin/sleep", "5"])
    defer {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    #expect(getsid(pid) == pid)  // it leads a new session
    #expect(getsid(0) != pid)
}
