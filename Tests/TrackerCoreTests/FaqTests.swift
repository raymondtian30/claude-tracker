// The FAQ card: the two accepted entries, built from the app's own name tables.

import Foundation
import Testing
@testable import TrackerCore

@Test func theFaqIsTheLastCardInSettings() {
    let tab = PanelModel.settingsTab([:], intervalChoices: [15], detected: [])
    #expect(tab.cards.last?.title == "FAQ")
    #expect(tab.cards.dropLast().last?.title == "About")
}

@Test func eachEntryIsAHeadingThenWrappedNotes() {
    let items = FaqEntries.items()
    let headings = items.compactMap { item -> String? in
        if case .heading(let text) = item { return text }
        return nil
    }
    #expect(headings == ["What is Anthropic, and what is Claude Code?", "What is OpenAI, and what is Codex?"])
    #expect(items.filter { $0.kind == "note" }.count > 2)  // answers wrap onto several lines
    #expect(items.first?.kind == "heading")
}

@Test func everyNoteLineFitsTheNoteWidth() {
    for item in FaqEntries.items() {
        if case .note(let text) = item { #expect(text.count <= PanelModel.noteWidth, "\(text)") }
    }
}

@Test func theNamesComeFromTheToolAndCompanyTables() {
    let text = FaqEntries.entries.map { $0.question + " " + $0.answer }.joined(separator: " ")
    for name in [Providers.providerNames["anthropic"]!, Providers.providerNames["openai"]!,
                 Tools.toolNames["claude_code"]!, Tools.toolNames["codex"]!] {
        #expect(text.contains(name), "\(name)")
    }
}

@Test func eachToolsHomeCompanyOwnsASampleModelOfIt() {
    for pair in FaqEntries.homeCompanies {
        #expect(Tools.toolNames[pair.tool] != nil, "\(pair.tool) is a tool")
        #expect(Providers.providerNames[pair.company] != nil, "\(pair.company) is a company")
        #expect(Providers.providerOf(pair.sampleModel) == pair.company, "\(pair.sampleModel)")
    }
}

@Test func everyKindOfItemHasAHeightOrItDrawsAtZero() {
    let samples: [Item] = [
        .tiles([]), .chart(values: [], caption: ""), .bar(label: "", value: "", fraction: 0), .row(label: "", value: ""),
        .note(""), .buttons([]), .segmented(label: nil, options: [], selected: 0, action: ""),
        .popup(label: nil, options: [], selected: 0, action: ""), .switch(label: "", isOn: false, action: ""),
        .rangePicker(from: Day(2026, 1, 1), to: Day(2026, 1, 2), earliest: Day(2026, 1, 1), latest: Day(2026, 1, 2)),
        .alert(text: "", showIcon: false), .tags([]), .choices(label: nil, options: [], selected: [], action: ""),
        .heading(""),
    ]
    for item in samples {
        #expect(PanelLayout.heights[item.kind] != nil, "\(item.kind) has no height")
    }
}
