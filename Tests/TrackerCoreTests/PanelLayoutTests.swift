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

// foldFrame: the panel grows from, and shrinks to, the menu bar icon, with its
// contents scaled by the same factor.

private let panelWidth = PanelLayout.width

private func frames(_ unfolding: Bool, from: Double? = nil, height: CGFloat = 600, count: Int = 10)
    -> [PanelLayout.FoldFrame] {
    (0...count).map {
        PanelLayout.foldFrame(progress: Double($0) / Double(count), unfolding: unfolding,
                              fromShare: from ?? (unfolding ? 0 : 1),
                              fullSize: CGSize(width: panelWidth, height: height))
    }
}

@Test func foldFrameUnfoldsFromTheFloorToFullSize() {
    for height in [200.0, 600.0] {
        let steps = frames(true, height: CGFloat(height))
        let minScale = max(24 / Double(panelWidth), 24 / height)
        #expect(abs(steps.first!.scale - minScale) < 1e-9)
        #expect(steps.last!.scale == 1 && steps.last!.share == 1)
        #expect(steps.map(\.scale) == steps.map(\.scale).sorted())
        #expect(steps.last!.windowWidth == panelWidth && steps.last!.windowHeight == CGFloat(height))
    }
}

@Test func foldFrameNeverGoesBelowTheFloorInEitherDimension() {
    for height in [200.0, 400.0, 600.0] {
        for step in frames(false, height: CGFloat(height)) + frames(true, height: CGFloat(height)) {
            #expect(step.width >= 24 - 1e-9 && step.height >= 24 - 1e-9)
            #expect(step.windowWidth >= 24 && step.windowHeight >= 24)
        }
    }
}

@Test func foldFrameSizeRatioEqualsTheScale() {
    for step in frames(true, height: 500) + frames(false, height: 500) {
        #expect(abs(step.width / panelWidth - step.scale) < 1e-9)
        #expect(abs(step.height / 500 - step.scale) < 1e-9)
        #expect(abs(step.windowWidth - step.width) <= 0.5)
        #expect(abs(step.windowHeight - step.height) <= 0.5)
    }
}

@Test func foldFrameFoldsBackToTheFloor() {
    let steps = frames(false)
    #expect(steps.first!.scale == 1)
    #expect(abs(steps.last!.scale - max(24 / Double(panelWidth), 24 / 600)) < 1e-9 && steps.last!.share == 0)
    #expect(steps.map(\.scale) == steps.map(\.scale).sorted(by: >))
}

@Test func foldFrameSteppingIsEvenLikeFoldHeight() {
    let count = 26
    for unfolding in [true, false] {
        let widths = frames(unfolding, count: count).map(\.width)
        let steps = zip(widths, widths.dropFirst()).map { abs($1 - $0) }
        let average = steps.reduce(0, +) / CGFloat(steps.count)
        #expect(steps.max()! <= 2 * average, "unfolding: \(unfolding)")
    }
}

@Test func foldFrameReversalContinuesFromTheCurrentShare() {
    // Closing at 40% open: the fold starts where the unfold was, with no jump.
    let open = PanelLayout.foldFrame(progress: 0.4, unfolding: true, fromShare: 0,
                                     fullSize: CGSize(width: panelWidth, height: 600))
    let back = PanelLayout.foldFrame(progress: 0, unfolding: false, fromShare: open.share,
                                     fullSize: CGSize(width: panelWidth, height: 600))
    #expect(abs(back.scale - open.scale) < 1e-12 && back.windowWidth == open.windowWidth
            && back.windowHeight == open.windowHeight)
    let end = PanelLayout.foldFrame(progress: 1, unfolding: false, fromShare: open.share,
                                    fullSize: CGSize(width: panelWidth, height: 600))
    #expect(end.share == 0)
}

@Test func foldFrameClampsProgress() {
    let full = CGSize(width: panelWidth, height: 600)
    #expect(PanelLayout.foldFrame(progress: 1.7, unfolding: true, fromShare: 0, fullSize: full).scale == 1)
    #expect(PanelLayout.foldFrame(progress: -1, unfolding: true, fromShare: 0, fullSize: full)
            == PanelLayout.foldFrame(progress: 0, unfolding: true, fromShare: 0, fullSize: full))
}
