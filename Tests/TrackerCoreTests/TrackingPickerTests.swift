// The Tracking dropdown's "Show more…" and the window of every AI it opens.

import Foundation
import Testing
@testable import TrackerCore

private func choices(_ count: Int) -> [(key: String, name: String)] {
    (1...count).map { ("k\($0)", "AI \($0)") }
}

@Test func upToSevenAisAreAllListed() {
    #expect(PanelLayout.trackingEntries(choices(5), selected: "k2") == ["k1", "k2", "k3", "k4", "k5"])
    #expect(PanelLayout.trackingEntries(choices(7), selected: "k7") == ["k1", "k2", "k3", "k4", "k5", "k6", "k7"])
    let picker = PanelLayout.toolPicker(choices(7), selected: "k7")
    #expect(picker == .popup(label: "Tracking", options: (1...7).map { "AI \($0)" }, selected: 6, action: "select_tool"))
}

@Test func anEighthAiAddsShowMore() {
    #expect(PanelLayout.trackingEntries(choices(8), selected: "k1")
        == ["k1", "k2", "k3", "k4", "k5", "k6", "k7", nil])
    let picker = PanelLayout.toolPicker(choices(8), selected: "k3")
    #expect(picker == .popup(label: "Tracking", options: (1...7).map { "AI \($0)" } + ["Show more…"],
                             selected: 2, action: "select_tool"))
}

@Test func aSelectedAiPastSevenTakesTheSeventhPlace() {
    let entries = PanelLayout.trackingEntries(choices(12), selected: "k10")
    #expect(entries == ["k1", "k2", "k3", "k4", "k5", "k6", "k10", nil])
    #expect(entries.count == PanelLayout.trackingVisibleCount + 1)
    let picker = PanelLayout.toolPicker(choices(12), selected: "k10")
    #expect(picker == .popup(label: "Tracking", options: (1...6).map { "AI \($0)" } + ["AI 10", "Show more…"],
                             selected: 6, action: "select_tool"))
    // An unknown selection shows the first, as before.
    #expect(PanelLayout.trackingEntries(choices(12), selected: "gone") == ["k1", "k2", "k3", "k4", "k5", "k6", "k7", nil])
    if case let .popup(_, _, selected, _) = PanelLayout.toolPicker(choices(12), selected: "gone") {
        #expect(selected == 0)
    }
}

@Test func picksMapBackToTheSameEntries() {
    let list = choices(12)
    #expect(PanelLayout.trackingPick(index: 0, choices: list, selected: "k10") == .select("k1"))
    #expect(PanelLayout.trackingPick(index: 6, choices: list, selected: "k10") == .select("k10"))
    #expect(PanelLayout.trackingPick(index: 7, choices: list, selected: "k10") == .showMore)
    #expect(PanelLayout.trackingPick(index: 8, choices: list, selected: "k10") == nil)
    #expect(PanelLayout.trackingPick(index: -1, choices: list, selected: "k10") == nil)
    #expect(PanelLayout.trackingPick(index: 2, choices: choices(3), selected: "k1") == .select("k3"))
}

private func manyAis() -> JSONObject {
    var state: JSONObject = ["enabled_tools": ["claude_code", "codex"], "onboarding_done": true]
    for key in ["openai", "deepseek", "kimi", "google", "meta", "nvidia"] {
        AppState.setProviderEnabled(&state, key, true)
    }
    return state
}

@Test func allAisCountsAmongTheSeven() {
    let state = manyAis()
    let list = PanelModel.viewChoices(state, detected: ["claude_code", "codex", "opencode"])
    #expect(list.first?.key == "all")
    #expect(list.count == 9)  // All AIs, 2 tools, 6 providers
    let entries = PanelLayout.trackingEntries(list, selected: "all")
    #expect(entries == ["all", "claude_code", "codex", "openai", "deepseek", "kimi", "google", nil])
    // No AI is named like the Show more entry, and names are unique (a popup drops repeated titles).
    let names = list.map(\.name) + Providers.providers.map(\.name) + Tools.tools.map(\.name)
    #expect(!names.contains(PanelLayout.trackingShowMoreTitle))
    #expect(Set(list.map(\.name)).count == list.count)
}

@Test func theWindowListsEveryAi() {
    let state = manyAis()
    let detected = ["claude_code", "codex", "opencode"]
    let tab = PanelModel.trackingWindowTab(state, detected: detected, selected: "meta")
    #expect(tab.title == "Choose an AI")
    func buttons(_ card: Card) -> [Item.Button] {
        card.items.compactMap { if case let .buttons(b) = $0 { return b.first } else { return nil } }
    }
    let tracked = buttons(tab.cards[0])
    #expect(tab.cards[0].title == "Tracking")
    #expect(tracked.map(\.action) == PanelModel.viewChoices(state, detected: detected).map { "pick_tool:\($0.key)" })
    #expect(tracked.filter { $0.icon == "checkmark" }.map(\.title) == ["Meta"])
    // The rest: opencode (found, off) and the 29 providers that are off.
    let off = buttons(tab.cards[1])
    #expect(tab.cards[1].title == "Not turned on")
    #expect(off.first?.action == "pick_tool:opencode")
    #expect(off.count == 1 + Providers.providers.count - 6)
    #expect(off.allSatisfy { $0.icon == "plus" })
    // Every AI appears exactly once across the window.
    let all = (tracked + off).map(\.action)
    #expect(Set(all).count == all.count)
    #expect(Set(all) == Set((["all"] + detected + Providers.providers.map(\.key)).map { "pick_tool:\($0)" }))
    // Every action parses.
    for action in all { #expect(AppAction.parse(action, .none) != nil, "\(action)") }
}

@Test func theWindowHasNoOffCardWhenEverythingIsOn() {
    var state: JSONObject = ["enabled_tools": ["claude_code"], "onboarding_done": true]
    for provider in Providers.providers { AppState.setProviderEnabled(&state, provider.key, true) }
    let tab = PanelModel.trackingWindowTab(state, detected: ["claude_code"], selected: "claude_code")
    #expect(tab.cards.count == 1)
}
