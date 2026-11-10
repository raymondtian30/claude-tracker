import Foundation

// What the panel shows, as plain data. PanelModel builds it; the app's
// SwiftUI views draw it, one view per `Item` case.
//
// A panel is a list of tabs; each tab has cards; each card has items. These
// mirror the Python tuples of stats_tabs.py field for field, so the ported
// tests can assert on them the same way. Actions are strings the app
// handles in AppController.handle(action:value:).
//
// SwiftUI (macOS 15 SDK) also declares a `Tab`. In the app target, write
// `typealias Tab = TrackerCore.Tab` once: a module's own names win over
// imported ones.

/// One tab of the panel.
public struct Tab: Equatable {
    public var key: String
    public var title: String
    /// The tab bar's caption under the icon.
    public var short: String
    /// SF Symbol name.
    public var icon: String
    public var cards: [Card]

    public init(key: String, title: String, short: String, icon: String, cards: [Card]) {
        self.key = key
        self.title = title
        self.short = short
        self.icon = icon
        self.cards = cards
    }
}

/// A rounded box on a tab, with an optional title over its items.
public struct Card: Equatable {
    public var title: String?
    public var items: [Item]

    public init(title: String?, items: [Item]) {
        self.title = title
        self.items = items
    }
}

/// What a bar or row label can carry beyond its text: a grey tail, a
/// chevron that opens a detail (`expandID`), and a tooltip.
public struct LabelExtras: Equatable {
    public var greyTail: String?
    public var expandID: String?
    public var isOpen: Bool
    public var tip: String?

    public init(greyTail: String? = nil, expandID: String? = nil, isOpen: Bool = false, tip: String? = nil) {
        self.greyTail = greyTail
        self.expandID = expandID
        self.isOpen = isOpen
        self.tip = tip
    }

    public static let none = LabelExtras()
}

/// One line (or block) inside a card.
public enum Item: Equatable {
    /// Big numbers side by side.
    case tiles([Tile])
    /// Line chart, oldest first, with a caption above it.
    /// `labels` name each value (a date) for hovering over the chart.
    case chart(values: [Int], caption: String, labels: [String] = [])
    /// Label and value over a 0-1 bar.
    /// `sub`: an optional grey line under the bar.
    case bar(label: String, value: String, fraction: Double, sub: String? = nil, extras: LabelExtras = .none)
    case row(label: String, value: String, extras: LabelExtras = .none)
    /// Small grey line.
    case note(String)
    case buttons([Button])
    /// One choice from a row of segments. `label` nil: full width.
    case segmented(label: String?, options: [String], selected: Int, action: String)
    case popup(label: String?, options: [String], selected: Int, action: String)
    case `switch`(label: String, isOn: Bool, action: String)
    /// Two date fields, "From" and "To" (actions chart_from and chart_to).
    /// Neither can be picked before `earliest` or after `latest`.
    case dateRange(from: Day, to: Day, earliest: Day, latest: Day)
    /// One line of a warning, in orange; the first line shows an icon.
    case alert(text: String, showIcon: Bool)
    /// Small rounded labels; off ones are crossed out.
    case tags([Tag])
    /// A label over a row of segments, any number of them on.
    case choices(label: String?, options: [String], selected: [Int], action: String)

    /// A big number with its label and an optional SF Symbol.
    public struct Tile: Equatable {
        public var label: String
        public var value: String
        public var icon: String?

        public init(_ label: String, _ value: String, _ icon: String?) {
            self.label = label
            self.value = value
            self.icon = icon
        }
    }

    public struct Button: Equatable {
        public var title: String
        /// SF Symbol name.
        public var icon: String?
        public var action: String

        public init(_ title: String, _ icon: String?, _ action: String) {
            self.title = title
            self.icon = icon
            self.action = action
        }
    }

    public struct Tag: Equatable {
        public var text: String
        public var isOn: Bool

        public init(_ text: String, _ isOn: Bool) {
            self.text = text
            self.isOn = isOn
        }
    }

    /// The Python tuple's first field ("tiles", "bar", ...): handy in
    /// tests and for looking up each kind's height.
    public var kind: String {
        switch self {
        case .tiles: return "tiles"
        case .chart: return "chart"
        case .bar: return "bar"
        case .row: return "row"
        case .note: return "note"
        case .buttons: return "buttons"
        case .segmented: return "segmented"
        case .popup: return "popup"
        case .switch: return "switch"
        case .dateRange: return "daterange"
        case .alert: return "alert"
        case .tags: return "tags"
        case .choices: return "choices"
        }
    }
}
