import Foundation

/// What the panel shows, as plain data (ported from stats_tabs.py). The
/// app's SwiftUI views draw it.
///
/// `buildPanel` returns a list of tabs (`Tab`: key, title, short tab-bar
/// caption, SF Symbol icon, cards). Each card has an optional title and
/// items; the item kinds are the `Item` cases in PanelItems.swift, which
/// mirror the Python tuples:
///
///     ("tiles", [(label, value, icon), ...])     big numbers side by side
///     ("chart", [tokens, ...], caption)           line chart, oldest first
///     ("bar", label, value, fraction)             label/value over a 0-1 bar
///     ("row", label, value)
///     ("note", text)                              small grey line
///     ("buttons", [(title, icon, action), ...])
///     ("segmented", label, [option, ...], selected_index, action)
///     ("popup", label, [option, ...], selected_index, action)
///     ("switch", label, is_on, action)
///     ("alert", text, show_icon)                  one line of a warning
///     ("tags", [(text, is_on), ...])              small rounded labels; off ones crossed out
///     ("choices", label, [option, ...], [selected_index, ...], action)  pick any number
///
/// Actions are strings the app handles in AppController.handle(action:value:).
///
/// Kept free of AppKit so it can be unit-tested. The tabs themselves are in
/// PanelModel+Tabs.swift, Settings and the first-run picker in
/// PanelModel+Settings.swift, and Python's `textwrap.wrap` in
/// PanelModel+TextWrap.swift.
public enum PanelModel {
    public static let categoryLabels: [(key: String, label: String)] = [
        ("input", "Input"),
        ("output", "Output"),
        ("cache_write", "Cache write"),
        ("cache_read", "Cache read"),
    ]

    public static let modelFamilies = ["fable", "mythos", "opus", "sonnet", "haiku"]

    public static let titleModes: [(key: String, label: String)] = [
        ("lifetime", "Lifetime"), ("today", "Today"), ("icon", "Icon only"),
    ]
    public static let leaderboardViews: [(key: String, label: String)] = [
        ("total", "Total"), ("day", "Yesterday"),
    ]
    public static let chartRanges = [1, 7, 14, 30]
    public static let defaultChartDays = 14

    /// How many days the Home chart shows: 1, 7, 14 or 30 (anything else reads as 14).
    public static func chartDays(from state: JSONObject) -> Int {
        guard let value = state["chart_days"], JSON.isInteger(value), let days = JSON.int(value),
              chartRanges.contains(days)
        else { return defaultChartDays }
        return days
    }

    /// What the Home chart covers.
    public enum ChartRange: Equatable {
        /// The last N days, ending today.
        case days(Int)
        /// From the first day with usage (or today, if none) to today.
        case allTime(from: Day)
        /// The two days picked, both included, in order and not after today.
        case custom(from: Day, to: Day)
    }

    /// The saved range choice (`chart_mode`: "days", "all" or "custom"); a
    /// custom range whose dates can't be read, and any other value, read as
    /// the last `chartDays` days. A custom range stays between the first day
    /// with usage (`earliest`) and today.
    public static func chartRange(from state: JSONObject, today: Day, earliest: Day?) -> ChartRange {
        switch state.string("chart_mode") {
        case "all":
            return .allTime(from: Swift.min(earliest ?? today, today))
        case "custom":
            guard let from = state.string("chart_from").flatMap({ Day(iso: $0) }),
                  let to = state.string("chart_to").flatMap({ Day(iso: $0) })
            else { break }
            let low = Swift.min(earliest ?? Day.min, today)
            // Entirely before the first usage (a mistyped year): an empty
            // chart is no use, so the last 30 days.
            if to < low {
                return .custom(from: Swift.max(today.adding(days: -29), low), to: today)
            }
            let (a, b) = (Swift.min(Swift.max(from, low), today), Swift.min(Swift.max(to, low), today))
            return .custom(from: Swift.min(a, b), to: Swift.max(a, b))
        default:
            break
        }
        return .days(chartDays(from: state))
    }

    /// The currency prices are shown in (an unknown or wrong-typed one reads as dollars).
    public static func currency(from state: JSONObject) -> String {
        guard let code = state.string("currency"), Pricing.currencies.contains(where: { $0.code == code })
        else { return "USD" }
        return code
    }
    public static let menuBarFontSizes = [10, 11, 12, 13, 14]
    public static let defaultMenuBarFontSize = 12
    public static let noteWidth = 46  // characters that fit on one note line

    public static let alertWidth = 40  // characters per warning line (it's indented for its icon)
    public static let tagLineChars = 48  // characters of tags that fit on one line
    public static let tagSpace = 4  // a tag's padding and the gap after it, in characters

    public static let projectsShown = 5  // before "Show more"
    public static let toolsShown = 8  // Settings > AI tools switches before "Show more"

    // MARK: - Small helpers

    /// A note too long for one line, as several note items.
    public static func noteLines(_ text: String) -> [Item] {
        wrap(text, width: noteWidth).map { .note($0) }
    }

    /// A warning as alert items; the icon is on line one.
    public static func alertLines(_ text: String) -> [Item] {
        wrap(text, width: alertWidth).enumerated().map { .alert(text: $0.element, showIcon: $0.offset == 0) }
    }

    static func ordinalSuffix(_ day: Int) -> String {
        if (11...13).contains(day % 100) {
            return "th"
        }
        return [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
    }

    /// strftime's "%B" in the C locale Python uses.
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]

    /// '2026-11-07' -> 'November 7th, 2026'. Python raises on a malformed
    /// date; here it comes back unchanged.
    public static func formatLongDate(_ isoDate: String) -> String {
        guard let parsed = Day(iso: isoDate) else { return isoDate }
        return "\(monthNames[parsed.month - 1]) \(parsed.day)\(ordinalSuffix(parsed.day)), \(parsed.year)"
    }

    /// Day(2026, 11, 7) -> 'Nov 7th'.
    public static func formatShortDate(_ day: Day) -> String {
        "\(Limits.monthAbbreviations[day.month - 1]) \(day.day)\(ordinalSuffix(day.day))"
    }

    public static func formatInterval(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) second" + (seconds == 1 ? "" : "s")
        }
        let minutes = seconds / 60
        return "\(minutes) minute" + (minutes == 1 ? "" : "s")
    }

    /// 'claude-opus-5-5' -> 'Opus 5.5', 'claude-haiku-4-5-20251001' -> 'Haiku 4.5',
    /// or the display name from a BYOK catalog (e.g. 'gemini-4-argon' -> 'Gemini 4 Argon').
    public static func modelDisplayName(_ modelId: String, catalog: [String: JSONObject] = [:]) -> String {
        if let name = catalog[modelId]?.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let parts = modelId.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "claude", modelFamilies.contains(parts[1]) else {
            return modelId
        }
        let version = parts.dropFirst(2).filter { isDigits($0) && $0.unicodeScalars.count <= 2 }
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst().lowercased()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }

    /// Python's `str.isdigit()`.
    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            $0.properties.numericType == .decimal || $0.properties.numericType == .digit
        }
    }

    public static func mergeCacheWrites(_ categories: [String: Int]) -> [String: Int] {
        var merged = categories
        let write5m = merged.removeValue(forKey: "cache_write_5m") ?? 0
        let write1h = merged.removeValue(forKey: "cache_write_1h") ?? 0
        merged["cache_write"] = write5m + write1h
        return merged
    }

    public static func percent(_ part: Int, _ whole: Int) -> String {
        if whole == 0 || part == 0 {
            return "0%"
        }
        let share = Double(part) / Double(whole) * 100
        return share < 1 ? "<1%" : String(format: "%.0f%%", share)
    }

    static func fraction(_ part: Int, _ whole: Int) -> Double {
        whole != 0 ? Double(part) / Double(whole) : 0.0
    }

    static func shareBar(_ label: String, _ count: Int, _ whole: Int, tip: String? = nil) -> Item {
        .bar(label: label, value: "\(TokenMath.formatCount(count)) · \(percent(count, whole))",
             fraction: fraction(count, whole), extras: tip.map { LabelExtras(tip: $0) } ?? .none)
    }

    /// Python's `value in options` and `options.index(value)` on JSON
    /// values (so 60 matches 60.0, as in Python); nil when it isn't there.
    static func index(of value: Any?, in options: [Any]) -> Int? {
        options.firstIndex { JSON.isEqual(value, $0) }
    }

    /// The strings in a JSON array, e.g. state["enabled_tools"].
    static func strings(_ value: Any?) -> [String] {
        (JSON.array(value) ?? []).compactMap(JSON.string)
    }

    /// `state.get(key, default)` for an on/off setting.
    static func flag(_ state: JSONObject, _ key: String, default fallback: Bool) -> Bool {
        state[key].map { JSON.truthy($0) } ?? fallback
    }

    // MARK: - The panel

    /// Everything the tabs need, computed once per render.
    struct PanelData {
        let view: Tools.View
        let state: JSONObject
        let daily: JSONObject
        let today: Day
        let weekStart: Day
        let todayModels: UsageStats.Models
        let weekModels: UsageStats.Models
        let monthModels: UsageStats.Models
        let lifetimeModels: UsageStats.Models
        let todayEfforts: [String: [String: Int]]
        let lifetimeEfforts: [String: [String: Int]]
        let grandTotal: Int
        let earlier: Int
        let todayTotal: Int
        let byokProviders: [String]
        let byokModels: [String: JSONObject]

        init(_ view: Tools.View, today: Day, state: JSONObject) {
            self.view = view
            self.state = state
            daily = view.daily
            self.today = today
            weekStart = today.adding(days: -6)
            todayModels = UsageStats.modelsInRange(daily, today, today)
            weekModels = UsageStats.modelsInRange(daily, weekStart, today)
            monthModels = UsageStats.modelsInRange(daily, today.firstOfMonth, today)
            lifetimeModels = UsageStats.modelsAllTime(daily)
            todayEfforts = UsageStats.effortsInRange(daily, today, today)
            lifetimeEfforts = UsageStats.effortsAllTime(daily)
            let detailed = UsageStats.modelTotals(lifetimeModels).reduce(0) { $0 + $1.tokens }
            grandTotal = view.grandTotal
            earlier = Swift.max(grandTotal - detailed, 0)
            todayTotal = UsageStats.modelTotals(todayModels).reduce(0) { $0 + $1.tokens }
            byokProviders = OpencodeSource.byokProviders(state)
            byokModels = OpencodeSource.byokModels(state)
        }
    }

    /// The tabs shown in the tab bar, in order, for one tool's view (or the
    /// combined view).
    public static func buildPanel(_ view: Tools.View, state: JSONObject,
                                  sessions: [ActiveSessions.Session], friends: [JSONObject],
                                  showLeaderboard: Bool, today: Day? = nil, now: Double? = nil,
                                  projectsExpanded: Bool = false,
                                  plugins: [Plugins.Row]? = nil, rangeOpen: Bool = false,
                                  live: LiveSnapshot? = nil) -> [Tab] {
        buildPanelResult(view, state: state, sessions: sessions, friends: friends,
                         showLeaderboard: showLeaderboard, today: today, now: now,
                         projectsExpanded: projectsExpanded, plugins: plugins, rangeOpen: rangeOpen,
                         live: live).tabs
    }

    /// `buildPanel`, plus what the app needs to know about rows by id (their
    /// folder, for rows that can be opened in Finder). `context` carries UI
    /// state that survives redraws.
    public static func buildPanelResult(_ view: Tools.View, state: JSONObject,
                                        sessions: [ActiveSessions.Session], friends: [JSONObject],
                                        showLeaderboard: Bool, today: Day? = nil, now: Double? = nil,
                                        projectsExpanded: Bool = false,
                                        plugins: [Plugins.Row]? = nil, rangeOpen: Bool = false,
                                        context: PanelContext = PanelContext(), live: LiveSnapshot? = nil)
        -> (tabs: [Tab], rows: [String: RowInfo]) {
        let d = PanelData(view, today: today ?? Day.today(), state: state)
        var tabs = [
            overviewTab(d),
            breakdownTab(d),
            modelsTab(d),
            projectsTab(d, expanded: projectsExpanded),
            costTab(d),
            limitsTab(d, now: now ?? Date().timeIntervalSince1970),
            subscriptionsTab(d),
        ]
        // A running session can't be tied to one provider, so provider views
        // have no Live tab.
        if Providers.providerNames[view.key] == nil {
            if let live = live {
                // The app passes the whole Live tab's data; `sessions` and
                // `plugins` are what tests and older callers pass instead.
                tabs.append(sessionsTab(view, live.sessions, plugins: live.plugins, now: now,
                                        background: live.background, scanned: live.scanned,
                                        notCounted: live.notCounted, error: live.error,
                                        limit: Limits.hitClaudeLimit(state, now: now ?? Date().timeIntervalSince1970)))
            } else {
                tabs.append(sessionsTab(view, sessions, plugins: plugins, now: now))
            }
        }
        if let warning = warning(d) {
            for index in tabs.indices {
                tabs[index].cards.insert(Card(title: nil, items: alertLines(warning)), at: 0)
            }
        }
        if showLeaderboard {
            tabs.append(leaderboardTab(state, friends))
        }
        // Last, so ids count the warning card too.
        var rows = [String: RowInfo]()
        for index in tabs.indices {
            let fit = fitted(tabs[index], measure: context.measure, open: context.open)
            tabs[index] = fit.tab
            for id in fit.ids {
                rows[id] = RowInfo()
            }
        }
        return (tabs, rows)
    }

    /// Why this AI's usage can't be seen, or nil. Shown at the top of every
    /// tab of its view.
    static func warning(_ d: PanelData) -> String? {
        let (view, name, key) = (d.view, d.view.name, d.view.key)
        if let error = view.error, !error.isEmpty {
            return "\(name) data couldn't be read: \(error)"
        }
        if Tools.toolNames[key] != nil {
            if d.daily.isEmpty && d.grandTotal == 0 {
                return "No \(name) usage found on this Mac yet."
            }
            return nil
        }
        if Providers.providerNames[key] == nil {
            return nil
        }
        let hasKey = strings(d.state["provider_keys"]).contains(key)
        let saved = d.state.object("accounts")?.object(key) ?? [:]
        if hasKey, let error = saved.string("error"), !error.isEmpty {
            return "Couldn't connect to \(name): \(error)"
        }
        if d.grandTotal != 0 {
            return nil
        }
        if hasKey {
            if saved.isEmpty || JSON.truthy(saved["has_usage"]) {
                return nil  // still fetching, or the account's usage is shown
            }
            let extra = key == "kimi" ? " An admin key (sk-admin-…) also shows usage."
                : " \(name) doesn't share usage history."
            return "No \(name) usage found on this Mac, and your \(name) key only shows your balance.\(extra)"
        }
        let found = "No \(name) usage found on this Mac. None of your tools have used \(name) models yet."
        if Accounts.keyHelp[key] == nil {
            return found  // no account API, so nothing more to offer
        }
        if key == "deepseek" {
            return found + " DeepSeek doesn't share usage history online, so an API key "
                + "would only show your balance."
        }
        return found + " For usage from other computers or the website, add an API key at the bottom of Home."
    }
}

/// How heavy a label's text is drawn (the panel uses these two).
public enum LabelWeight { case regular, semibold }

/// The width in points of `text` at `size` and `weight`. The app passes the
/// real font metrics; tests pass a stub.
public typealias TextMeasure = (_ text: String, _ size: CGFloat, _ weight: LabelWeight) -> CGFloat

/// UI state the app keeps across redraws and hands to the model.
public struct PanelContext {
    /// Rows whose detail is open, by row id.
    public var open: [String: Bool]
    public var measure: TextMeasure

    public init(open: [String: Bool] = [:], measure: @escaping TextMeasure = { _, _, _ in 0 }) {
        self.open = open
        self.measure = measure
    }
}

/// What the app can do with a row, by id.
public struct RowInfo: Equatable {
    public var path: String?

    public init(path: String? = nil) {
        self.path = path
    }
}
