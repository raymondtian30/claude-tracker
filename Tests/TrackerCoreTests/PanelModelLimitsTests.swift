// Ported from tests/test_stats_tabs.py, test for test: the limits, projects,
// Settings, Live tab and formatting tests (the rest are in
// PanelModelTests.swift, with the shared helpers).

import Foundation
import Testing
@testable import TrackerCore

private let limitsNow = LocalTime.timestamp(2026, 11, 8, 12, 0, 0)

private func limitsTab(_ state: JSONObject, _ view: Tools.View, now: Double = limitsNow) -> Tab {
    let tabs = PanelModel.buildPanel(view, state: state, sessions: [], friends: [], showLeaderboard: false,
                                     today: Day(2026, 11, 8), now: now)
    return tabs.first { $0.key == "limits" }!
}

/// Python builds this once and then edits the nested dicts in place (the
/// window length, the reset time); Swift's value types make that clumsy, so
/// here those values are parameters instead.
private func codexLimitsState(_ used: Double, windowMinutes: Int = 300,
                              resetsAt: Double = LocalTime.timestamp(2026, 11, 8, 15, 30)) -> JSONObject {
    let limits: JSONObject = ["at": "2026-11-08T11:00:00Z", "rate_limits": [
        "primary": ["used_percent": used, "window_minutes": windowMinutes, "resets_at": resetsAt] as JSONObject,
        "secondary": NSNull(),
    ] as JSONObject]
    return ["sources": ["codex": ["files": ["f": ["size": 1, "mtime": 1, "daily": JSONObject(),
                                                  "limits": limits] as JSONObject]]]]
}

private func projectsView(_ count: Int) -> Tools.View {
    var daily = JSONObject()
    for i in 0..<count {  // project 0 used the most
        UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "m", project: "/p/proj\(i)",
                            parts: ["input": 1000 - i])
    }
    return Tools.View(key: "opencode", name: "opencode", daily: daily, grandTotal: 1, error: nil)
}

private func projectsItems(_ count: Int, expanded: Bool = false) -> [Item] {
    let tabs = PanelModel.buildPanel(projectsView(count), state: [:], sessions: [], friends: [],
                                     showLeaderboard: false, today: Day(2026, 11, 8), projectsExpanded: expanded)
    let tab = tabs.first { $0.key == "projects" }!
    return tab.cards.first { $0.title != nil }!.items
}

private func barLabels(_ items: [Item]) -> [String] {
    items.compactMap { item -> String? in
        if case let .bar(label, _, _, _, _) = item { return label }
        return nil
    }
}

private func planItems(_ tab: Tab) -> [Item] {
    cardTitled(tab, "Plan limits")!.items
}

@Test func projectsShowsTheTop5ThenAShowMoreButton() {
    let items = projectsItems(8)

    #expect(barLabels(items) == (0..<5).map { "proj\($0)" })
    #expect(items.last == .buttons([Item.Button("Show 3 more", "chevron.down", "projects_expand")]))
}

@Test func projectsShowMoreListsEveryProject() {
    let items = projectsItems(8, expanded: true)

    #expect(barLabels(items) == (0..<8).map { "proj\($0)" })
    #expect(items.last == .buttons([Item.Button("Show less", "chevron.up", "projects_expand")]))
}

@Test func projectsWithoutMoreThan5HasNoButton() {
    let items = projectsItems(5)

    #expect(barLabels(items).count == 5)
    #expect(buttonsOf(items).isEmpty)
}

@Test func limitsTabSitsAfterCost() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8))

    let keys = tabs.map(\.key)
    #expect(keys.firstIndex(of: "limits") == keys.firstIndex(of: "cost")! + 1)
}

@Test func limitsTabShowsCodexPlanLimits() {
    let state = codexLimitsState(83.0)

    let tab = limitsTab(state, Tools.toolView(state, "codex"))

    #expect(planItems(tab) == [.bar(label: "Codex (5-hour)", value: "83%", fraction: 0.83, sub: "Resets 3:30 PM")])
}

@Test func limitsTabShowsAReachedClaudeLimit() {
    let state: JSONObject = ["claude_usage_enabled": false,
                             "claude_limit_hits": ["five_hour": LocalTime.timestamp(2026, 11, 8, 15, 30)]]

    let tab = limitsTab(state, Tools.toolView(state, "claude_code"))

    #expect(planItems(tab)[0] == .bar(label: "Claude Code (5-hour)", value: "Reached", fraction: 1.0, sub: "Resets 3:30 PM"))
}

@Test func limitsTabExplainsClaudeRecordsLimitsOnlyWhenReached() {
    let state: JSONObject = ["claude_usage_enabled": false]

    let tab = limitsTab(state, Tools.toolView(state, "claude_code"))

    let plan = planItems(tab)
    #expect(notesOf(plan).joined(separator: " ").contains("only records a limit once it's reached"))
    #expect(notesOf(plan).joined(separator: " ").contains("Turn on Percentages from Anthropic in Settings"))
    #expect(!plan.contains { $0.kind == "switch" })
}

private func claudeUsageState(limits: [JSONObject]? = nil, error: Any = NSNull()) -> JSONObject {
    let reset = LocalTime.timestamp(2026, 11, 8, 15, 30)
    let defaultLimits: [JSONObject] = [
        ["kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 23.0, "resets_at": reset],
        ["kind": "weekly", "window": "weekly", "label": "Weekly", "percent": 41.4, "resets_at": NSNull()],
    ]
    return ["claude_usage": ["limits": limits ?? defaultLimits, "error": error, "fetched_at": 1] as JSONObject]
}

@Test func limitsTabShowsClaudesPercentages() {
    let state = claudeUsageState()

    let tab = limitsTab(state, Tools.toolView(state, "claude_code"))

    let plan = planItems(tab)
    #expect(Array(plan.prefix(2)) == [.bar(label: "Claude Code (5-hour)", value: "23%", fraction: 0.23, sub: "Resets 3:30 PM"),
                                      .bar(label: "Claude Code (Weekly)", value: "41%", fraction: 0.414)])
}

@Test func limitsTabSaysWhenClaudesPercentagesAreUnavailable() {
    let state = claudeUsageState(limits: [], error: "Couldn't reach server. Percentage unavailable.")

    let tab = limitsTab(state, Tools.toolView(state, "claude_code"))

    let plan = planItems(tab)
    #expect(!plan.contains { $0.kind == "bar" })
    #expect(notesOf(plan).joined(separator: " ").contains("Couldn't reach server. Percentage unavailable."))
}

@Test func limitsTabNotificationsCardListsOnlyTheWindowsTheToolHas() {
    let claude = limitsTab([:], Tools.toolView([:], "claude_code"))
    let freeCodex = codexLimitsState(88.0, windowMinutes: 43200)
    let codex = limitsTab(freeCodex, Tools.toolView(freeCodex, "codex"))

    func windowSwitches(_ tab: Tab) -> [String] {
        cardTitled(tab, "Notifications")!.items.compactMap { item -> String? in
            if case let .switch(label, _, action) = item, action.hasPrefix("alert_window") { return label }
            return nil
        }
    }

    #expect(windowSwitches(claude) == ["5-hour limit", "Weekly limit"])
    #expect(windowSwitches(codex) == ["Monthly limit"])
}

@Test func limitsTabNotificationsCard() {
    let tab = limitsTab([:], Tools.toolView([:], "claude_code"))

    let items = cardTitled(tab, "Notifications")!.items
    #expect(items.contains(.switch(label: "Notify me", isOn: true, action: "alerts_enabled")))
    #expect(items.contains(.choices(label: "When usage reaches",
                                    options: ["50%", "60%", "70%", "75%", "80%", "90%", "95%"], selected: [3],
                                    action: "alert_thresholds")))
}

@Test func notificationsCardShowsEveryChosenThreshold() {
    let tab = limitsTab(["alert_thresholds": [75, 90]], Tools.toolView([:], "claude_code"))

    let items = cardTitled(tab, "Notifications")!.items
    let selected = items.compactMap { item -> [Int]? in
        if case let .choices(_, _, selected, _) = item { return selected }
        return nil
    }.first
    #expect(selected == [3, 5])
    #expect(items.contains(.buttons([Item.Button("Send Test Alert", "bell", "alert_test")])))
}

@Test func limitsTabHasNoNotificationsCardWithoutPlanLimits() {
    let view = Tools.View(key: "opencode", name: "opencode", daily: [:], grandTotal: 0, error: nil)

    let tab = limitsTab([:], view)

    #expect(tab.cards.compactMap(\.title) == ["Plan limits"])
}

@Test func settingsHasThePercentagesFromAnthropicSwitchWhenTrackingClaude() {
    func general(_ state: JSONObject) -> [Item] {
        let tab = PanelModel.settingsTab(state, intervalChoices: [15], detected: [])
        return cardTitled(tab, "General")!.items
    }

    let on = general(["enabled_tools": ["claude_code"]])
    let off = general(["enabled_tools": ["claude_code"], "claude_usage_enabled": false])

    #expect(on.contains(.switch(label: "Percentages from Anthropic", isOn: true, action: "claude_usage_enabled")))
    #expect(off.contains(.switch(label: "Percentages from Anthropic", isOn: false, action: "claude_usage_enabled")))
    #expect(!general(["enabled_tools": ["codex"]]).contains { actionOf($0) == "claude_usage_enabled" })
}

@Test func settingsHasNoUsageAlertsCard() {
    let tab = PanelModel.settingsTab([:], intervalChoices: [15], detected: [])

    #expect(!tab.cards.map(\.title).contains("Usage alerts"))
}

@Test func limitsTabGivesTheDateForAResetAfterToday() {
    let state = codexLimitsState(83.0, windowMinutes: 43200, resetsAt: LocalTime.timestamp(2026, 11, 20, 18, 46))

    let tab = limitsTab(state, Tools.toolView(state, "codex"))

    #expect(planItems(tab) == [.bar(label: "Codex (Monthly)", value: "83%", fraction: 0.83, sub: "Resets Nov 20")])
}

@Test func settingsHasLightDarkAutoAppearance() {
    func appearance(_ state: JSONObject) -> Item {
        let tab = PanelModel.settingsTab(state, intervalChoices: [15], detected: [])
        return cardTitled(tab, "Appearance")!.items[0]
    }

    #expect(appearance([:]) == .segmented(label: "Mode", options: ["Auto", "Light", "Dark"], selected: 0,
                                          action: "appearance"))
    #expect(selectedOf(appearance(["appearance": "dark"])) == 2)
    #expect(selectedOf(appearance(["appearance": "bogus"])) == 0)
}

@Test func liveTabShowsPluginTagsAndPluginActivity() {
    let sessions = [ActiveSessions.Session(label: "~/proj", tokens: 1500,
                                           plugins: [Plugins.Tag("superpowers", true), Plugins.Tag("caveman", false)])]
    let pluginRows = [
        Plugins.Row(label: "superpowers", sessions: 1, latest: Plugins.Activity(text: "Ran tdd skill", at: 1000.0),
                    today: ["skill": 2, "hook": 1]),
        Plugins.Row(label: "caveman", sessions: 0, latest: nil, today: [:]),
    ]

    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), sessions, plugins: pluginRows,
                                     now: 1000.0 + 125)

    expectWellFormed(tab)
    #expect(tab.cards.count == 2)
    let (sessionsCard, pluginsCard) = (tab.cards[0], tab.cards[1])
    #expect(sessionsCard.title == "Sessions (1)")
    #expect(sessionsCard.items == [
        .row(label: "~/proj", value: "1.5K"),
        .tags([Item.Tag("superpowers", true), Item.Tag("caveman", false)]),
    ])
    #expect(pluginsCard.title == "Plugins (2 enabled)")
    #expect(pluginsCard.items == [
        .row(label: "superpowers", value: "1 session"),
        .note("Ran tdd skill · 2 min ago"),
        .note("Today: 2 skills, 1 hook"),
        .row(label: "caveman", value: "0 sessions"),
        .note("Enabled, not used yet"),
    ])
}

@Test func liveTabWithoutPluginInfoHasOnlySessions() {
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "codex"), [ActiveSessions.Session(label: "~/g", tokens: nil)],
                                     plugins: nil, now: 0)

    #expect(tab.cards.map(\.title) == ["Sessions (1)"])
    #expect(tab.cards[0].items == [.row(label: "~/g", value: "running")])
}

@Test func liveTabWithNoPluginsSaysSo() {
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), [], plugins: [], now: 0)

    #expect(tab.cards[1] == Card(title: "Plugins (0 enabled)", items: [.note("No plugins enabled")]))
}

@Test func tagLinesWrapLongPluginLists() {
    let tags = (0..<6).map { Item.Tag("plugin-number-\($0)", true) }

    let lines = PanelModel.tagLines(tags)

    #expect(lines.count > 1)
    #expect(lines.flatMap { $0 } == tags)
    #expect(lines.allSatisfy { line in
        line.reduce(0) { $0 + $1.text.count + PanelModel.tagSpace } <= PanelModel.tagLineChars
    })
}

@Test func formatAgo() {
    #expect(PanelModel.formatAgo(100, 130) == "just now")
    #expect(PanelModel.formatAgo(0, 5 * 60) == "5 min ago")
    #expect(PanelModel.formatAgo(0, 3 * 3600) == "3 hr ago")
    #expect(PanelModel.formatAgo(0, 86400) == "1 day ago")
    #expect(PanelModel.formatAgo(0, 3 * 86400) == "3 days ago")
}

@Test func limitsTabUsesDisplayNameInAllViews() {
    let state = codexLimitsState(80.0, windowMinutes: 43200, resetsAt: LocalTime.timestamp(2026, 11, 20, 18, 46))
        .merging(["enabled_tools": ["codex"]]) { a, _ in a }

    for view in [Tools.toolView(state, "codex"), Tools.toolView(state, "all")] {
        let tab = limitsTab(state, view)
        #expect(planItems(tab) == [.bar(label: "Codex (Monthly)", value: "80%", fraction: 0.8,
                                        sub: "Resets Nov 20")])
    }
}

@Test func subTextAndNilCases() {
    for resets: Any in [NSNull(), 0.0] {
        let state: JSONObject = ["claude_usage": ["limits": [
            ["kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 23.0, "resets_at": resets] as JSONObject,
        ], "error": NSNull(), "fetched_at": 1] as JSONObject]
        let tab = limitsTab(state, Tools.toolView(state, "claude_code"))
        #expect(planItems(tab)[0] == .bar(label: "Claude Code (5-hour)", value: "23%", fraction: 0.23, sub: nil))
    }
    let reached: JSONObject = ["claude_usage_enabled": false,
                               "claude_limit_hits": ["five_hour": LocalTime.timestamp(2026, 11, 8, 15, 30)]]
    let tab = limitsTab(reached, Tools.toolView(reached, "claude_code"))
    guard case let .bar(_, value, _, sub, _) = planItems(tab)[0] else { Issue.record("no bar"); return }
    #expect(value == "Reached" && sub == "Resets 3:30 PM")
}

@Test func limitsTabShowsTheFableLimitUnderItsName() {
    let reset = LocalTime.timestamp(2026, 11, 8, 15, 30)
    let state = claudeUsageState(limits: [
        ["kind": "weekly_fable", "window": "weekly", "label": "Weekly · Fable", "percent": 0.0, "resets_at": reset],
    ])

    let tab = limitsTab(state, Tools.toolView(state, "claude_code"))

    #expect(planItems(tab)[0] == .bar(label: "Claude Code (Weekly, Fable)", value: "0%", fraction: 0.0,
                                      sub: "Resets 3:30 PM"))
}

@Test func limitsTabShowsALimitInAnUnknownWindowByItsLabel() {
    let state = claudeUsageState(limits: [
        ["kind": "daily_fable", "window": "daily", "label": "Daily · Fable", "percent": 50.0, "resets_at": NSNull()],
    ])

    let tab = limitsTab(state, Tools.toolView(state, "claude_code"))

    #expect(planItems(tab)[0] == .bar(label: "Claude Code (Daily · Fable)", value: "50%", fraction: 0.5))
}

// One row per folder: several Claude Code processes can run in the same one
// (each chat in VS Code, and the helpers it starts).

private func sessionRows(_ sessions: [ActiveSessions.Session]) -> [Item] {
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), sessions, plugins: nil, now: 0)
    return tab.cards[0].items
}

@Test func sessionsInOneFolderShareOneRow() {
    let sessions = [
        ActiveSessions.Session(label: "~/proj", tokens: 1500, cwd: "/Users/me/proj", log: "a",
                               plugins: [Plugins.Tag("superpowers", true), Plugins.Tag("caveman", false)]),
        ActiveSessions.Session(label: "~/proj", tokens: 500, cwd: "/Users/me/proj", log: "b",
                               plugins: [Plugins.Tag("caveman", true), Plugins.Tag("egm", false)]),
        ActiveSessions.Session(label: "~/proj", tokens: nil, cwd: "/Users/me/proj"),
        ActiveSessions.Session(label: "~/other", tokens: 100, cwd: "/Users/me/other"),
    ]

    let items = sessionRows(sessions)

    #expect(items.filter { if case .row = $0 { return true } else { return false } }
            == [.row(label: "proj · 3 sessions", value: "2.0K"), .row(label: "other", value: "100")])
    // The tags of the folder's sessions, once each; one that runs anywhere runs.
    var tags = [Item.Tag]()
    for item in items {
        if case let .tags(line) = item { tags += line }
    }
    #expect(tags.map { $0.text } == ["superpowers", "caveman", "egm"])
    #expect(tags.first { $0.text == "caveman" }?.isOn == true)
}

@Test func sessionRowsShowOnlyTheFolderName() {
    let rows = sessionRows([
        ActiveSessions.Session(label: "~/Desktop/claude-token-counter", tokens: 10, cwd: "/Users/me/Desktop/claude-token-counter"),
        ActiveSessions.Session(label: "~", tokens: nil),
        ActiveSessions.Session(label: "/opt/tool/", tokens: nil),
    ])

    #expect(rows == [.row(label: "claude-token-counter", value: "10"), .row(label: "~", value: "running"),
                     .row(label: "tool", value: "running")])
}

@Test func sessionFoldersWithOneNameShowTheirParent() {
    let rows = sessionRows([
        ActiveSessions.Session(label: "~/a/app", tokens: 2, cwd: "/Users/me/a/app"),
        ActiveSessions.Session(label: "~/b/app", tokens: 1, cwd: "/Users/me/b/app"),
    ])

    #expect(rows == [.row(label: "app · a", value: "2"), .row(label: "app · b", value: "1")])
}

@Test func theSessionCountStillCountsEveryProcess() {
    let sessions = (0..<5).map { _ in ActiveSessions.Session(label: "~/p", tokens: nil, cwd: "/p") }
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), sessions, plugins: nil, now: 0)

    #expect(tab.cards[0].title == "Sessions (5)")
    #expect(tab.cards[0].items == [.row(label: "~/p · 5 sessions", value: "running")])
}

@Test func aLoneSessionIsUnchanged() {
    let items = sessionRows([ActiveSessions.Session(label: "~/p", tokens: nil, cwd: "/p")])

    #expect(items == [.row(label: "~/p", value: "running")])
}

@Test func sessionsWithoutAFolderAreGroupedByLabel() {
    // Codex and opencode rows have a label only.
    let items = sessionRows([ActiveSessions.Session(label: "~/g", tokens: nil),
                             ActiveSessions.Session(label: "~/g", tokens: nil),
                             ActiveSessions.Session(label: "~/h", tokens: nil)])

    #expect(items == [.row(label: "~/g · 2 sessions", value: "running"), .row(label: "~/h", value: "running")])
}
