// Ported from tests/test_stats_tabs.py, test for test (the limits,
// projects, Live tab and formatting tests are in PanelModelLimitsTests.swift),
// plus test_about_has_check_for_updates from tests/test_updater.py, which
// tests the Settings tab.
//
// The Python tests compare item tuples; these compare `Item` values. The
// tuple-length check in assert_well_formed has no counterpart: each `Item`
// case has its fields fixed by its type.

import Foundation
import Testing
@testable import TrackerCore

// MARK: - Helpers shared with PanelModelLimitsTests.swift

/// The Python tests' `build_panel`, the old call shape: Claude Code's view
/// of `state`, with the leaderboard shown when the state turns it on.
func buildTestPanel(_ state: JSONObject, _ sessions: [ActiveSessions.Session], _ friends: [JSONObject],
                    today: Day? = nil, view: Tools.View? = nil, showLeaderboard: Bool? = nil) -> [Tab] {
    PanelModel.buildPanel(view ?? Tools.toolView(state, "claude_code"), state: state, sessions: sessions,
                          friends: friends,
                          showLeaderboard: showLeaderboard ?? PanelModel.leaderboardEnabled(state),
                          today: today)
}

func panelEntry(_ ts: String, model: String = "claude-opus-5-5", cwd: String = "/x/proj",
                _ usage: [String: Int]) -> JSONObject {
    ["type": "assistant", "timestamp": ts, "cwd": cwd, "message": ["model": model, "usage": usage]]
}

func expectWellFormed(_ tab: Tab) {
    for card in tab.cards {
        #expect(!card.items.isEmpty, "\(tab.key)")
        for item in card.items {
            if case let .bar(_, _, fraction, _, _) = item {
                #expect(0.0 <= fraction && fraction <= 1.0)
            }
        }
    }
}

/// The warning at the top of a tab, as one string, or nil.
func alertText(_ tab: Tab) -> String? {
    let first = tab.cards.first?.items ?? []
    let lines = first.compactMap { item -> String? in
        if case let .alert(text, _) = item { return text }
        return nil
    }
    return lines.isEmpty ? nil : lines.joined(separator: " ")
}

func itemsOf(_ tab: Tab) -> [Item] {
    tab.cards.flatMap(\.items)
}

func tabsByKey(_ tabs: [Tab]) -> [String: Tab] {
    Dictionary(uniqueKeysWithValues: tabs.map { ($0.key, $0) })
}

func cardTitled(_ tab: Tab, _ title: String) -> Card? {
    tab.cards.first { $0.title == title }
}

/// An item's action string: Python's `item[-1]` for the kinds that have one.
func actionOf(_ item: Item) -> String? {
    switch item {
    case let .segmented(_, _, _, action), let .popup(_, _, _, action), let .switch(_, _, action),
         let .choices(_, _, _, action):
        return action
    default:
        return nil
    }
}

/// A popup's or segmented control's selected index: Python's `item[3]`.
func selectedOf(_ item: Item?) -> Int? {
    switch item {
    case let .segmented(_, _, selected, _)?, let .popup(_, _, selected, _)?:
        return selected
    default:
        return nil
    }
}

func notesOf(_ items: [Item]) -> [String] {
    items.compactMap { item -> String? in
        if case let .note(text) = item { return text }
        return nil
    }
}

func buttonsOf(_ items: [Item]) -> [[Item.Button]] {
    items.compactMap { item -> [Item.Button]? in
        if case let .buttons(buttons) = item { return buttons }
        return nil
    }
}

func tilesOf(_ item: Item) -> [Item.Tile] {
    if case let .tiles(tiles) = item { return tiles }
    return []
}

/// (key, name) choices as [[key, name]], so they can be compared.
func pairs(_ choices: [(key: String, name: String)]) -> [[String]] {
    choices.map { [$0.key, $0.name] }
}

let partsZero: [String: Int] = ["input": 0, "output": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0]

/// Python's `{**PARTS, ...}`.
func parts(_ overrides: [String: Int]) -> [String: Int] {
    partsZero.merging(overrides) { _, new in new }
}

func viewOf(_ daily: JSONObject, name: String = "Codex", key: String = "codex", total: Int? = nil,
            error: String? = nil) -> Tools.View {
    let total = total ?? daily.values.reduce(0) { sum, bucket in
        (JSON.object(bucket)?.object("models") ?? [:]).values.reduce(sum) { sum, models in
            (JSON.object(models) ?? [:]).values.reduce(sum) { $0 + (JSON.int($1) ?? 0) }
        }
    }
    return Tools.View(key: key, name: name, daily: daily, grandTotal: total, error: error)
}

// MARK: - Tests

@Test func formatters() {
    #expect(PanelModel.modelDisplayName("claude-opus-5-5") == "Opus 5.5")
    #expect(PanelModel.modelDisplayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(PanelModel.modelDisplayName("<synthetic>") == "<synthetic>")
    #expect(PanelModel.percent(1, 1000) == "<1%")
    #expect(PanelModel.percent(50, 100) == "50%")
    #expect(PanelModel.percent(5, 0) == "0%")
    #expect(PanelModel.formatLongDate("2026-11-03") == "November 3rd, 2026")
    #expect(PanelModel.formatShortDate(Day(2026, 11, 12)) == "Nov 12th")
    #expect(PanelModel.formatInterval(15) == "15 seconds")
    #expect(PanelModel.formatInterval(60) == "1 minute")
}

@Test func buildPanelWithData() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": 10, "output_tokens": 5]))
    let state: JSONObject = ["grand_total": 115, "daily": daily, "leaderboard_view": "total",
                             "leaderboard_enabled": true]
    let sessions = [ActiveSessions.Session(label: "~/proj", tokens: 1500)]
    let friends: [JSONObject] = [["name": "Ann", "total_tokens": 200, "yesterday_tokens": 1],
                                 ["name": "Bo", "total_tokens": 100, "yesterday_tokens": 2]]

    let list = buildTestPanel(state, sessions, friends, today: Day(2026, 7, 29))

    #expect(list.map(\.key) == [
        "overview", "breakdown", "models", "projects", "cost", "limits", "subscriptions", "sessions", "leaderboard",
    ])
    for tab in list {
        expectWellFormed(tab)
    }
    let tabs = tabsByKey(list)
    #expect(itemsOf(tabs["overview"]!).contains(
        .tiles([Item.Tile("Today", "15", "sun.max"), Item.Tile("Lifetime", "115", "infinity")])))
    let chart = itemsOf(tabs["overview"]!).compactMap { item -> [Int]? in
        if case let .chart(values, _, _) = item { return values }
        return nil
    }.first!
    #expect(chart.count == 14 && chart.last == 15)
    #expect(itemsOf(tabs["breakdown"]!).contains(.bar(label: "Older, no detail", value: "100 · 87%", fraction: 100.0 / 115)))
    #expect(itemsOf(tabs["models"]!).contains(.bar(label: "Opus 5.5", value: "15 · 100%", fraction: 1.0)))
    #expect(itemsOf(tabs["projects"]!).contains(.bar(label: "proj", value: "15 · 100%", fraction: 1.0,
                                                     extras: LabelExtras(tip: "/x/proj"))))
    #expect(tabs["sessions"]!.cards[0].title == "Sessions (1)")
    #expect(itemsOf(tabs["leaderboard"]!).contains(.bar(label: "1. Ann", value: "200", fraction: 1.0)))
    #expect(itemsOf(tabs["leaderboard"]!).contains(.bar(label: "2. Bo", value: "100", fraction: 0.5)))
}

@Test func buildPanelWithNoData() {
    let tabs = tabsByKey(buildTestPanel(["grand_total": 0, "leaderboard_enabled": true], [], [],
                                        today: Day(2026, 7, 29)))
    for tab in tabs.values {
        expectWellFormed(tab)
    }
    #expect(itemsOf(tabs["sessions"]!).contains(.note("No Claude Code sessions running")))
    #expect(itemsOf(tabs["leaderboard"]!).contains(.note("No friends added yet")))
    let buttons = buttonsOf(itemsOf(tabs["leaderboard"]!))
    #expect(buttons[0][0].action == "leaderboard_setup")
}

@Test func leaderboardButtonsAfterSetup() {
    let tabs = tabsByKey(buildTestPanel(["grand_total": 0, "my_gist_id": "abc"], [], [], today: Day(2026, 7, 29)))
    let actions = buttonsOf(itemsOf(tabs["leaderboard"]!)).flatMap { $0.map(\.action) }
    #expect(actions == ["leaderboard_share", "leaderboard_push", "leaderboard_add", "leaderboard_pull"])
}

@Test func settingsTabReflectsState() {
    var tab = PanelModel.settingsTab(
        ["title_mode": "icon", "scan_interval_seconds": 60, "start_at_login": false],
        intervalChoices: [5, 15, 30, 60, 300],
        detected: ["claude_code"]
    )
    expectWellFormed(tab)
    tab.cards = tab.cards.filter { $0.title != "AI tools" && $0.title != "AI providers" }
    let items = itemsOf(tab)
    #expect(items.contains(.segmented(label: "Shows", options: ["Lifetime", "Today", "Icon only"], selected: 2,
                                      action: "title_mode")))
    #expect(items.first { actionOf($0) == "menu_bar_font_size" }
        == .popup(label: "Text size", options: ["10 pt", "11 pt", "12 pt", "13 pt", "14 pt"], selected: 2,
                  action: "menu_bar_font_size"))  // 12 pt by default
    #expect(selectedOf(items.first { actionOf($0) == "scan_interval" }) == 3)  // 60 seconds selected
    #expect(!items.contains { actionOf($0) == "pause" })
    #expect(items.contains(.switch(label: "Start at login", isOn: false, action: "login")))
}

@Test func leaderboardTabHiddenUnlessEnabled() {
    func keys(_ state: JSONObject) -> [String] {
        buildTestPanel(state, [], [], today: Day(2026, 7, 29)).map(\.key)
    }

    #expect(!keys(["grand_total": 0]).contains("leaderboard"))
    #expect(keys(["grand_total": 0, "leaderboard_enabled": true]).contains("leaderboard"))
    // Existing leaderboard users keep the tab by default.
    #expect(keys(["grand_total": 0, "my_gist_id": "abc"]).contains("leaderboard"))
    #expect(!keys(["grand_total": 0, "my_gist_id": "abc", "leaderboard_enabled": false]).contains("leaderboard"))
}

@Test func settingsAboutCardShowsVersionAndCredits() {
    let tab = PanelModel.settingsTab([:], intervalChoices: [15], detected: ["claude_code"])
    let about = cardTitled(tab, "About")!
    #expect(about.items.contains(.row(label: "Version", value: Version.version)))
    #expect(about.items.contains(.row(label: "Original app by", value: "BrodyKretz")))
    #expect(about.items.contains(.row(label: "Redesign & new features by", value: "Raymond Tian")))
}

@Test func overviewShowsNewInputPlusOutput() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "gpt-x", project: "~/p",
                        parts: parts(["input": 30, "output": 5, "cache_read": 900]))

    let tabs = tabsByKey(buildTestPanel([:], [], [], today: Day(2026, 7, 29), view: viewOf(daily)))

    #expect(itemsOf(tabs["overview"]!).contains(.row(label: "New input + output", value: "35")))
}

@Test func errorNoteShown() {
    let tabs = tabsByKey(buildTestPanel([:], [], [], today: Day(2026, 7, 29), view: viewOf([:], error: "bad file")))

    #expect(alertText(tabs["overview"]!) == "Codex data couldn't be read: bad file")
}

@Test func costUsesRecordedCost() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "gemini-4-argon", project: "~/p",
                        parts: parts(["input": 10]), cost: 1.25)

    let tabs = tabsByKey(buildTestPanel([:], [], [], today: Day(2026, 7, 29),
                                        view: viewOf(daily, name: "opencode", key: "opencode")))

    #expect(tilesOf(tabs["cost"]!.cards[0].items[0]).contains(Item.Tile("Today", "$1.25", "sun.max")))
}

@Test func sessionsEmptyMessageNamesTool() {
    let tabs = tabsByKey(buildTestPanel([:], [], [], today: Day(2026, 7, 29), view: viewOf([:])))

    #expect(itemsOf(tabs["sessions"]!).contains(.note("No Codex sessions running")))
}

@Test func sessionsWithoutAKnownStateShowUnknownWithAHollowDot() {
    let tabs = tabsByKey(buildTestPanel([:], [ActiveSessions.Session(label: "~/p", tokens: nil)], [],
                                        today: Day(2026, 7, 29), view: viewOf([:])))

    #expect(itemsOf(tabs["sessions"]!).contains(
        .row(label: "p", value: "Unknown", extras: LabelExtras(dot: .hollow))))
}

@Test func leaderboardOnlyWhenRequested() {
    let state: JSONObject = ["grand_total": 0, "leaderboard_enabled": true]
    let keys = buildTestPanel(state, [], [], today: Day(2026, 7, 29), showLeaderboard: false).map(\.key)
    #expect(!keys.contains("leaderboard"))
}

@Test func settingsListsDetectedToolsOnly() {
    let state: JSONObject = ["enabled_tools": ["claude_code"]]

    let tab = PanelModel.settingsTab(state, intervalChoices: [15], detected: ["claude_code", "opencode"])

    let toolsCard = cardTitled(tab, "AI tools")!
    let tools = toolsCard.items.filter { actionOf($0)?.hasPrefix("tool:") ?? false }
    #expect(tools == [
        .switch(label: "Claude Code", isOn: true, action: "tool:claude_code"),
        .switch(label: "opencode", isOn: false, action: "tool:opencode"),
    ])
}

@Test func welcomeListsDetectedTools() {
    let tab = PanelModel.welcomeTab(detected: ["claude_code", "codex"], chosen: ["codex"])

    #expect(tab.key == "welcome")
    let items = itemsOf(tab)
    #expect(items.contains(.switch(label: "Claude Code", isOn: false, action: "welcome_tool:claude_code")))
    #expect(items.contains(.switch(label: "Codex", isOn: true, action: "welcome_tool:codex")))
    #expect(items.contains(.buttons([Item.Button("Continue", "arrow.right.circle", "welcome_done")])))
}

@Test func welcomeWithNoToolsDetected() {
    let items = itemsOf(PanelModel.welcomeTab(detected: [], chosen: []))

    #expect(items.contains(.note("No supported AI tools found on this Mac yet.")))
    #expect(items.contains(.buttons([Item.Button("Continue", "arrow.right.circle", "welcome_done")])))
}

@Test func toolChoicesAreEnabledToolsDetectedOrWithHistory() {
    let state: JSONObject = [
        "enabled_tools": ["claude_code", "codex", "opencode"],
        "sources": ["opencode": ["daily": ["2026-07-29": ["models": JSONObject(), "projects": JSONObject()]]]],
    ]

    #expect(pairs(PanelModel.toolChoices(state, detected: ["claude_code"])) == [
        ["claude_code", "Claude Code"], ["opencode", "opencode"],
    ])
}

@Test func settingsKeepsEnabledToolWhoseDataDisappeared() {
    let state: JSONObject = ["enabled_tools": ["claude_code", "codex"]]

    let tab = PanelModel.settingsTab(state, intervalChoices: [15], detected: ["claude_code"])

    let toolsCard = cardTitled(tab, "AI tools")!
    #expect(toolsCard.items.contains(.switch(label: "Codex", isOn: true, action: "tool:codex")))
}

@Test func combinedCostPricesEachToolSeparately() {
    var claudeDaily = JSONObject()
    var opencodeDaily = JSONObject()
    UsageStats.addUsage(&claudeDaily, day: Day(2026, 7, 29), model: "claude-opus-5-5", project: "~/p",
                        parts: parts(["input": 1_000_000]))
    UsageStats.addUsage(&opencodeDaily, day: Day(2026, 7, 29), model: "claude-opus-5-5", project: "~/p",
                        parts: parts(["input": 10]), cost: 0.5)
    let state: JSONObject = ["grand_total": 1_000_000, "daily": claudeDaily,
                             "sources": ["opencode": ["daily": opencodeDaily]]]

    let view = Tools.combinedView(state, enabled: ["claude_code", "opencode"])
    let tabs = tabsByKey(buildTestPanel(state, [], [], today: Day(2026, 7, 29), view: view))

    // Claude Code: 1M input at $4/M; opencode: its recorded $0.50.
    #expect(tilesOf(tabs["cost"]!.cards[0].items[0]).contains(Item.Tile("Today", "$4.50", "sun.max")))
}

// MARK: - Providers

private func providerView(_ key: String = "openai", _ name: String = "OpenAI") -> Tools.View {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 11, 8), model: "gpt-5", project: "~/a", parts: ["input": 5])
    return Tools.View(key: key, name: name, daily: daily, grandTotal: 5, error: nil, views: [])
}

private func card(_ tabs: [Tab], _ tabKey: String, _ title: String) -> Card {
    let tab = tabs.first { $0.key == tabKey }!
    return cardTitled(tab, title)!
}

@Test func toolChoicesAddEnabledProvidersAfterTools() {
    let state: JSONObject = ["enabled_tools": ["claude_code"], "enabled_providers": ["kimi", "openai"]]

    #expect(pairs(PanelModel.toolChoices(state, detected: ["claude_code"])) == [
        ["claude_code", "Claude Code"], ["openai", "OpenAI"], ["kimi", "Kimi"],
    ])
}

@Test func providerViewHasNoLiveSessionsTab() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8), view: providerView())

    #expect(!tabs.map(\.key).contains("sessions"))
}

@Test func withoutAKeyTheOptionalAccountCardSitsAtTheBottom() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8), view: providerView())

    let cards = tabs[0].cards
    #expect(cards.last!.title == "Whole account (optional)")
    let items = cards.last!.items
    #expect(items.last == .buttons([Item.Button("Add API Key", "key", "provider_key:openai")]))
    #expect(!cards.contains { $0.title == "OpenAI account" })
}

@Test func providerAccountCardWithFetchedNumbers() {
    var accountDaily = JSONObject()
    UsageStats.addUsage(&accountDaily, day: Day(2026, 11, 8), model: "gpt-5", project: "Account", parts: ["input": 1000])
    UsageStats.addUsage(&accountDaily, day: Day(2026, 11, 1), model: "gpt-5", project: "Account", parts: ["input": 2000])
    UsageStats.addUsage(&accountDaily, day: Day(2026, 10, 15), model: "gpt-5", project: "Account", parts: ["input": 4000])
    let state: JSONObject = ["provider_keys": ["openai"], "accounts": ["openai": [
        "daily": accountDaily, "cost": ["2026-11-08": 1.5, "2026-10-15": 2.0],
        "rows": [["Balance", "$3.00"]], "notes": ["Hello"], "error": "boom",
        "fetched_at": "2026-11-08T09:05:00", "attempted_at": "2026-11-08T09:20:00",
    ] as JSONObject]]

    let tabs = buildTestPanel(state, [], [], today: Day(2026, 11, 8), view: providerView())

    let items = card(tabs, "overview", "OpenAI account").items
    #expect(items.contains(.row(label: "Today", value: "1.0K")))
    #expect(items.contains(.row(label: "Last 7 days", value: "1.0K")))
    #expect(items.contains(.row(label: "Last 30 days", value: "7.0K")))
    #expect(items.contains(.row(label: "Billed, last 30 days", value: "$3.50")))
    #expect(items.contains(.row(label: "Balance", value: "$3.00")))
    let notes = notesOf(items)
    #expect(notes.contains("Hello"))
    #expect(!notes.contains { $0.contains("boom") })  // shown as the warning instead
    #expect(alertText(tabs[0]) == "Couldn't connect to OpenAI: boom")
    #expect(notes.contains("Updated 9:05 AM"))
    #expect(items.last == .buttons([Item.Button("Replace Key", "key", "provider_key:openai"),
                                    Item.Button("Remove Key", "trash", "provider_key_remove:openai")]))
}

@Test func providerAccountCardBeforeFirstFetch() {
    let state: JSONObject = ["provider_keys": ["kimi"], "accounts": JSONObject()]

    let tabs = buildTestPanel(state, [], [], today: Day(2026, 11, 8), view: providerView("kimi", "Kimi"))

    #expect(card(tabs, "overview", "Kimi account").items.contains(.note("Fetching account numbers…")))
}

@Test func toolViewsHaveNoAccountCard() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8))

    let titles = tabs[0].cards.map(\.title)
    #expect(!titles.contains { $0?.hasSuffix("account") ?? false })
}

@Test func settingsOnlySwitchesProvidersOnAndOff() {
    let state: JSONObject = ["enabled_tools": [String](), "enabled_providers": ["openai", "kimi"],
                             "provider_keys": ["kimi"]]

    let tab = PanelModel.settingsTab(state, intervalChoices: [15], detected: [])

    #expect(!tab.cards.map(\.title).contains("AI providers"))
    let items = cardTitled(tab, "AI tools")!.items
    #expect(items.contains(.switch(label: "OpenAI", isOn: true, action: "provider:openai")))
    #expect(items.contains(.switch(label: "DeepSeek", isOn: false, action: "provider:deepseek")))
    // Turning a provider on asks for nothing: no key buttons or notes here.
    #expect(items.allSatisfy { $0.kind == "switch" })
}

@Test func longNotesAreSplitIntoLines() {
    let text = "the API key was rejected (HTTP 401) and some more words to make it long"

    let lines = PanelModel.noteLines(text)

    #expect(lines.count > 1)
    #expect(lines.allSatisfy { $0.kind == "note" })
    #expect(notesOf(lines).allSatisfy { $0.count <= 46 })
    #expect(notesOf(lines).joined(separator: " ") == text)
}

@Test func dropdownOffersAllAisFirstOnceTwoToolsAreOn() {
    let state: JSONObject = ["enabled_tools": ["claude_code", "opencode"], "enabled_providers": ["kimi"]]

    #expect(pairs(PanelModel.viewChoices(state, detected: ["claude_code", "opencode"])) == [
        ["all", "All AIs"], ["claude_code", "Claude Code"], ["opencode", "opencode"], ["kimi", "Kimi"],
    ])
}

@Test func dropdownHasNoAllAisWithASingleTool() {
    let state: JSONObject = ["enabled_tools": ["claude_code"], "enabled_providers": ["kimi"]]

    #expect(pairs(PanelModel.viewChoices(state, detected: ["claude_code"]))
        == pairs(PanelModel.toolChoices(state, detected: ["claude_code"])))
}

@Test func settingsOnlyPicksWhichAisAreUsed() {
    let state: JSONObject = ["enabled_tools": ["claude_code"], "enabled_providers": ["kimi"]]

    let tab = PanelModel.settingsTab(state, intervalChoices: [15], detected: ["claude_code", "codex"])

    let items = cardTitled(tab, "AI tools")!.items
    let switches = items.compactMap { item -> String? in
        if case let .switch(label, _, _) = item { return label }
        return nil
    }
    #expect(switches == ["Claude Code", "Codex"] + Providers.providers.map(\.name))
}

// MARK: - Warnings when an AI's usage can't be seen

private func emptyProvider(_ key: String, _ name: String) -> Tools.View {
    Tools.View(key: key, name: name, daily: [:], grandTotal: 0, error: nil, views: [])
}

@Test func providerWithNoUsageWarnsOnEveryTab() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8), view: emptyProvider("kimi", "Kimi"))

    for tab in tabs {
        expectWellFormed(tab)
        #expect(alertText(tab)?.hasPrefix("No Kimi usage found on this Mac.") == true, "\(tab.key)")
    }
    guard case let .alert(_, showIcon) = tabs[0].cards[0].items[0] else {
        Issue.record("the first item isn't a warning line")
        return
    }
    #expect(showIcon == true)  // icon on the first line only
    #expect(alertText(tabs[0])!.contains("add an API key at the bottom of Home"))
}

@Test func deepseekWithoutUsageExplainsAKeyWontShowIt() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8), view: emptyProvider("deepseek", "DeepSeek"))

    #expect(alertText(tabs[0])!.contains("doesn't share usage history"))
}

@Test func keyThatOnlyGivesABalanceIsExplained() {
    let state: JSONObject = ["provider_keys": ["kimi"], "accounts": ["kimi": [
        "daily": JSONObject(), "cost": JSONObject(), "rows": [["Balance", "$1.00"]], "notes": [String](),
        "error": NSNull(), "has_usage": false, "fetched_at": "2026-11-08T09:00:00",
    ] as JSONObject]]

    let tabs = buildTestPanel(state, [], [], today: Day(2026, 11, 8), view: emptyProvider("kimi", "Kimi"))

    #expect(alertText(tabs[0])!.contains("only shows your balance"))
}

@Test func accountConnectionErrorIsAWarning() {
    let state: JSONObject = ["provider_keys": ["openai"], "accounts": ["openai": [
        "daily": JSONObject(), "cost": JSONObject(), "rows": [Any](), "notes": [String](),
        "error": "the API key was rejected (HTTP 401)",
        "fetched_at": NSNull(), "attempted_at": "2026-11-08T09:00:00",
    ] as JSONObject]]

    let tabs = buildTestPanel(state, [], [], today: Day(2026, 11, 8), view: providerView())

    #expect(alertText(tabs[0]) == "Couldn't connect to OpenAI: the API key was rejected (HTTP 401)")
    #expect(alertText(tabs[2]) == alertText(tabs[0]))
}

@Test func noWarningWhenUsageIsVisible() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8), view: providerView())

    #expect(tabs.allSatisfy { alertText($0) == nil })
}

@Test func noWarningWhileWaitingForFirstFetch() {
    let state: JSONObject = ["provider_keys": ["kimi"], "accounts": JSONObject()]

    let tabs = buildTestPanel(state, [], [], today: Day(2026, 11, 8), view: emptyProvider("kimi", "Kimi"))

    #expect(alertText(tabs[0]) == nil)
}

@Test func settingsHasThePanelAnimationSpeed() {
    var tab = PanelModel.settingsTab([:], intervalChoices: [15], detected: [])
    var items = cardTitled(tab, "Menu bar")!.items

    #expect(items.contains(.popup(label: "Animation", options: ["Off", "Fast", "Normal", "Slow"], selected: 2,
                                  action: "panel_animation")))

    tab = PanelModel.settingsTab(["panel_animation": "off"], intervalChoices: [15], detected: [])
    items = cardTitled(tab, "Menu bar")!.items
    #expect(items.contains(.popup(label: "Animation", options: ["Off", "Fast", "Normal", "Slow"], selected: 0,
                                  action: "panel_animation")))
}

@Test func providersWithoutKeySupportOfferNoKey() {
    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8), view: emptyProvider("google", "Google"))

    #expect(!tabs[0].cards.contains { $0.title == "Whole account (optional)" })
    let warning = alertText(tabs[0])
    #expect(warning == "No Google usage found on this Mac. None of your tools have used Google models yet.")
}

@Test func toolWithNoUsageYetWarns() {
    let view = Tools.View(key: "gemini_cli", name: "Gemini CLI", daily: [:], grandTotal: 0, error: nil)

    let tabs = buildTestPanel([:], [], [], today: Day(2026, 11, 8), view: view)

    #expect(alertText(tabs[0]) == "No Gemini CLI usage found on this Mac yet.")
}

// From tests/test_updater.py.
@Test func aboutHasCheckForUpdates() {
    let tab = PanelModel.settingsTab([:], intervalChoices: [15], detected: [], updateStatus: "Checking…")

    let about = cardTitled(tab, "About")!.items
    #expect(about.contains(.row(label: "Updates", value: "Checking…")))
    let buttons = buttonsOf(about).first!
    #expect(buttons.contains(Item.Button("Check for Updates", "arrow.down.circle", "check_updates")))
}

// MARK: - Foundation (3.1): result entry point, measured wrapping

@Test func buildPanelWrapperMatchesResultTabs() {
    let state: JSONObject = [:]
    let view = Tools.toolView(state, "claude_code")
    let wrapped = PanelModel.buildPanel(view, state: state, sessions: [], friends: [], showLeaderboard: false,
                                        today: Day(2026, 5, 20))
    let result = PanelModel.buildPanelResult(view, state: state, sessions: [], friends: [],
                                             showLeaderboard: false, today: Day(2026, 5, 20))
    #expect(wrapped == result.tabs)
}

private let sevenPerChar: TextMeasure = { text, _, _ in CGFloat(text.count) * 7 }

@Test func wrapMeasuredBreaksWideWordsByCharacter() {
    #expect(PanelModel.wrapMeasured("abcdefghij kl", width: 28, size: 11, measure: sevenPerChar)
        == ["abcd", "efgh", "ij", "kl"])
    #expect(PanelModel.wrapMeasured("", width: 28, size: 11, measure: sevenPerChar) == [])
}

@Test func stubMeasureBoundaryAtBudgetMinusOne() {
    func cut(_ width: CGFloat, _ budget: CGFloat) -> Bool {
        PanelLayout.isCutOff(text: "x", size: 13, weight: .regular, budget: budget, measure: { _, _, _ in width })
    }
    #expect(!cut(191, 192))
    #expect(cut(192, 192))
    #expect(!cut(177, 178))
    #expect(cut(178, 178))
    #expect(!cut(187, 188))
    #expect(cut(188, 188))
}

// MARK: - Effort on the Models tab

private func effortTabs(_ entries: [(model: String, effort: String?, tokens: Int)],
                        changeBucket: ((inout JSONObject) -> Void)? = nil) -> [String: Tab] {
    var daily = JSONObject()
    for entry in entries {
        var e = panelEntry("2026-07-29T12:00:00.000Z", model: entry.model, ["input_tokens": entry.tokens])
        e["effort"] = entry.effort
        if entry.effort == nil { e["effort"] = nil }
        UsageStats.recordEntry(&daily, e)
    }
    if let change = changeBucket {
        var bucket = daily.object("2026-07-29")!
        change(&bucket)
        daily["2026-07-29"] = bucket
    }
    let view = viewOf(daily, name: "Claude Code", key: "claude_code")
    return tabsByKey(buildTestPanel([:], [], [], today: Day(2026, 7, 29), view: view))
}

@Test func effortRowsSumToModelTotal() {
    let tabs = effortTabs([("claude-opus-5-5", "high", 60), ("claude-opus-5-5", "xhigh", 40),
                           ("gpt-5.6-luna", "medium", 100)])

    let items = itemsOf(tabs["models"]!)

    #expect(items.contains(.bar(label: "gpt-5.6-luna (Medium)", value: "100 · 50%", fraction: 0.5)))
    #expect(items.contains(.bar(label: "Opus 5.5 (High)", value: "60 · 30%", fraction: 0.3)))
    #expect(items.contains(.bar(label: "Opus 5.5 (Xhigh)", value: "40 · 20%", fraction: 0.2)))
    #expect(!items.contains { if case let .bar(label, _, _, _, _) = $0 { return label == "Opus 5.5" } else { return false } })
    // Within a model, the larger effort comes first.
    let labels = items.compactMap { item -> String? in
        if case let .bar(label, _, _, _, _) = item { return label } else { return nil }
    }
    let high = labels.firstIndex(of: "Opus 5.5 (High)")!
    #expect(high < labels.firstIndex(of: "Opus 5.5 (Xhigh)")!)
}

private func barLabels(_ card: Card) -> [String] {
    card.items.compactMap { item -> String? in
        if case let .bar(label, _, _, _, _) = item { return label } else { return nil }
    }
}

@Test func tokenOrderSortsEffortRowsOnTheirOwn() {
    // Opus has 100 (High 60, Low 40), Sonnet 50. In token order a model's
    // efforts are not tied to it: Sonnet sits between Opus's two rows.
    let models: UsageStats.Models = [
        "claude-opus-5-5": ["input": 100], "claude-sonnet-5-5": ["input": 50],
    ]
    let efforts = ["claude-opus-5-5": ["high": 60, "low": 40]]
    let card = PanelModel.modelsCard("Today", models, efforts: efforts, order: .tokens)
    #expect(barLabels(card) == ["Opus 5.5 (High)", "Sonnet 5.5", "Opus 5.5 (Low)"])

    // The leftover plain row takes part too.
    let leftover = PanelModel.modelsCard("Today", models, efforts: ["claude-opus-5-5": ["high": 30]], order: .tokens)
    #expect(barLabels(leftover) == ["Opus 5.5 (No effort recorded)", "Sonnet 5.5", "Opus 5.5 (High)"])

    // Equal rows keep model order, then effort order.
    let tied = PanelModel.modelsCard("Today", ["claude-opus-5-5": ["input": 40], "claude-sonnet-5-5": ["input": 20]],
                                     efforts: ["claude-opus-5-5": ["high": 20, "low": 20]], order: .tokens)
    #expect(barLabels(tied) == ["Opus 5.5 (High)", "Opus 5.5 (Low)", "Sonnet 5.5"])
}

@Test func tierOrderKeepsEffortRowsUnderTheirModel() {
    let models: UsageStats.Models = [
        "claude-opus-5-5": ["input": 100], "claude-sonnet-5-5": ["input": 50],
    ]
    let efforts = ["claude-opus-5-5": ["high": 60, "low": 40]]
    let card = PanelModel.modelsCard("Today", models, efforts: efforts, order: .tier)
    #expect(barLabels(card) == ["Sonnet 5.5", "Opus 5.5 (High)", "Opus 5.5 (Low)"])
}

@Test func effortSumIsClampedToTheModelTotal() {
    // A merge or backfill can leave more tokens in `efforts` than the model has.
    let tabs = effortTabs([("claude-opus-5-5", "high", 100)]) { bucket in
        bucket["efforts"] = ["claude-opus-5-5": ["high": 150, "low": 20]] as JSONObject
    }

    let items = itemsOf(tabs["models"]!)

    #expect(items.contains(.bar(label: "Opus 5.5 (High)", value: "100 · 100%", fraction: 1.0)))
    #expect(!items.contains { if case let .bar(label, _, _, _, _) = $0 { return label.contains("Low") || label == "Opus 5.5" } else { return false } })
}

@Test func remainderRowOnlyWhenPositive() {
    let tabs = effortTabs([("claude-opus-5-5", "high", 70), ("claude-opus-5-5", nil, 30)])

    let items = itemsOf(tabs["models"]!)

    #expect(items.contains(.bar(label: "Opus 5.5 (High)", value: "70 · 70%", fraction: 0.7)))
    #expect(items.contains(.bar(label: "Opus 5.5 (No effort recorded)", value: "30 · 30%", fraction: 0.3)))
}

@Test func modelsWithoutEffortKeepTheirPlainRowAndCostIsUnchanged() {
    let plain = effortTabs([("claude-opus-5-5", nil, 100)])
    let withEffort = effortTabs([("claude-opus-5-5", "high", 100)])

    #expect(itemsOf(plain["models"]!).contains(.bar(label: "Opus 5.5", value: "100 · 100%", fraction: 1.0)))
    #expect(plain["cost"]! == withEffort["cost"]!)
    #expect(plain["breakdown"]! == withEffort["breakdown"]!)
}

// MARK: - Round 2: effort option, chart range and hover, folder names, currency

private func effortState(_ extra: JSONObject = [:]) -> JSONObject {
    var daily = JSONObject()
    for (effort, tokens) in [("high", 60), ("medium", 40)] {
        var e = panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": tokens])
        e["effort"] = effort
        UsageStats.recordEntry(&daily, e)
    }
    return ["daily": daily].merging(extra) { _, new in new }
}

private func tabsFor(_ daily: JSONObject, state: JSONObject = [:]) -> [String: Tab] {
    let view = viewOf(daily, name: "Claude Code", key: "claude_code")
    return tabsByKey(buildTestPanel(state, [], [], today: Day(2026, 7, 29), view: view))
}

private func labels(_ tab: Tab) -> [String] {
    itemsOf(tab).compactMap { item -> String? in
        if case let .bar(label, _, _, _, _) = item { return label } else { return nil }
    }
}

@Test func modelsTabOffersEffortOnOrOff() {
    let on = tabsFor(effortState()["daily"] as! JSONObject)["models"]!
    #expect(on.cards[0].items == [.switch(label: "Show effort", isOn: true, action: "show_effort")])
    #expect(labels(on).contains("Opus 5.5 (High)") && labels(on).contains("Opus 5.5 (Medium)"))

    let off = tabsFor(effortState()["daily"] as! JSONObject, state: ["show_effort": false])["models"]!
    #expect(off.cards[0].items == [.switch(label: "Show effort", isOn: false, action: "show_effort")])
    #expect(labels(off) == ["Opus 5.5", "Opus 5.5"])  // Today and Lifetime, one plain row each
    #expect(itemsOf(off).contains(.bar(label: "Opus 5.5", value: "100 · 100%", fraction: 1.0)))
}

@Test func noEffortControlWhenNothingHasAnEffort() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": 10]))

    let tab = tabsFor(daily)["models"]!

    #expect(!itemsOf(tab).contains { if case .segmented = $0 { return true } else { return false } })
}

@Test func chartRangeIsSevenFourteenOrThirty() {
    #expect(PanelModel.chartDays(from: [:]) == 14)
    for days in [1, 7, 14, 30] { #expect(PanelModel.chartDays(from: ["chart_days": days]) == days) }
    for bad: Any in [10, 0, -7, "30", NSNull(), 30.5, true] { #expect(PanelModel.chartDays(from: ["chart_days": bad]) == 14) }
}

@Test func overviewChartUsesHoursForOneDayAndDaysForLongerRanges() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": 15]))
    for days in [1, 7, 14, 30] {
        let tab = tabsFor(daily, state: ["chart_days": days])["overview"]!
        let expectedTitle = days == 1 ? "Last 1 day" : "Last \(days) days"
        let card = tab.cards.first { $0.title == expectedTitle }!
        #expect(card.items[0] == .segmented(label: nil, options: ["1 day", "7 days", "14 days", "30 days", "All", "Custom"],
                                            selected: [1, 7, 14, 30].firstIndex(of: days)!, action: "chart_days"))
        guard case let .chart(values, _, chartLabels) = card.items[1] else { Issue.record("no chart"); return }
        if days == 1 {
            #expect(values.count == 24 && chartLabels.count == 24)
            #expect(values.reduce(0, +) == 15)
            #expect(chartLabels.first == "12 AM" && chartLabels.last == "11 PM")
        } else {
            #expect(values.count == days && chartLabels.count == days)
            #expect(chartLabels.last == "Jul 29th" && values.last == 15)
            #expect(chartLabels.first == PanelModel.formatShortDate(Day(2026, 7, 29).adding(days: -(days - 1))))
        }
    }
}

@Test func oneDayChartPlacesTokensInTheirLocalHours() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T09:10:00", ["input_tokens": 12]))
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T15:30:00", ["output_tokens": 8]))
    let tab = tabsFor(daily, state: ["chart_days": 1])["overview"]!
    let card = tab.cards.first { $0.title == "Last 1 day" }!
    guard case let .chart(values, caption, labels) = card.items[1] else { Issue.record("no chart"); return }
    #expect(values[9] == 12 && values[15] == 8)
    #expect(values.reduce(0, +) == 20)
    #expect(labels[9] == "9 AM" && labels[15] == "3 PM")
    #expect(caption == "Peak 12 per hour")
}

@Test func projectRowsShowOnlyTheFolderName() {
    var daily = JSONObject()
    for (cwd, tokens) in [("/x/game", 10), ("/x/other/tools", 6), ("/Users/me/Desktop/My Project", 3)] {
        UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", cwd: cwd, ["input_tokens": tokens]))
    }

    let projects = labels(tabsFor(daily)["projects"]!)

    #expect(projects == ["game", "tools", "My Project"])
}

@Test func foldersWithTheSameNameShowTheirParent() {
    var daily = JSONObject()
    for (cwd, tokens) in [("/a/b/app", 10), ("/a/c/app", 6), ("/a/c/other", 3), ("/x/solo", 2)] {
        UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", cwd: cwd, ["input_tokens": tokens]))
    }

    let tab = tabsFor(daily)["projects"]!

    #expect(labels(tab) == ["app · b", "app · c", "other", "solo"])
    #expect(itemsOf(tab).contains(.bar(label: "app · b", value: "10 · 48%", fraction: 10.0 / 21,
                                       extras: LabelExtras(tip: "/a/b/app"))))
}

@Test func theHomeFolderAndRootKeepTheirOwnNames() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "m", project: "~", parts: ["input": 5])
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "m", project: "/", parts: ["input": 4])
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "m", project: "~/Desktop/a", parts: ["input": 3])

    #expect(labels(tabsFor(daily)["projects"]!) == ["~", "/", "a"])
}

@Test func costTabUsesTheChosenCurrency() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", model: "claude-opus-5-5",
                                              ["input_tokens": 1_000_000]))
    func today(_ state: JSONObject) -> String {
        let tiles = itemsOf(tabsFor(daily, state: state)["cost"]!).compactMap { item -> [Item.Tile]? in
            if case let .tiles(tiles) = item { return tiles } else { return nil }
        }.first!
        return tiles[0].value
    }

    let usd = today([:])
    #expect(usd.hasPrefix("$"))
    let euro = today(["currency": "EUR"])
    #expect(euro.hasPrefix("€"))
    #expect(today(["currency": "XXX"]) == usd)  // unknown reads as dollars
    #expect(today(["currency": 5]) == usd)
}

// MARK: - Chart range: all time and custom

private let july29 = Day(2026, 7, 29)

@Test func chartRangeReadsTheSavedChoice() {
    let earliest = Day(2026, 3, 2)
    func range(_ state: JSONObject) -> PanelModel.ChartRange {
        PanelModel.chartRange(from: state, today: july29, earliest: earliest)
    }
    #expect(range([:]) == .days(14))
    #expect(range(["chart_days": 30]) == .days(30))
    #expect(range(["chart_mode": "all"]) == .allTime(from: earliest))
    #expect(range(["chart_mode": "custom", "chart_from": "2026-07-01", "chart_to": "2026-07-20"])
            == .custom(from: Day(2026, 7, 1), to: Day(2026, 7, 20)))
    // Backwards dates swap; a future end stops at today.
    #expect(range(["chart_mode": "custom", "chart_from": "2026-07-20", "chart_to": "2026-07-01"])
            == .custom(from: Day(2026, 7, 1), to: Day(2026, 7, 20)))
    #expect(range(["chart_mode": "custom", "chart_from": "2026-07-01", "chart_to": "2030-01-01"])
            == .custom(from: Day(2026, 7, 1), to: july29))
    // Anything unreadable is the 14-day default.
    #expect(range(["chart_mode": "custom", "chart_from": "nope", "chart_to": "2026-07-20"]) == .days(14))
    #expect(range(["chart_mode": "custom", "chart_from": 5, "chart_to": NSNull()]) == .days(14))
    #expect(range(["chart_mode": "sideways", "chart_days": 7]) == .days(7))
    #expect(range(["chart_mode": 3]) == .days(14))
}

@Test func allTimeWithNoUsageIsJustToday() {
    #expect(PanelModel.chartRange(from: ["chart_mode": "all"], today: july29, earliest: nil)
            == .allTime(from: july29))
}

@Test func overviewChartAllTimeStartsAtTheFirstDay() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-05-01T12:00:00.000Z", ["input_tokens": 9]))
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": 15]))
    let tab = tabsFor(daily, state: ["chart_mode": "all"])["overview"]!
    let card = tab.cards.first { $0.title == "All time" }!

    #expect(card.items[0] == .segmented(label: nil, options: ["1 day", "7 days", "14 days", "30 days", "All", "Custom"],
                                        selected: 4, action: "chart_days"))
    guard case let .chart(values, caption, chartLabels) = card.items[1] else { Issue.record("no chart"); return }
    #expect(values.reduce(0, +) == 24 && values.count <= 60 && values.count == chartLabels.count)
    #expect(chartLabels.first?.hasPrefix("May 1st") == true && chartLabels.last?.hasSuffix("Jul 29th") == true)
    #expect(caption.hasPrefix("Peak "))
}

@Test func overviewChartCustomHasAChangeDatesButton() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-10T12:00:00.000Z", ["input_tokens": 9]))
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": 15]))
    let state: JSONObject = ["chart_mode": "custom", "chart_from": "2026-07-10", "chart_to": "2026-07-14"]
    let tab = tabsFor(daily, state: state)["overview"]!
    let card = tab.cards.first { $0.title == "Jul 10th – Jul 14th" }!

    #expect(card.items[0] == .segmented(label: nil, options: ["1 day", "7 days", "14 days", "30 days", "All", "Custom"],
                                        selected: 5, action: "chart_days"))
    // The dates are picked in a popup; this opens it again.
    #expect(card.items[1] == .buttons([Item.Button("Change dates", "calendar", "chart_edit")]))
    guard case let .chart(values, _, _) = card.items[2] else { Issue.record("no chart"); return }
    #expect(values == [9, 0, 0, 0, 0])
}

@Test func otherRangesHaveNoChangeDatesButton() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": 15]))
    for state: JSONObject in [[:], ["chart_mode": "all"], ["chart_days": 30]] {
        let items = itemsOf(tabsFor(daily, state: state)["overview"]!)
        #expect(!items.contains { if case .buttons = $0 { return true } else { return false } })
    }
}

// MARK: - The Custom range popup

@Test func theCustomRangeIsAPopupAndNeverATab() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-10T12:00:00.000Z", ["input_tokens": 9]))
    let view = viewOf(daily, name: "Claude Code", key: "claude_code")
    let state: JSONObject = ["chart_mode": "custom", "chart_from": "2026-07-12", "chart_to": "2026-07-20"]

    let closed = PanelModel.buildPanel(view, state: state, sessions: [], friends: [], showLeaderboard: false, today: july29)
    let open = PanelModel.buildPanel(view, state: state, sessions: [], friends: [], showLeaderboard: false, today: july29,
                                     rangeOpen: true)

    #expect(!closed.map(\.key).contains("range"))
    #expect(open.map(\.key) == closed.map(\.key))
    let popup = PanelModel.rangePopupCard(view, state: state, today: july29)
    #expect(popup.title == "Custom range")
    #expect(popup.items.first == .rangePicker(from: Day(2026, 7, 12), to: Day(2026, 7, 20),
                                              earliest: Day(2026, 7, 10), latest: july29))
    #expect(popup.items.contains(.note("Usage is recorded from Jul 10th.")))
}

@Test func theCustomRangePopupStartsFromTheShownRange() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-01T12:00:00.000Z", ["input_tokens": 9]))
    let view = viewOf(daily, name: "Claude Code", key: "claude_code")
    func page(_ state: JSONObject) -> Item? {
        PanelModel.rangePopupCard(view, state: state, today: july29).items.first
    }

    // Not custom yet: the range the chart shows (the last 14 days unless picked otherwise, or all of it).
    #expect(page([:]) == .rangePicker(from: Day(2026, 7, 16), to: july29, earliest: Day(2026, 7, 1), latest: july29))
    #expect(page(["chart_days": 1]) == .rangePicker(from: july29, to: july29, earliest: Day(2026, 7, 1), latest: july29))
    #expect(page(["chart_days": 7]) == .rangePicker(from: Day(2026, 7, 23), to: july29, earliest: Day(2026, 7, 1), latest: july29))
    #expect(page(["chart_mode": "all"]) == .rangePicker(from: Day(2026, 7, 1), to: july29, earliest: Day(2026, 7, 1), latest: july29))
}

@Test func aCustomRangeNeverStartsBeforeTheFirstDay() {
    let earliest = Day(2026, 7, 10)
    func range(_ from: String, _ to: String) -> PanelModel.ChartRange {
        PanelModel.chartRange(from: ["chart_mode": "custom", "chart_from": from, "chart_to": to],
                              today: july29, earliest: earliest)
    }
    #expect(range("2026-07-01", "2026-07-20") == .custom(from: earliest, to: Day(2026, 7, 20)))
    // Entirely before the first usage (a mistyped year): the last 30 days instead of an empty chart.
    #expect(range("2025-10-08", "2025-10-08") == .custom(from: earliest, to: july29))
}

@Test func aCustomRangeWithNoUsageSaysSo() {
    var daily = JSONObject()
    UsageStats.recordEntry(&daily, panelEntry("2026-07-10T12:00:00.000Z", ["input_tokens": 9]))
    UsageStats.recordEntry(&daily, panelEntry("2026-07-29T12:00:00.000Z", ["input_tokens": 15]))
    let state: JSONObject = ["chart_mode": "custom", "chart_from": "2026-07-15", "chart_to": "2026-07-20"]
    let card = tabsFor(daily, state: state)["overview"]!.cards.first { $0.title == "Jul 15th – Jul 20th" }!

    guard case let .chart(values, caption, _) = card.items[2] else { Issue.record("no chart"); return }
    #expect(values == [0, 0, 0, 0, 0, 0] && caption == "No usage in this range")
}

@Test func theLeaderboardTabIsCalledBoardAndSaysItIsWorkInProgressAndClaudeCodeNumbers() {
    let tabs = tabsByKey(buildTestPanel(["grand_total": 0, "leaderboard_enabled": true], [], [],
                                        today: Day(2026, 7, 29), view: viewOf([:]), showLeaderboard: true))
    let board = tabs["leaderboard"]!
    #expect(board.short == "Board")
    #expect(board.title == "Leaderboard (Beta · WIP)")
    let notes = board.cards.flatMap(\.items).compactMap { item -> String? in
        if case .note(let text) = item { return text }
        return nil
    }.joined(separator: " ")
    #expect(notes.contains("Claude Code totals"))
    #expect(notes.contains("Work in progress"))
}

@Test func theLeaderboardTabIsPresentInAToolViewAllAIsAndACompanyView() {
    let state: JSONObject = ["grand_total": 0, "leaderboard_enabled": true]
    for key in ["claude_code", "codex", "all", Providers.providerNames.keys.sorted()[0]] {
        let panel = PanelModel.buildPanel(Tools.toolView(state, key), state: state, sessions: [], friends: [],
                                          showLeaderboard: AppState.showsLeaderboard(key, state: state))
        let keys = panel.map { $0.key }
        #expect(keys.contains("leaderboard"), "\(key)")
    }
}
