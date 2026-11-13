// Settings > AI tools: the list stops after `toolsShown` switches, with
// "Show N more" for the rest; switches that are on always show.

import Testing
@testable import TrackerCore

private func aiToolsItems(_ state: JSONObject, detected: [String] = [], expanded: Bool = false) -> [Item] {
    let tab = PanelModel.settingsTab(state, intervalChoices: [15], detected: detected, toolsExpanded: expanded)
    return tab.cards.first { $0.title == "AI tools" }?.items ?? []
}

private func switchActions(_ items: [Item]) -> [String] {
    items.compactMap { item in
        if case let .switch(_, _, action) = item { return action }
        return nil
    }
}

@Test func aiToolsListStopsAfterToolsShownWithShowMore() {
    let items = aiToolsItems([:], detected: ["claude_code"])
    let total = 1 + Providers.providers.count
    #expect(switchActions(items).count == PanelModel.toolsShown)
    #expect(items.last == .buttons([Item.Button("Show \(total - PanelModel.toolsShown) more", "chevron.down",
                                                "tools_expand")]))
}

@Test func aiToolsExpandedListsEverythingWithShowLess() {
    let items = aiToolsItems([:], detected: ["claude_code"], expanded: true)
    #expect(switchActions(items).count == 1 + Providers.providers.count)
    #expect(items.last == .buttons([Item.Button("Show less", "chevron.up", "tools_expand")]))
}

@Test func aiToolsCollapsedStillShowsSwitchesThatAreOn() {
    let last = Providers.providers.last!.key
    let items = aiToolsItems(["enabled_providers": [last]], detected: ["claude_code"])
    let actions = switchActions(items)
    #expect(actions.contains("provider:\(last)"))
    #expect(actions.first == "tool:claude_code")
    #expect(actions.count == PanelModel.toolsShown)
}

@Test func toolsExpandParses() {
    #expect(AppAction.parse("tools_expand", .none) == .toolsExpand)
}
