// Text that does not fit: shrink first, then a "Read more" that opens the
// full text under the item; notes and warnings wrap instead.

import Foundation
import Testing
@testable import TrackerCore

/// 7 pt per character, whatever the size: easy to reason about.
private let measure: TextMeasure = { text, _, _ in CGFloat(text.count) * 7 }
private let long = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)  // 99 characters

private func tab(_ items: [Item], title: String? = "Card") -> Tab {
    Tab(key: "t", title: "T", short: "T", icon: "x", cards: [Card(title: title, items: items)])
}

@Test func aRowThatFitsIsLeftAlone() {
    let fit = PanelModel.fitted(tab([.row(label: "Plan", value: "Pro")]), measure: measure, open: [:])
    #expect(fit.tab.cards[0].items == [.row(label: "Plan", value: "Pro")])
    #expect(fit.ids.isEmpty)
}

@Test func aLabelThatFitsOnceShrunkGetsNoReadMore() {
    // 40 characters = 280 pt; the label's slot is 312 - 21 - 8 = 283 wide, shrunk 85% it fits.
    let label = String(repeating: "a", count: 40)
    let fit = PanelModel.fitted(tab([.row(label: label, value: "12%")]), measure: measure, open: [:])
    #expect(fit.ids.isEmpty)
}

@Test func aCutRowGetsReadMoreAndOpensToItsFullText() {
    let row = Item.row(label: long, value: "1")
    let closed = PanelModel.fitted(tab([row, .row(label: "Next", value: "2")]), measure: measure, open: [:])
    let id = "fit:t:Card:0"
    #expect(closed.ids == [id])
    #expect(closed.tab.cards[0].items == [row, .readMore(id: id, isOpen: false), .row(label: "Next", value: "2")])

    let opened = PanelModel.fitted(tab([row, .row(label: "Next", value: "2")]), measure: measure, open: [id: false])
    let items = opened.tab.cards[0].items
    #expect(items.first == row)
    #expect(items.last == .row(label: "Next", value: "2"))
    #expect(items[items.count - 2] == .readMore(id: id, isOpen: true))
    let shown = items.compactMap { item -> String? in
        if case let .note(text) = item { return text }
        return nil
    }
    #expect(shown.joined(separator: " ") == long)
    #expect(shown.allSatisfy { CGFloat($0.count) * 7 <= PanelLayout.cardInner - 1 })
}

@Test func aCutValueShowsLabelAndValue() {
    let value = String(repeating: "9", count: 40)  // 280 pt, over the 200 pt cap even shrunk
    let fit = PanelModel.fitted(tab([.row(label: "Balance", value: value)]), measure: measure,
                                open: ["fit:t:Card:0": false])
    let shown = fit.tab.cards[0].items.compactMap { item -> String? in
        if case let .note(text) = item { return text }
        return nil
    }
    #expect(shown.joined(separator: " ") == "Balance: \(value)")
}

@Test func idsDoNotDependOnTheTextSoAChangingValueStaysOpen() {
    let a = PanelModel.fitted(tab([.row(label: long, value: "1 min")]), measure: measure, open: [:])
    let b = PanelModel.fitted(tab([.row(label: long + "!", value: "2 min")]), measure: measure, open: [:])
    #expect(a.ids == b.ids)
}

@Test func aCardWithoutTitleIsKeyedByPosition() {
    let t = Tab(key: "t", title: "T", short: "T", icon: "x",
                cards: [Card(title: nil, items: []), Card(title: nil, items: [.heading(long)])])
    #expect(PanelModel.fitted(t, measure: measure, open: [:]).ids == ["fit:t:#1:0"])
}

@Test func aCutCardTitleGetsReadMoreFirst() {
    let fit = PanelModel.fitted(tab([.row(label: "a", value: "b")], title: long), measure: measure, open: [:])
    #expect(fit.tab.cards[0].items.first == .readMore(id: "fit:t:\(long):title", isOpen: false))
}

@Test func controlLabelsUseTheirOwnWidths() {
    let label = String(repeating: "b", count: 30)  // 210 pt: fits beside a switch (270), not a dropdown (164)
    let fit = PanelModel.fitted(tab([.switch(label: label, isOn: true, action: "a"),
                                     .popup(label: label, options: ["x"], selected: 0, action: "b")]),
                                measure: measure, open: [:])
    #expect(fit.ids == ["fit:t:Card:1"])
}

@Test func aNoteTooWideIsWrappedNotCut() {
    let fit = PanelModel.fitted(tab([.note(long)]), measure: measure, open: [:])
    let lines = fit.tab.cards[0].items.compactMap { item -> String? in
        if case let .note(text) = item { return text }
        return nil
    }
    #expect(lines.count > 1)
    #expect(lines.joined(separator: " ") == long)
    #expect(fit.ids.isEmpty)
}

@Test func aWarningTooWideKeepsItsIconOnTheFirstLineOnly() {
    let fit = PanelModel.fitted(tab([.alert(text: long, showIcon: true)]), measure: measure, open: [:])
    let icons = fit.tab.cards[0].items.compactMap { item -> Bool? in
        if case let .alert(_, showIcon) = item { return showIcon }
        return nil
    }
    #expect(icons.count > 1 && icons.first == true && icons.dropFirst().allSatisfy { !$0 })
}

@Test func withoutRealMeasuresNothingChanges() {
    let state: JSONObject = ["enabled_tools": ["claude_code"]]
    let result = PanelModel.buildPanelResult(Tools.toolView(state, "claude_code"), state: state, sessions: [],
                                             friends: [], showLeaderboard: false, today: Day(2026, 11, 12))
    #expect(result.rows.isEmpty)
    #expect(!result.tabs.flatMap(\.cards).flatMap(\.items).contains { $0.kind == "readmore" })
}

@Test func thePanelReturnsReadMoreIdsSoTheyStayOpen() {
    let state: JSONObject = ["enabled_tools": ["claude_code"]]
    let wide: TextMeasure = { text, _, _ in CGFloat(text.count) * 30 }
    let result = PanelModel.buildPanelResult(Tools.toolView(state, "claude_code"), state: state, sessions: [],
                                             friends: [], showLeaderboard: false, today: Day(2026, 11, 12),
                                             context: PanelContext(measure: wide))
    #expect(!result.rows.isEmpty)
    #expect(result.rows.keys.allSatisfy { $0.hasPrefix("fit:") })
}

@Test func readMoreHasItsHeight() {
    #expect(PanelLayout.height(of: .readMore(id: "x", isOpen: false)) == 16)
    #expect(Item.readMore(id: "x", isOpen: true).kind == "readmore")
}
