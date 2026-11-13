import Foundation

/// The panel's sizes and the arithmetic behind them, kept free of AppKit so
/// it can be unit-tested. The app's views (ClaudeTracker/Panel) draw with
/// these numbers, and the panel controller sizes the popover from them, so
/// the two always agree.
///
/// Ported from panel_view.py, which laid the panel out by hand. Every
/// height here is a y offset there.
public enum PanelLayout {
    public static let width: CGFloat = 360
    public static let pad: CGFloat = 12  // outer padding
    public static let cardPad: CGFloat = 12  // padding inside a card
    public static let gap: CGFloat = 10  // space between cards
    public static let corner: CGFloat = 10
    /// The width inside the outer padding: what cards span.
    public static let inner: CGFloat = width - 2 * pad

    public static let heights: [String: CGFloat] = [
        "tiles": 66,
        "chart": 84,
        "bar": 36,
        "row": 22,
        "note": 16,
        "buttons": 32,
        "segmented": 30,
        "popup": 30,
        "switch": 30,
        "rangepicker": 264,
        "alert": 17,
        "tags": 22,
        "choices": 52,
        "heading": 22,
        "readmore": 16,
    ]
    public static let cardTitleHeight: CGFloat = 24
    public static let screenMargin: CGFloat = 40  // keep the panel this far from the bottom of the screen

    public static let foldedHeight: CGFloat = 24  // how tall the panel is when fully folded
    public static let animationFPS: Double = 60  // only where there's no display link (before macOS 14)
    public static let tabFadeSeconds: Double = 0.15  // a newly picked tab fades in this fast

    // The panel's parts, top to bottom.
    public static let headerHeight: CGFloat = 42  // logo, title and subtitle
    public static let toolPickerHeight: CGFloat = 30 + 2  // a popup row, plus a little air
    public static let tabBarHeight: CGFloat = 44  // icons and captions; a 1 pt hairline follows
    public static let contentGap: CGFloat = 12  // between the tab bar and the first card
    public static let bareTilesHeight: CGFloat = 58  // a card of tiles alone, drawn without its box
    public static let footerHeight: CGFloat = 9 + 24  // hairline and space, then the footer's row
    public static let welcomeTitleHeight: CGFloat = 32

    /// The header's mark when there's no logo for the selected AI.
    public static let coin = "🪙"

    /// The footer's icon buttons: (SF Symbol, tooltip, action).
    public static let footerButtons: [(icon: String, tip: String, action: String)] = [
        ("slider.horizontal.3", "Settings", "open_settings"),
        ("xmark.circle", "Quit", "quit"),
    ]

    public static let settingsWindowTitle = "\(Version.appName) Settings"

    /// The panel's height `progress` (0-1) of the way through unfolding to
    /// `fullHeight`, or folding from it. Both ease in and out (a half cosine):
    /// a sharper curve front-loads the motion, and its first frames jumped by
    /// over 100 points, which looked choppy.
    public static func foldHeight(_ progress: Double, _ fullHeight: CGFloat, unfolding: Bool) -> CGFloat {
        let eased = easedProgress(progress)
        let share = unfolding ? eased : 1 - eased
        // Python's round() rounds halves to even.
        return (foldedHeight + (fullHeight - foldedHeight) * CGFloat(share)).rounded(.toNearestOrEven)
    }

    /// `progress` (0-1, clamped) eased in and out by a half cosine.
    private static func easedProgress(_ progress: Double) -> Double {
        (1 - cos(Double.pi * min(max(progress, 0.0), 1.0))) / 2
    }

    public static let foldedWidth: CGFloat = 24  // how wide the panel is when fully shrunk

    /// The panel at one moment of growing from or shrinking into the menu bar
    /// icon: its contents are scaled by `scale`, and the window around them is
    /// `width` by `height` (`windowWidth` by `windowHeight`, rounded, is what
    /// the popover gets).
    public struct FoldFrame: Equatable {
        public let share: Double  // 0 = fully shrunk, 1 = full size
        public let scale: Double
        public let width: CGFloat
        public let height: CGFloat
        public let windowWidth: CGFloat
        public let windowHeight: CGFloat
    }

    /// The panel `progress` (0-1) of the way through unfolding to `fullSize`,
    /// or folding from it, starting from `fromShare` (1 when fully open, 0
    /// when fully shrunk, or where an animation was when it was reversed).
    /// The scale is one number for both dimensions, so the contents shrink
    /// evenly; it never goes below the one that leaves the panel
    /// `foldedWidth` by `foldedHeight`. The eased `share` is what to pass as
    /// `fromShare` next time.
    public static func foldFrame(progress: Double, unfolding: Bool, fromShare: Double,
                                 fullSize: CGSize) -> FoldFrame {
        let eased = easedProgress(progress)
        let from = min(max(fromShare, 0.0), 1.0)
        let share = unfolding ? from + (1 - from) * eased : from * (1 - eased)
        let minScale = max(Double(foldedWidth / fullSize.width), Double(foldedHeight / fullSize.height))
        let scale = minScale + (1 - minScale) * share
        let width = fullSize.width * CGFloat(scale)
        let height = fullSize.height * CGFloat(scale)
        // Python's round() rounds halves to even.
        return FoldFrame(share: share, scale: scale, width: width, height: height,
                         windowWidth: width.rounded(.toNearestOrEven),
                         windowHeight: height.rounded(.toNearestOrEven))
    }

    /// How tall the panel is: its content, capped so it fits on screen
    /// (anything beyond scrolls).
    public static func panelHeight(_ contentHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        min(contentHeight, screenHeight - screenMargin)
    }

    // MARK: - Cards

    /// The grey line under a bar that has a `sub`.
    public static let barSubHeight: CGFloat = 14

    public static func height(of item: Item) -> CGFloat {
        let base = heights[item.kind] ?? 0
        if case let .bar(_, _, _, sub, _) = item, sub != nil { return base + barSubHeight }
        return base
    }

    /// Whether a label's text is wider than its slot and would be cut off
    /// (the last point is kept as air, so a text exactly the budget wide is cut).
    public static func isCutOff(text: String, size: CGFloat, weight: LabelWeight, budget: CGFloat,
                                measure: TextMeasure) -> Bool {
        measure(text, size, weight) > budget - 1
    }

    /// The room a status dot takes before a row's label.
    public static let dotWidth: CGFloat = 14

    // MARK: - Fitting text

    /// How small a label may shrink to fit its slot before it is cut off
    /// (and gets a "Read more"): 85% of its size.
    public static let minTextScale: CGFloat = 0.85
    /// The width inside a card: what its items span.
    public static let cardInner: CGFloat = inner - 2 * cardPad
    /// A row's or bar's value takes the width it needs, up to this; the
    /// label gets the rest of the line.
    public static let valueCap: CGFloat = 200
    /// Space kept between a row's label and its value.
    public static let valueGap: CGFloat = 8
    /// Label widths beside controls: a switch (34 wide), a dropdown (140
    /// wide), or segments (after a 90 pt label).
    public static let switchLabelWidth: CGFloat = cardInner - 34 - 8
    public static let popupLabelWidth: CGFloat = cardInner - 140 - 8
    public static let segmentedLabelWidth: CGFloat = 90 - 4
    /// A warning line's text, after its icon (16) and the gap (6).
    public static let alertTextWidth: CGFloat = cardInner - 22

    /// Whether `text` is wider than `width` even shrunk to `minTextScale`
    /// (the last point is kept as air).
    public static func isCutEvenShrunk(_ text: String, size: CGFloat, weight: LabelWeight, width: CGFloat,
                                       measure: TextMeasure) -> Bool {
        measure(text, size, weight) * minTextScale > width - 1
    }

    /// The (label, value) widths of a row or bar: the value as wide as it
    /// needs up to `valueCap`, the label the rest (less a dot, if any).
    public static func labelValueWidths(label: String, value: String, valueWeight: LabelWeight, hasDot: Bool,
                                        measure: TextMeasure) -> (label: CGFloat, value: CGFloat) {
        let value = Swift.min(measure(value, 13, valueWeight), valueCap)
        return (cardInner - (hasDot ? dotWidth : 0) - value - valueGap, value)
    }

    /// Tiles are already boxes, so a card holding only tiles (and no title)
    /// is drawn without the card around them.
    public static func isBareTiles(_ card: Card) -> Bool {
        card.title == nil && card.items.map(\.kind) == ["tiles"]
    }

    /// A card's height, box and padding included.
    public static func cardHeight(_ card: Card) -> CGFloat {
        if isBareTiles(card) { return bareTilesHeight }
        var height = cardPad * 2
        if card.title != nil { height += cardTitleHeight }
        return height + card.items.map(height(of:)).reduce(0, +)
    }

    /// Cards stacked with a gap after each one.
    public static func cardsHeight(_ cards: [Card]) -> CGFloat {
        cards.map { cardHeight($0) + gap }.reduce(0, +)
    }

    // MARK: - The whole panel

    /// Where a tab's content starts: under the header, the tool picker (if
    /// shown) and the tab bar.
    public static func contentTop(hasToolPicker: Bool) -> CGFloat {
        pad + headerHeight + (hasToolPicker ? toolPickerHeight : 0) + tabBarHeight + 1 + contentGap
    }

    /// A tab's cards and the footer under them.
    public static func tabContentHeight(_ tab: Tab) -> CGFloat {
        cardsHeight(tab.cards) + footerHeight
    }

    /// The panel's full height showing `tab` (before capping to the screen).
    public static func panelContentHeight(_ tab: Tab, hasToolPicker: Bool) -> CGFloat {
        contentTop(hasToolPicker: hasToolPicker) + tabContentHeight(tab) + pad
    }

    /// The first-run picker: the header, then a title over the tab's cards.
    public static func welcomeHeight(_ tab: Tab) -> CGFloat {
        pad + headerHeight + welcomeTitleHeight + cardsHeight(tab.cards) + pad
    }

    /// The Settings window's content: its cards, padded all round.
    public static func settingsHeight(_ tab: Tab) -> CGFloat {
        pad + cardsHeight(tab.cards) + pad - gap
    }

    /// The tool switcher, shown when there are 2+ tools: a dropdown of at
    /// most `trackingVisibleCount` AIs, then "Show more…" (a window with every
    /// AI) when there are more. `choices` are (key, name).
    public static func toolPicker(_ choices: [(key: String, name: String)], selected: String?) -> Item? {
        guard choices.count >= 2 else { return nil }
        let entries = trackingEntries(choices, selected: selected)
        let names = Dictionary(choices.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        let shown = choices.contains { $0.key == selected } ? selected : choices[0].key
        let index = entries.firstIndex { $0 == shown } ?? 0
        return .popup(label: "Tracking", options: entries.map { $0.flatMap { names[$0] } ?? trackingShowMoreTitle },
                      selected: index, action: "select_tool")
    }

    /// How many AIs the Tracking dropdown lists before "Show more…" ("All AIs" counts as one).
    public static let trackingVisibleCount = 7
    public static let trackingShowMoreTitle = "Show more…"

    /// The Tracking dropdown's entries in order: AI keys, and nil for "Show
    /// more…". Up to 7 choices: all of them. More: the first 7, with the
    /// selected AI in the 7th place when it comes later (so the dropdown can
    /// show it), then nil.
    public static func trackingEntries(_ choices: [(key: String, name: String)], selected: String?) -> [String?] {
        let keys = choices.map(\.key)
        guard keys.count > trackingVisibleCount else { return keys }
        var shown = Array(keys.prefix(trackingVisibleCount))
        if let selected = selected, keys.contains(selected), !shown.contains(selected) {
            shown[trackingVisibleCount - 1] = selected
        }
        return shown + [nil]
    }

    /// What a pick of entry `index` in the Tracking dropdown means.
    public enum TrackingPick: Equatable {
        case select(String)
        case showMore
    }

    /// The meaning of a pick in the dropdown that `toolPicker` built from
    /// the same `choices` and `selected`; nil for an index it doesn't have.
    public static func trackingPick(index: Int, choices: [(key: String, name: String)],
                                    selected: String?) -> TrackingPick? {
        let entries = trackingEntries(choices, selected: selected)
        guard entries.indices.contains(index) else { return nil }
        return entries[index].map(TrackingPick.select) ?? .showMore
    }

    /// The title of the window that lists every AI.
    public static let trackingWindowTitle = "Choose an AI"

    /// Whether a click in this app's `window` should close the panel: not in
    /// the panel itself, and not on the menu bar icon, whose own click
    /// toggles the panel (closing here first would make it reopen).
    /// `partOfPanel` says whether a window belongs to the panel, like the
    /// pop-up of a date field: a click in it is a click in the panel.
    public static func clickCloses<Window: AnyObject>(_ window: Window?, panel: Window?, statusItem: Window?,
                                                      partOfPanel: (Window) -> Bool = { _ in false }) -> Bool {
        guard let window = window else { return false }
        return window !== panel && window !== statusItem && !partOfPanel(window)
    }

    /// Whether a window class is a pop-over's (`_NSPopoverWindow`), such as the
    /// pop-up a date field opens.
    public static func isPopoverWindowClass(_ name: String) -> Bool {
        name.contains("PopoverWindow")
    }

    /// The NSAppearance name for an appearance setting; nil ("auto")
    /// follows macOS, switching with it.
    public static func appearanceName(_ key: String) -> String? {
        ["light": "NSAppearanceNameAqua", "dark": "NSAppearanceNameDarkAqua"][key]
    }
}

/// Which tab the panel shows. Kept apart from the views so the rules can be
/// tested: a render keeps the selected tab if it's still there, and every
/// opening starts on the first tab (Home).
public struct TabSelection {
    public private(set) var keys: [String] = []
    public private(set) var selected: String

    public init(selected: String = "overview") {
        self.selected = selected
    }

    /// New tabs from a render. Falls back to the first tab if the selected
    /// one is gone (e.g. Settings, which moved to its own window).
    public mutating func update(keys: [String]) {
        self.keys = keys
        if !keys.contains(selected), let first = keys.first {
            selected = first
        }
    }

    /// Selects the tab at `index`. True if that changed the selection.
    @discardableResult
    public mutating func select(_ index: Int) -> Bool {
        guard keys.indices.contains(index), keys[index] != selected else { return false }
        selected = keys[index]
        return true
    }

    /// Back to the first tab (Home). True if that changed the selection.
    @discardableResult
    public mutating func goHome() -> Bool {
        select(0)
    }

    public var selectedIndex: Int? { keys.firstIndex(of: selected) }
}

/// Each tab's built content, kept until new data arrives: switching tabs
/// only swaps views, and going back to a tab doesn't rebuild it.
public struct TabViewCache<View> {
    private var views: [String: View] = [:]

    public init() {}

    /// The view for `key`, built by `build` the first time it's asked for.
    public mutating func view(for key: String, build: () -> View) -> View {
        if let view = views[key] { return view }
        let view = build()
        views[key] = view
        return view
    }

    /// Forget every view (a render with new data).
    public mutating func removeAll() {
        views = [:]
    }
}

/// What a control hands back with its action: nothing (a button), the
/// picked index (segmented, popup), the picked indexes (choices), or on/off
/// (a switch). AppController.handle(action:value:) reads it.
public enum ActionValue: Equatable {
    case none
    case index(Int)
    case indices([Int])
    case bool(Bool)
    /// A date field's new date, as "2026-07-29".
    case text(String)
}
