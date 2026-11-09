// Port of tests/test_panel_layout.py.
//
// The Python tests built the real AppKit panel and searched its views. Here
// the panel's rules live in TrackerCore (PanelLayout, TabSelection,
// TabViewCache), which these tests check; the AppKit and SwiftUI drawing
// is in the app target, which this test target can't import, and is
// checked by eye in the running app instead. Each test says which part
// that is.

import Foundation
import Testing
@testable import TrackerCore

private let tab = Tab(key: "overview", title: "Overview", short: "Home", icon: "square.grid.2x2",
                      cards: [Card(title: nil, items: [.note("hi")])])

@Test func shortContentUsesItsOwnHeight() {
    #expect(PanelLayout.panelHeight(500, screenHeight: 800) == 500)
}

@Test func tallContentIsCappedToTheScreen() {
    #expect(PanelLayout.panelHeight(900, screenHeight: 800) == 800 - PanelLayout.screenMargin)
}

// The dropdown itself (one NSPopUpButton, no segmented control) is drawn
// by the app's PanelChromeView from this item.
@Test func toolSwitcherIsADropdown() {
    let picker = PanelLayout.toolPicker(
        [("claude_code", "Claude Code"), ("codex", "Codex"), ("opencode", "opencode")], selected: "codex")

    #expect(picker == .popup(label: "Tracking", options: ["Claude Code", "Codex", "opencode"],
                             selected: 1, action: "select_tool"))
    #expect(PanelLayout.toolPicker([("claude_code", "Claude Code")], selected: "claude_code") == nil)
}

// The footer's buttons fire these actions through the panel's on_action;
// the button views are AppKit (checked in the running app).
@Test func settingsButtonAsksTheAppToOpenTheSettingsWindow() {
    let settings = PanelLayout.footerButtons.first { $0.tip == "Settings" }
    #expect(settings?.action == "open_settings")

    var selection = TabSelection()
    selection.update(keys: ["overview"])
    #expect(selection.selected == "overview")  // the popover itself doesn't change
}

@Test func popoverNoLongerShowsSettingsInline() {
    var selection = TabSelection(selected: "settings")

    selection.update(keys: [tab.key])

    #expect(selection.selected == "overview")
}

// Only the window title is portable: the cards and the switch's action are
// drawn by the app's SettingsWindow with the panel's own card views.
@Test func settingsWindowDrawsTheSettingsCards() {
    #expect(PanelLayout.settingsWindowTitle == "Claude Tracker Settings")
    let settings = Tab(key: "settings", title: "Settings", short: "Settings", icon: "gear",
                       cards: [Card(title: "AI tools", items: [.switch(label: "Codex", isOn: true, action: "tool:codex")])])
    // Padding 12, then the card (24 padding + 24 title + 30 switch), then 12.
    let expected: CGFloat = 102
    #expect(PanelLayout.settingsHeight(settings) == expected)
}

// Not ported: testHeaderShowsTheSelectedAIsLogoInsteadOfTheCoin and
// testHeaderKeepsTheCoinWithoutALogo check NSImageViews in the AppKit
// header. The app's PanelHeaderView shows `logo` when given, else
// PanelLayout.coin; checked by eye with and without a logo.
@Test func headerKeepsTheCoinWithoutALogo() {
    #expect(PanelLayout.coin == "🪙")
}

@Test func clickingTheMenuBarIconIsLeftToTheIconToToggle() {
    // The icon's own click closes an open panel. If the outside-click
    // monitor closed it first, the icon's toggle would just reopen it.
    final class Window {}
    let statusWindow = Window(), settingsWindow = Window(), panelWindow = Window()

    #expect(!PanelLayout.clickCloses(statusWindow, panel: panelWindow, statusItem: statusWindow))
    #expect(!PanelLayout.clickCloses(panelWindow, panel: panelWindow, statusItem: statusWindow))
    #expect(PanelLayout.clickCloses(settingsWindow, panel: panelWindow, statusItem: statusWindow))
}

@Test func animationSpeeds() {
    #expect(PanelSpeeds.animationSpeeds.map { "\($0.key) \($0.label) \($0.seconds)" }
            == ["off Off 0.0", "fast Fast 0.12", "normal Normal 0.22", "slow Slow 0.4"])
}

@Test func unfoldingGrowsFromAStripToFullHeight() {
    let heights = (0...10).map { PanelLayout.foldHeight(Double($0) / 10, 600, unfolding: true) }

    #expect(heights.first == PanelLayout.foldedHeight)
    #expect(heights.last == 600)
    #expect(heights == heights.sorted())
}

@Test func noFrameJumpsMuchMoreThanTheAverage() {
    // Big jumps in the first frames looked choppy: the motion eases in and
    // out, so no step is more than twice the average one.
    let frames = 26  // 0.22 s at 120 Hz
    for unfolding in [true, false] {
        let heights = (0...frames).map { PanelLayout.foldHeight(Double($0) / Double(frames), 600, unfolding: unfolding) }
        let steps = zip(heights, heights.dropFirst()).map { abs($1 - $0) }
        let average = steps.reduce(0, +) / CGFloat(steps.count)
        #expect(steps.max()! <= 2 * average, "unfolding: \(unfolding)")
        #expect(steps[0] <= steps[frames / 2] && steps.last! <= steps[frames / 2])
    }
}

@Test func foldingShrinksBackToTheStrip() {
    let heights = (0...10).map { PanelLayout.foldHeight(Double($0) / 10, 600, unfolding: false) }

    #expect(heights.first == 600)
    #expect(heights.last == PanelLayout.foldedHeight)
    #expect(heights == heights.sorted(by: >))
}

@Test func progressPastTheEndIsClamped() {
    #expect(PanelLayout.foldHeight(1.7, 600, unfolding: true) == 600)
    #expect(PanelLayout.foldHeight(-1, 600, unfolding: true) == PanelLayout.foldHeight(0, 600, unfolding: true))
}

@Test func openingThePanelGoesBackToHome() {
    var selection = TabSelection()
    selection.update(keys: ["overview", "limits"])
    selection.select(1)
    #expect(selection.selected == "limits")

    selection.goHome()

    #expect(selection.selected == "overview")
}

// The Python test also checked the views' superview and alpha; in the app,
// PanelController keeps its tab views in this cache and swaps them.
@Test func switchingTabsReusesEachTabsViews() {
    final class View {}
    var cache = TabViewCache<View>()
    var built = 0
    let make = { () -> View in built += 1; return View() }

    let home = cache.view(for: "overview", build: make)
    let limits = cache.view(for: "limits", build: make)
    let homeAgain = cache.view(for: "overview", build: make)

    #expect(homeAgain === home)
    #expect(limits !== home)
    #expect(built == 2)
}

@Test func newDataRebuildsTheTabs() {
    final class View {}
    var cache = TabViewCache<View>()
    let before = cache.view(for: "overview") { View() }

    cache.removeAll()  // what a render does

    #expect(cache.view(for: "overview") { View() } !== before)
}

// The Python test set NSApplication's appearance; the app's
// Appearance.apply does that with these names.
@Test func appearanceFollowsTheSetting() {
    #expect(PanelLayout.appearanceName("dark") == "NSAppearanceNameDarkAqua")
    #expect(PanelLayout.appearanceName("light") == "NSAppearanceNameAqua")
    #expect(PanelLayout.appearanceName("auto") == nil)  // follows macOS
}

// Swift-only: the heights the controller sizes the popover with add up the
// way panel_view.py's y offsets did.
@Test func panelHeightAddsUpLikeThePythonLayout() {
    // pad 12 + header 42 + tab bar 45 + 12, then a card (24 + note 16) and
    // a gap, then the footer (33) and the bottom pad.
    #expect(PanelLayout.contentTop(hasToolPicker: false) == 111)
    #expect(PanelLayout.contentTop(hasToolPicker: true) == 143)
    let expected: CGFloat = 111 + 40 + 10 + 33 + 12
    #expect(PanelLayout.panelContentHeight(tab, hasToolPicker: false) == expected)
    let tiles = Card(title: nil, items: [.tiles([Item.Tile("Today", "1", nil)])])
    #expect(PanelLayout.cardHeight(tiles) == 58)
    let titled: CGFloat = 24 + 24 + 66
    #expect(PanelLayout.cardHeight(Card(title: "T", items: [.tiles([])])) == titled)
}

@Test func barHeightWithAndWithoutSub() {
    #expect(PanelLayout.height(of: .bar(label: "a", value: "1%", fraction: 0.1)) == 36)
    #expect(PanelLayout.height(of: .bar(label: "a", value: "1%", fraction: 0.1, sub: "Resets Nov 20")) == 50)
}

@Test func labelBudgetPlainAndWithChevron() {
    #expect(PanelLayout.labelBudget(kind: "bar", hasChevron: false) == 192)
    #expect(PanelLayout.labelBudget(kind: "bar", hasChevron: true) == 178)
    #expect(PanelLayout.labelBudget(kind: "row", hasChevron: false) == 202)
    #expect(PanelLayout.labelBudget(kind: "row", hasChevron: true) == 188)
}
