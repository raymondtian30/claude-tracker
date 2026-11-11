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

private func dotRow(_ label: String, _ value: String, _ dot: LabelExtras.Dot) -> Item {
    .row(label: label, value: value, extras: LabelExtras(dot: dot))
}

@Test func liveTabShowsPluginTagsAndPluginActivity() {
    let sessions = [ActiveSessions.Session(label: "~/proj", tokens: 1500,
                                           plugins: [Plugins.Tag("superpowers", true), Plugins.Tag("caveman", false)],
                                           pid: 1, status: "busy")]
    let pluginRows = [
        Plugins.Row(label: "superpowers", sessions: 1, latest: Plugins.Activity(text: "Ran tdd skill", at: 1000.0),
                    today: ["skill": 2, "hook": 1]),
        Plugins.Row(label: "caveman", sessions: 0, latest: nil, today: [:]),
    ]

    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), sessions, plugins: pluginRows,
                                     now: 1000.0 + 125)

    expectWellFormed(tab)
    #expect(tab.cards.count == 3)
    let (sessionsCard, processCard, pluginsCard) = (tab.cards[0], tab.cards[1], tab.cards[2])
    #expect(sessionsCard.title == "Sessions (1)")
    #expect(processCard.items == [
        dotRow("proj", "Active", .green),
        .note("busy now"),
        .note("process 1 · 1.5K tokens"),
        .tags([Item.Tag("superpowers", true), Item.Tag("caveman", false)]),
        .buttons([Item.Button("Stop", "pause.circle", "session_stop:1"),
                  Item.Button("Quit", "xmark.circle", "session_quit:1")]),
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
    #expect(tab.cards[0].items == [.note("1 unknown"), dotRow("g", "Unknown", .hollow)])
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

// One row per session: never grouped by folder, since several can run in one
// (each chat in VS Code, two terminals), and never merged across tools.

private func sessionRows(_ sessions: [ActiveSessions.Session], view: String = "claude_code") -> [Item] {
    let tab = PanelModel.sessionsTab(Tools.toolView([:], view), sessions, plugins: nil, now: 0)
    return tab.cards[0].items
}

private func statusRows(_ items: [Item]) -> [Item] {
    items.filter { if case .row = $0 { return true } else { return false } }
}

@Test func sessionsInOneFolderAreOneRowEachNeverGrouped() {
    let sessions = [
        ActiveSessions.Session(label: "~/proj", tokens: nil, cwd: "/Users/me/proj", tool: "codex"),
        ActiveSessions.Session(label: "~/proj", tokens: nil, cwd: "/Users/me/proj", tool: "codex"),
        ActiveSessions.Session(label: "~/proj", tokens: nil, cwd: "/Users/me/proj", tool: "codex"),
        ActiveSessions.Session(label: "~/other", tokens: nil, cwd: "/Users/me/other", tool: "codex"),
    ]

    let rows = statusRows(sessionRows(sessions, view: "codex"))

    #expect(rows == [dotRow("proj", "Unknown", .hollow), dotRow("proj", "Unknown", .hollow),
                     dotRow("proj", "Unknown", .hollow), dotRow("other", "Unknown", .hollow)])
}

@Test func sessionsOfDifferentToolsInOneFolderStayApartAndNameTheirTool() {
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "all"), [
        ActiveSessions.Session(label: "~/app", tokens: nil, tool: "codex"),
        ActiveSessions.Session(label: "~/app", tokens: nil, tool: "opencode"),
    ], plugins: nil, now: 0)

    #expect(tab.cards[0].title == "Sessions (2)")
    #expect(statusRows(tab.cards[0].items) == [dotRow("Codex · app", "Unknown", .hollow),
                                               dotRow("opencode · app", "Unknown", .hollow)])
}

@Test func sessionRowsShowOnlyTheFolderName() {
    let rows = statusRows(sessionRows([
        ActiveSessions.Session(label: "~/Desktop/claude-token-counter", tokens: nil, tool: "codex"),
        ActiveSessions.Session(label: "~", tokens: nil, tool: "codex"),
        ActiveSessions.Session(label: "/opt/tool/", tokens: nil, tool: "codex"),
    ], view: "codex"))

    #expect(rows == [dotRow("claude-token-counter", "Unknown", .hollow), dotRow("~", "Unknown", .hollow),
                     dotRow("tool", "Unknown", .hollow)])
}

@Test func sessionFoldersWithOneNameShowTheirParent() {
    let rows = statusRows(sessionRows([
        ActiveSessions.Session(label: "~/a/app", tokens: nil, tool: "codex"),
        ActiveSessions.Session(label: "~/b/app", tokens: nil, tool: "codex"),
    ], view: "codex"))

    #expect(rows == [dotRow("app · a", "Unknown", .hollow), dotRow("app · b", "Unknown", .hollow)])
}

@Test func theSessionCountIsOneRowPerSession() {
    let sessions = (0..<5).map { _ in ActiveSessions.Session(label: "~/p", tokens: nil, tool: "codex") }
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "codex"), sessions, plugins: nil, now: 0)

    #expect(tab.cards[0].title == "Sessions (5)")
    #expect(statusRows(tab.cards[0].items).count == 5)
}

@Test func nothingScannedYetSaysLookingNotZero() {
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), [], plugins: nil, now: 0, scanned: false)

    #expect(tab.cards == [Card(title: "Sessions", items: [.note("Looking for sessions…")])])
}

@Test func afterAScanWithNothingRunningItIsAConfidentZero() {
    let all = PanelModel.sessionsTab(Tools.toolView([:], "all"), [], plugins: nil, now: 0)
    let codex = PanelModel.sessionsTab(Tools.toolView([:], "codex"), [], plugins: nil, now: 0)

    #expect(all.cards[0] == Card(title: "Sessions (0)", items: [.note("No sessions running")]))
    #expect(codex.cards[0] == Card(title: "Sessions (0)", items: [.note("No Codex sessions running")]))
}

@Test func aFailedScanBeforeAnythingWasKnownShowsTheReason() {
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "all"), [], plugins: nil, now: 0, scanned: false,
                                     error: "Couldn't list sessions: ps exited with 1")

    #expect(tab.cards[0].items == [.note("Couldn't list sessions: ps exited with 1")])
}

@Test func theSummaryLineCountsEachStateAndPausedApart() {
    func session(_ state: SessionRules.State, stopped: Bool = false) -> ActiveSessions.Session {
        ActiveSessions.Session(label: "~/p", tokens: nil, stopped: stopped, tool: "codex", state: state)
    }
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "codex"), [
        session(.active), session(.active), session(.waiting), session(.idle), session(.unknown),
        session(.active, stopped: true),
    ], plugins: nil, now: 0)

    #expect(tab.cards[0].items.first == .note("3 active · 1 waiting · 1 idle · 1 unknown · 1 paused"))
}

@Test func eachStateHasItsWordAndDot() {
    func word(_ state: SessionRules.State?, stopped: Bool = false) -> Item {
        let tab = PanelModel.sessionsTab(Tools.toolView([:], "codex"), [
            ActiveSessions.Session(label: "~/p", tokens: nil, stopped: stopped, tool: "codex", state: state),
        ], plugins: nil, now: 0)
        return statusRows(tab.cards[0].items)[0]
    }
    #expect(word(.active) == dotRow("p", "Active", .green))
    #expect(word(.waiting) == dotRow("p", "Waiting", .yellow))
    #expect(word(.idle) == dotRow("p", "Idle", .grey))
    #expect(word(.unknown) == dotRow("p", "Unknown", .hollow))
    #expect(word(nil) == dotRow("p", "Unknown", .hollow))
    #expect(word(.active, stopped: true) == dotRow("p", "Paused", .grey))
}

@Test func theFootnoteSaysHowManyProcessesWereLeftOut() {
    func notes(_ count: Int) -> String {
        let tab = PanelModel.sessionsTab(Tools.toolView([:], "codex"), [], plugins: nil, now: 0, notCounted: count)
        return tab.cards[0].items.compactMap { item -> String? in
            if case .note(let text) = item { return text }
            return nil
        }.joined(separator: " ")
    }

    #expect(!notes(0).contains("not counted"))
    #expect(notes(1).hasSuffix("1 process not counted (a server, a helper or one with no terminal)"))
    #expect(notes(3).hasSuffix("3 processes not counted (servers, helpers or ones with no terminal)"))
    // Wrapped to the card: no single line is wider than a note may be.
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "codex"), [], plugins: nil, now: 0, notCounted: 3)
    for case .note(let line) in tab.cards[0].items { #expect(line.count <= PanelModel.noteWidth) }
}

@Test func backgroundAgentsAreListedInTheirOwnCardAndNotCounted() {
    let agent = ActiveSessions.Session(label: "~/a/app", tokens: nil, pid: 9, tool: "claude_code", state: .idle)
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), [], plugins: nil, now: 0, background: [agent])

    #expect(tab.cards[0].title == "Sessions (0)")
    #expect(tab.cards[1] == Card(title: "Background (1)", items: [.note("Not counted in Sessions"),
                                                                  dotRow("app", "Idle", .grey)]))
}

@Test func runningSubagentsAreListedUnderTheirSessionAndCapped() {
    let subagents = (1...7).map { Subagent(id: "agent-\($0)", type: "Explore", description: "job \($0)", depth: $0 == 2 ? 2 : 1) }
    let tab = claudeTab([ActiveSessions.Session(label: "~/p", tokens: nil, pid: 4, status: "busy", subagents: subagents)])

    let notes = tab.cards[1].items.compactMap { item -> String? in
        if case .note(let text) = item, text.contains("↳") { return text }
        return nil
    }
    #expect(notes == ["↳ Explore: job 1", "  ↳ Explore: job 2", "↳ Explore: job 3", "↳ Explore: job 4",
                      "↳ Explore: job 5", "↳ …and 2 more"])
}

@Test func theTitleCountEqualsTheStatusRowsAndBulkTargetsAreAmongThem() {
    // Two Claude processes (cards), one Codex row; one background agent that is not counted.
    let sessions = [
        ActiveSessions.Session(label: "~/a", tokens: 1, cwd: "/a", pid: 2, status: "busy", tool: "claude_code"),
        ActiveSessions.Session(label: "~/b", tokens: 1, cwd: "/b", pid: 3, status: "idle", tool: "claude_code"),
        ActiveSessions.Session(label: "~/c", tokens: nil, pid: 4, tool: "codex"),
    ]
    let agent = ActiveSessions.Session(label: "~/d", tokens: nil, pid: 5, tool: "claude_code", state: .idle)
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "all"), sessions, plugins: nil, now: 0, background: [agent])

    let counted = tab.cards.dropFirst().prefix(2).count + statusRows(tab.cards[0].items).count
    #expect(tab.cards[0].title == "Sessions (\(counted))")
    let actions = tab.cards.flatMap(\.items).flatMap { item -> [String] in
        if case .buttons(let buttons) = item { return buttons.map(\.action) } else { return [] }
    }
    #expect(actions.contains("session_stop:2") && actions.contains("session_stop:3"))
    #expect(!actions.contains { $0.hasSuffix(":4") || $0.hasSuffix(":5") })  // Codex and the agent have no buttons
}

// MARK: - Stop and Quit for each Claude process

private func claudeTab(_ sessions: [ActiveSessions.Session], now: Double = 1_000_000) -> Tab {
    PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), sessions, plugins: nil, now: now)
}

private func button(_ title: String, _ icon: String, _ action: String) -> Item.Button {
    Item.Button(title, icon, action)
}

@Test func eachClaudeProcessGetsItsOwnCardWithStopAndQuit() {
    let now = 1_000_000.0
    let tab = claudeTab([
        ActiveSessions.Session(label: "~/a/app", tokens: 1500, cwd: "/Users/me/a/app", log: "x",
                               plugins: [Plugins.Tag("caveman", true)], pid: 42, status: "busy", since: now - 5,
                               title: "Active plugins", kind: "VS Code"),
        ActiveSessions.Session(label: "~/a/app", tokens: 500, cwd: "/Users/me/a/app", log: "y", pid: 43,
                               status: "idle", since: now - 7200, kind: "Terminal"),
    ], now: now)

    expectWellFormed(tab)
    #expect(tab.cards.count == 3)
    #expect(tab.cards[0].title == "Sessions (2)")
    // The first row is the status row: the chat's title (or the folder) with its dot and state. Under it:
    // kind and state, the folder (when a title is shown), process number and tokens, plugins, buttons.
    #expect(tab.cards[1].title == nil)
    #expect(tab.cards[1].items == [
        dotRow("Active plugins", "Active", .green),
        .note("VS Code · busy now"),
        .note("app · process 42 · 1.5K tokens"),
        .tags([Item.Tag("caveman", true)]),
        .buttons([button("Stop", "pause.circle", "session_stop:42"), button("Quit", "xmark.circle", "session_quit:42")]),
    ])
    #expect(tab.cards[2].items == [
        dotRow("app", "Idle", .grey),
        .note("Terminal · idle for 2 hr"),
        .note("process 43 · 500 tokens"),
        .buttons([button("Stop", "pause.circle", "session_stop:43"), button("Quit", "xmark.circle", "session_quit:43")]),
    ])
}

@Test func aWaitingSessionSaysWhatItWaitsFor() {
    let tab = claudeTab([
        ActiveSessions.Session(label: "~/a", tokens: nil, cwd: "/a", log: "x", pid: 6, status: "waiting",
                               tool: "claude_code", state: .waiting, waitingFor: "input needed"),
    ])

    #expect(tab.cards[1].items.prefix(2) == [dotRow("a", "Waiting", .yellow), .note("waiting: input needed")])
}

@Test func aPausedProcessSaysSoLoudlyAndOffersResume() {
    let tab = claudeTab([
        ActiveSessions.Session(label: "~/a", tokens: 7, cwd: "/a", log: "z", pid: 5, stopped: true, status: "busy",
                               title: "Chart fix", kind: "VS Code"),
    ])

    #expect(tab.cards[1].items == [
        dotRow("Chart fix", "Paused", .grey),
        .alert(text: "Paused · click Resume to continue", showIcon: true),
        .note("a · process 5 · 7 tokens"),
        .buttons([button("Resume", "play.circle", "session_resume:5"), button("Quit", "xmark.circle", "session_quit:5")]),
    ])
}

@Test func theSummaryCardHasStopAllQuitAllAndResumeAllWhenSomethingIsPaused() {
    let running = ActiveSessions.Session(label: "~/p", tokens: nil, cwd: "/p", log: "x", pid: 7)
    let paused = ActiveSessions.Session(label: "~/q", tokens: nil, cwd: "/q", log: "y", pid: 8, stopped: true)

    #expect(claudeTab([running]).cards[0].items == [
        .note("1 unknown"),
        .buttons([button("Stop all", "pause.circle", "sessions_stop_all"),
                  button("Quit all", "xmark.circle", "sessions_quit_all")]),
    ])
    #expect(claudeTab([running, paused]).cards[0].items == [
        .note("2 unknown · 1 paused"),
        .buttons([button("Stop all", "pause.circle", "sessions_stop_all"),
                  button("Quit all", "xmark.circle", "sessions_quit_all")]),
        .buttons([button("Resume all", "play.circle", "sessions_resume_all")]),
    ])
}

@Test func foldersWithOneNameShowTheirParentOnProcessCards() {
    let tab = claudeTab([
        ActiveSessions.Session(label: "~/a/app", tokens: 2, cwd: "/Users/me/a/app", log: "x", pid: 2),
        ActiveSessions.Session(label: "~/b/app", tokens: 1, cwd: "/Users/me/b/app", log: "y", pid: 3),
    ])

    #expect(tab.cards[1].items.first == dotRow("app · a", "Unknown", .hollow))
    #expect(tab.cards[2].items.first == dotRow("app · b", "Unknown", .hollow))
}

@Test func otherToolsSessionsAreRowsInTheSummaryCardWithNoButtons() {
    let tab = claudeTab([
        ActiveSessions.Session(label: "~/a", tokens: 5, cwd: "/Users/me/a", log: "x", pid: 9),
        ActiveSessions.Session(label: "~/g", tokens: nil, pid: 90, tool: "codex"),
        ActiveSessions.Session(label: "~/g", tokens: nil, tool: "opencode"),
    ])

    #expect(tab.cards[0].title == "Sessions (3)")
    #expect(tab.cards[0].items == [
        .note("3 unknown"),
        .buttons([button("Stop all", "pause.circle", "sessions_stop_all"), button("Quit all", "xmark.circle", "sessions_quit_all")]),
        dotRow("g", "Unknown", .hollow),
        dotRow("g", "Unknown", .hollow),
    ])
    #expect(tab.cards.count == 2)  // and one card for the one controllable process
}

@Test func aProcessWithNoLogSaysItHasNoMessages() {
    let tab = claudeTab([
        ActiveSessions.Session(label: "~/c", tokens: nil, cwd: "/c", pid: 4, status: "idle", since: 999_970),
    ])

    #expect(tab.cards[1].items.prefix(3) == [dotRow("c", "Idle", .grey), .note("idle, no messages yet"),
                                             .note("process 4")])
}

@Test func eachProcessSaysWhetherItIsBusyOrIdle() {
    let now = 1_000_000.0
    let tab = claudeTab([
        ActiveSessions.Session(label: "~/a", tokens: 9, cwd: "/a", log: "x", pid: 2, status: "busy", since: now - 5),
        ActiveSessions.Session(label: "~/b", tokens: 8, cwd: "/b", log: "y", pid: 3, status: "idle", since: now - 7200),
        ActiveSessions.Session(label: "~/c", tokens: 7, cwd: "/c", log: "z", pid: 4, status: "idle", since: now - 30),
        ActiveSessions.Session(label: "~/d", tokens: 6, cwd: "/d", log: "w", pid: 5),
        ActiveSessions.Session(label: "~/e", tokens: 5, cwd: "/e", log: "v", pid: 6, status: "idle", since: now - 200_000),
    ], now: now)

    let states = (1...5).map { tab.cards[$0].items[1] }
    #expect(states == [.note("busy now"), .note("idle for 2 hr"), .note("idle for under a minute"),
                       .note("running"), .note("idle for 2 days")])
}

// MARK: - A hit plan limit pauses what would read as running

private let fiveHourHit: JSONObject = ["claude_usage_enabled": false,
                                       "claude_limit_hits": ["five_hour": LocalTime.timestamp(2026, 11, 8, 15, 30)]]

@Test func aHitFiveHourLimitIsFoundUntilItResets() {
    let level = Limits.hitClaudeLimit(fiveHourHit, now: limitsNow)
    #expect(level?.label == "5-hour")
    #expect(level?.resetsAt == LocalTime.timestamp(2026, 11, 8, 15, 30))
    #expect(Limits.hitClaudeLimit(fiveHourHit, now: LocalTime.timestamp(2026, 11, 8, 15, 31)) == nil)
    #expect(Limits.hitClaudeLimit(["claude_usage_enabled": false], now: limitsNow) == nil)
}

@Test func aFullPercentageFromAnthropicCountsAsHitAndAnythingLessDoesNot() {
    let full = claudeUsageState(limits: [
        ["kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 100.0,
         "resets_at": LocalTime.timestamp(2026, 11, 8, 15, 30)],
    ])
    #expect(Limits.hitClaudeLimit(full, now: limitsNow)?.window == "five_hour")
    #expect(Limits.hitClaudeLimit(claudeUsageState(), now: limitsNow) == nil)  // 23%
}

@Test func runningClaudeSessionsReadPausedLimitHitInsteadOfRunning() {
    let level = Limits.hitClaudeLimit(fiveHourHit, now: limitsNow)
    let sessions = [
        ActiveSessions.Session(label: "~/a", tokens: nil, cwd: "/a", log: "x", pid: 2, status: "busy", kind: "VS Code",
                               tool: "claude_code", state: .active),
        ActiveSessions.Session(label: "~/b", tokens: nil, cwd: "/b", log: "y", pid: 3, tool: "claude_code",
                               state: .unknown),
        ActiveSessions.Session(label: "~/c", tokens: nil, cwd: "/c", log: "z", pid: 4, status: "idle", tool: "claude_code",
                               state: .idle),
    ]
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), sessions, plugins: nil, now: limitsNow,
                                     limit: level)

    #expect(tab.cards[0].items.first == .note("1 idle · 2 limit hit"))
    #expect(tab.cards[1].items.prefix(2) == [dotRow("a", "Limit hit", .yellow),
                                             .note("VS Code · paused: 5-hour limit hit, resets 3:30 PM")])
    #expect(tab.cards[2].items.first == dotRow("b", "Limit hit", .yellow))
    #expect(tab.cards[3].items.first == dotRow("c", "Idle", .grey))  // not running: the limit changes nothing
}

@Test func aLimitDoesNotTouchOtherToolsOrPausedOrWaitingSessions() {
    let level = Limits.hitClaudeLimit(fiveHourHit, now: limitsNow)
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "all"), [
        ActiveSessions.Session(label: "~/a", tokens: nil, tool: "codex", state: .unknown),
        ActiveSessions.Session(label: "~/b", tokens: nil, pid: 5, stopped: true, tool: "claude_code", state: .active),
        ActiveSessions.Session(label: "~/c", tokens: nil, pid: 6, tool: "claude_code", state: .waiting),
    ], plugins: nil, now: limitsNow, limit: level)

    let words = tab.cards.flatMap(\.items).compactMap { item -> String? in
        if case .row(_, let value, _) = item { return value }
        return nil
    }
    #expect(words == ["Unknown", "Paused", "Waiting"])
}

@Test func withoutALimitNothingChanges() {
    let session = ActiveSessions.Session(label: "~/a", tokens: nil, pid: 2, status: "busy", tool: "claude_code",
                                         state: .active)
    let tab = PanelModel.sessionsTab(Tools.toolView([:], "claude_code"), [session], plugins: nil, now: limitsNow)
    #expect(tab.cards[1].items.first == dotRow("a", "Active", .green))
}

@Test func theLiveTabOfAWholePanelShowsTheLimitFromState() {
    let session = ActiveSessions.Session(label: "~/a", tokens: nil, pid: 2, status: "busy", tool: "claude_code",
                                         state: .active)
    let live = LiveSnapshot(scanned: true, sessions: [session])
    let panel = PanelModel.buildPanel(Tools.toolView(fiveHourHit, "claude_code"), state: fiveHourHit, sessions: [],
                                      friends: [], showLeaderboard: false, today: Day(2026, 11, 8), now: limitsNow,
                                      live: live)
    let tab = panel.first { $0.key == "sessions" }!
    #expect(tab.cards.flatMap(\.items).contains(dotRow("a", "Limit hit", .yellow)))
}
