// The models card's order: by token usage, or by model tier (low to high).

import Foundation
import Testing
@testable import TrackerCore

private func total(_ name: String, _ tokens: Int) -> UsageStats.NamedTotal { UsageStats.NamedTotal(name, tokens) }

@Test func theClaudeTierTableIsLowToHighAndIsTheReverseOfTheNameList() {
    #expect(ModelTiers.claudeFamilies == ["haiku", "sonnet", "opus", "mythos", "fable"])
    // The display-name list runs high to low; the tiers must stay its mirror.
    #expect(ModelTiers.claudeFamilies == PanelModel.modelFamilies.reversed())
}

@Test func aModelIdHasTheTierOfItsFamilyWhateverItsShape() {
    #expect(ModelTiers.tier(of: "claude-haiku-4-5") == 1)
    #expect(ModelTiers.tier(of: "claude-3-5-sonnet-20241022") == 2)
    #expect(ModelTiers.tier(of: "anthropic/claude-opus-5-5") == 3)
    #expect(ModelTiers.tier(of: "claude-mythos-1") == 4)
    #expect(ModelTiers.tier(of: "claude-fable-5-2") == 5)
}

@Test func otherModelsHaveNoTier() {
    for id in ["gpt-5", "gemini-2.5-pro", "unknown", "<synthetic>", "sonnet", "deepseek-chat"] {
        #expect(ModelTiers.tier(of: id) == nil, "\(id)")
    }
}

@Test func byTokensTheOrderIsLeftAsItIs() {
    let totals = [total("claude-opus-5-5", 900), total("claude-haiku-4-5", 100), total("gpt-5", 50)]
    #expect(ModelTiers.sorted(totals, by: .tokens) == totals)
}

@Test func byTierLowFirstThenTokensAndNoTierLast() {
    let totals = [
        total("gpt-5", 5000), total("claude-fable-5-2", 400), total("claude-opus-5-5", 900),
        total("claude-opus-4-1", 1200), total("claude-haiku-4-5", 100), total("unknown", 7000),
    ]
    #expect(ModelTiers.sorted(totals, by: .tier).map(\.name) ==
        ["claude-haiku-4-5", "claude-opus-4-1", "claude-opus-5-5", "claude-fable-5-2", "unknown", "gpt-5"])
}

@Test func theStoredValueDefaultsToTokensForAMissingOrBadOne() {
    #expect(ModelTiers.order(from: nil) == .tokens)
    #expect(ModelTiers.order(from: "bogus") == .tokens)
    #expect(ModelTiers.order(from: 3) == .tokens)
    #expect(ModelTiers.order(from: "tier") == .tier)
    #expect(ModelTiers.order(from: "tokens") == .tokens)
}

private func modelsState(_ sort: Any?) -> JSONObject {
    var state: JSONObject = ["grand_total": 0]
    if let sort = sort { state["model_sort"] = sort }
    return state
}

private func modelNames(_ sort: Any?) -> [String] {
    let today = Day(2026, 7, 29)
    let daily: JSONObject = [today.iso: ["models": ["claude-opus-5-5": ["output": 900],
                                                    "claude-haiku-4-5": ["output": 100],
                                                    "claude-fable-5-2": ["output": 400]] as JSONObject] as JSONObject]
    let view = Tools.View(key: "claude_code", name: "Claude Code", daily: daily, grandTotal: 1400, error: nil)
    let tabs = PanelModel.buildPanel(view, state: modelsState(sort), sessions: [], friends: [], showLeaderboard: false,
                                     today: today)
    let models = tabs.first { $0.key == "models" }!
    return models.cards.first { $0.title == "Today" }!.items.compactMap { item in
        if case .bar(let label, _, _, _, _) = item { return label }
        return nil
    }
}

@Test func theModelsCardFollowsTheSetting() {
    let byTokens = modelNames(nil)
    #expect(byTokens.count == 3)
    #expect(byTokens.first?.contains("Opus") == true)  // 900 tokens is the most
    #expect(modelNames("bogus") == byTokens)  // a bad stored value is the default
    let byTier = modelNames("tier")
    #expect(byTier.first?.contains("Haiku") == true)
    #expect(byTier.last?.contains("Fable") == true)
}

@Test func theSettingIsAPopupAndTheActionParses() {
    let tab = PanelModel.settingsTab(["model_sort": "tier"], intervalChoices: [15], detected: [])
    let models = tab.cards.first { $0.title == "Models" }!
    #expect(!tab.cards.first { $0.title == "Appearance" }!.items.contains { $0.kind == "popup" })  // not under Appearance
    #expect(models.items.contains(.popup(label: "Sort model token usage by",
                                             options: ["Token usage", "Model, low to high"], selected: 1,
                                             action: "model_sort")))
    #expect(AppAction.parse("model_sort", .index(1)) == .modelSort("tier"))
    #expect(AppAction.parse("model_sort", .index(0)) == .modelSort("tokens"))
    #expect(AppAction.parse("model_sort", .index(9)) == nil)
}

@Test func theDefaultSelectionIsTokenUsage() {
    let tab = PanelModel.settingsTab([:], intervalChoices: [15], detected: [])
    let popup = tab.cards.first { $0.title == "Models" }!.items.first {
        if case .popup(_, _, _, "model_sort") = $0 { return true } else { return false }
    }
    #expect(popup == .popup(label: "Sort model token usage by", options: ["Token usage", "Model, low to high"],
                            selected: 0, action: "model_sort"))
}
