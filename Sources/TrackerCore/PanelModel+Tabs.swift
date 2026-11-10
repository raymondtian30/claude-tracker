import Foundation

/// The panel's tabs, each built from `PanelData`.
extension PanelModel {
    // MARK: - Overview

    static func overviewTab(_ d: PanelData) -> Tab {
        let stats = UsageStats.history(d.daily, today: d.today)
        let lifetime = UsageStats.categoryTotals(d.lifetimeModels)
        let chartDays = PanelModel.chartDays(from: d.state)
        let series = UsageStats.dailySeries(d.daily, d.today, chartDays)
        let peak = series.map(\.tokens).max() ?? 0
        var historyItems: [Item] = [
            .row(label: "Yesterday", value: TokenMath.formatCount(stats.yesterday)),
            .row(label: "Last 7 days", value: TokenMath.formatCount(stats.last7Days)),
            .row(label: "This month", value: TokenMath.formatCount(stats.thisMonth)),
        ]
        if let best = stats.biggestDay {
            historyItems.append(.row(label: "Biggest day · \(formatShortDate(best.day))",
                                     value: TokenMath.formatCount(best.tokens)))
        }
        // Cache reads dominate some tools' totals; new input + output compares
        // fairly across tools.
        historyItems.append(.row(label: "New input + output",
                                 value: TokenMath.formatCount((lifetime["input"] ?? 0) + (lifetime["output"] ?? 0))))
        let tiles = Card(title: nil, items: [
            .tiles([
                Item.Tile("Today", TokenMath.formatCount(d.todayTotal), "sun.max"),
                Item.Tile("Lifetime", TokenMath.formatCount(d.grandTotal), "infinity"),
            ]),
        ])
        let chart = Card(title: "Last \(chartDays) days", items: [
            .segmented(label: nil, options: chartRanges.map { "\($0) days" },
                       selected: chartRanges.firstIndex(of: chartDays) ?? 1, action: "chart_days"),
            .chart(values: series.map(\.tokens), caption: "Peak \(TokenMath.formatCount(peak))",
                   labels: series.map { formatShortDate($0.day) }),
        ])
        return Tab(key: "overview", title: "Overview", short: "Home", icon: "square.grid.2x2",
                   cards: [tiles] + accountCards(d) + [chart, Card(title: "History", items: historyItems)]
                       + accountInvite(d))
    }

    /// For a provider view: numbers from the provider's own API, kept apart
    /// from the local counts above (they overlap).
    static func accountCards(_ d: PanelData) -> [Card] {
        let key = d.view.key
        guard Providers.providerNames[key] != nil, strings(d.state["provider_keys"]).contains(key) else {
            return []
        }
        let title = "\(d.view.name) account"
        let keyButtons = Item.buttons([Item.Button("Replace Key", "key", "provider_key:\(key)"),
                                       Item.Button("Remove Key", "trash", "provider_key_remove:\(key)")])
        guard let saved = d.state.object("accounts")?.object(key), !saved.isEmpty else {
            return [Card(title: title, items: [.note("Fetching account numbers…"), keyButtons])]
        }
        var items = [Item]()
        let daily = saved.object("daily") ?? [:]
        if !daily.isEmpty {
            let windowStart = d.today.adding(days: -(Accounts.windowDays - 1))
            items += [
                .row(label: "Today", value: TokenMath.formatCount(UsageStats.totalInRange(daily, d.today, d.today))),
                .row(label: "Last 7 days",
                     value: TokenMath.formatCount(UsageStats.totalInRange(daily, d.weekStart, d.today))),
                .row(label: "Last \(Accounts.windowDays) days",
                     value: TokenMath.formatCount(UsageStats.totalInRange(daily, windowStart, d.today))),
            ]
        }
        let cost = saved.object("cost") ?? [:]
        if !cost.isEmpty {
            func billed(_ days: Int) -> Double {
                let start = d.today.adding(days: -(days - 1))
                // Date order, so the sum adds up the same way every time.
                return cost.keys.sorted().reduce(0.0) { total, iso in
                    guard let day = Day(iso: iso), start <= day, day <= d.today else { return total }
                    return total + (JSON.double(cost[iso]) ?? 0)
                }
            }
            items += [
                .row(label: "Billed, last 7 days", value: Pricing.formatMoney(billed(7), currency: PanelModel.currency(from: d.state))),
                .row(label: "Billed, last \(Accounts.windowDays) days",
                     value: Pricing.formatMoney(billed(Accounts.windowDays), currency: PanelModel.currency(from: d.state))),
            ]
        }
        for row in saved.array("rows") ?? [] {
            let pair = JSON.array(row) ?? []
            guard pair.count == 2, let label = JSON.string(pair[0]), let value = JSON.string(pair[1]) else {
                continue
            }
            items.append(.row(label: label, value: value))
        }
        for note in strings(saved["notes"]) {
            items += noteLines(note)
        }
        if let fetchedAt = saved.string("fetched_at"), !fetchedAt.isEmpty,
           let fetched = LocalTime.parseISO(fetchedAt) {
            items.append(.note("Updated \(clockTime(fetched))"))
        }
        items.append(keyButtons)
        return [Card(title: title, items: items)]
    }

    /// strftime's "%-I:%M %p": "9:05 AM".
    static func clockTime(_ timestamp: Double) -> String {
        let parts = LocalTime.parts(of: timestamp)
        let hour = parts.hour % 12 == 0 ? 12 : parts.hour % 12
        return String(format: "%d:%02d %@", hour, parts.minute, parts.hour < 12 ? "AM" : "PM")
    }

    /// For a provider view without a key: a quiet, optional way to add one,
    /// below everything else. The numbers above never need it.
    static func accountInvite(_ d: PanelData) -> [Card] {
        let key = d.view.key
        guard let help = Accounts.keyHelp[key], !strings(d.state["provider_keys"]).contains(key) else {
            return []  // no account API supported, or a key is already added
        }
        var items = noteLines("Usage from other computers or the website "
                              + "needs an API key. Not needed for this Mac.")
        items += noteLines(help + ".")
        items.append(.buttons([Item.Button("Add API Key", "key", "provider_key:\(key)")]))
        return [Card(title: "Whole account (optional)", items: items)]
    }

    // MARK: - Token types and models

    static func breakdownCard(_ title: String, _ models: UsageStats.Models, extra: Int) -> Card {
        let categories = mergeCacheWrites(UsageStats.categoryTotals(models))
        let whole = categories.values.reduce(0, +) + extra
        var items = categoryLabels.map { shareBar($0.label, categories[$0.key] ?? 0, whole) }
        if extra != 0 {
            items.append(shareBar("Older, no detail", extra, whole))
        }
        return Card(title: title, items: items)
    }

    static func breakdownTab(_ d: PanelData) -> Tab {
        var lifetime = breakdownCard("Lifetime", d.lifetimeModels, extra: d.earlier)
        lifetime.items.append(.note("Cache read = context re-sent each turn, billed cheaply"))
        return Tab(key: "breakdown", title: "Token Types", short: "Types", icon: "chart.pie",
                   cards: [breakdownCard("Today", d.todayModels, extra: 0), lifetime])
    }

    /// One bar per model, or per model and effort ("Opus 5.5 (High)") when the
    /// tool recorded the effort. A model's effort rows are largest first, and
    /// their sum is clamped to the model's total (merged or backfilled maps can
    /// hold more than the model has); what's left over, when there is any,
    /// stays a plain model row. So the rows always add up to the model's total.
    static func modelsCard(_ title: String, _ models: UsageStats.Models,
                           efforts: [String: [String: Int]] = [:]) -> Card {
        let totals = UsageStats.modelTotals(models)
        let whole = totals.reduce(0) { $0 + $1.tokens }
        if totals.isEmpty {
            return Card(title: title, items: [.note("No usage yet")])
        }
        var items = [Item]()
        for total in totals {
            let name = modelDisplayName(total.name)
            var left = total.tokens
            var shownAny = false
            let known = (efforts[total.name] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            for (effort, tokens) in known where left > 0 {
                let shown = Swift.min(tokens, left)
                items.append(shareBar("\(name) (\(effort.prefix(1).uppercased() + effort.dropFirst()))", shown, whole))
                left -= shown
                shownAny = true
            }
            if left > 0 || !shownAny {
                items.append(shareBar(name, left, whole))
            }
        }
        return Card(title: title, items: items)
    }

    static func modelsTab(_ d: PanelData) -> Tab {
        // Efforts can be hidden. The control only shows once some model has one.
        let hasEfforts = !d.lifetimeEfforts.isEmpty
        let showEffort = flag(d.state, "show_effort", default: true)
        let todayEfforts = showEffort ? d.todayEfforts : [:]
        let lifetimeEfforts = showEffort ? d.lifetimeEfforts : [:]
        var lifetime = modelsCard("Lifetime", d.lifetimeModels, efforts: lifetimeEfforts)
        if d.earlier != 0 {
            lifetime.items.append(.note("Plus \(TokenMath.formatCount(d.earlier)) older tokens with no model detail"))
        }
        var cards = [modelsCard("Today", d.todayModels, efforts: todayEfforts), lifetime]
        if hasEfforts {
            cards.insert(Card(title: nil, items: [
                .segmented(label: nil, options: ["With effort", "Without effort"], selected: showEffort ? 0 : 1,
                           action: "show_effort"),
            ]), at: 0)
        }
        return Tab(key: "models", title: "Models", short: "Models", icon: "brain", cards: cards)
    }

    // MARK: - Projects

    /// Every project from the last 7 days, most used first: the top 5, and
    /// the rest behind "Show more".
    static func projectsTab(_ d: PanelData, expanded: Bool) -> Tab {
        let projects = UsageStats.topProjects(d.daily, d.weekStart, d.today)
        let weekTotal = UsageStats.modelTotals(d.weekModels).reduce(0) { $0 + $1.tokens }
        let shown = expanded ? projects : Array(projects.prefix(projectsShown))
        var items: [Item]
        if projects.isEmpty {
            items = [.note("No usage in the last 7 days")]
        } else {
            // Just the folder's name; the full path is the tip. Two folders
            // with one name also show their parent ("app · b").
            let parts = projects.map { folderParts($0.name) }
            var counts = [String: Int]()
            for part in parts { counts[part.name, default: 0] += 1 }
            let rows = Dictionary(uniqueKeysWithValues: zip(projects.map(\.name), parts).map { ($0.0, $0.1) })
            items = shown.map { project in
                let part = rows[project.name] ?? (name: project.name, parent: nil)
                let duplicated = counts[part.name, default: 0] > 1
                let label = duplicated ? part.parent.map { "\(part.name) · \($0)" } ?? part.name : part.name
                return shareBar(label, project.tokens, weekTotal, tip: project.name)
            }
        }
        let hidden = projects.count - projectsShown
        if hidden > 0 {
            let button = expanded ? Item.Button("Show less", "chevron.up", "projects_expand")
                : Item.Button("Show \(hidden) more", "chevron.down", "projects_expand")
            items.append(.buttons([button]))
        }
        return Tab(key: "projects", title: "Projects", short: "Projects", icon: "folder",
                   cards: [Card(title: "Projects · last 7 days", items: items)])
    }

    /// "~/Downloads/FPS Game" -> ("FPS Game", "Downloads"); "~" and "/" are their own names.
    static func folderParts(_ path: String) -> (name: String, parent: String?) {
        var trimmed = Substring(path)
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed = trimmed.dropLast()
        }
        if trimmed == "~" || trimmed == "/" || trimmed.isEmpty {
            return (path.isEmpty ? "Unknown" : String(trimmed.isEmpty ? Substring(path) : trimmed), nil)
        }
        let pieces = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let name = String(pieces.last ?? trimmed)
        let parent = pieces.count >= 2 ? String(pieces[pieces.count - 2]) : nil
        return (name.isEmpty ? String(trimmed) : name, parent?.isEmpty == true ? nil : parent)
    }

    // MARK: - Cost

    static func costTab(_ d: PanelData) -> Tab {
        let ranges: [(key: String, start: Day, end: Day)] = [
            ("today", d.today, d.today),
            ("week", d.weekStart, d.today),
            ("month", d.today.firstOfMonth, d.today),
            ("all", Day.min, Day.max),
        ]
        // Price each tool on its own: a cost one tool recorded for a model must
        // not stand in for another tool's tokens of the same model.
        let dailies = (d.view.views ?? [d.view]).map(\.daily)
        var costs = [String: (dollars: Double, unpriced: Int)]()
        for range in ranges {
            let perTool = dailies.map { daily in
                Pricing.estimateCost(UsageStats.modelsInRange(daily, range.start, range.end),
                                     recorded: UsageStats.recordedCostInRange(daily, range.start, range.end))
            }
            costs[range.key] = (perTool.reduce(0.0) { $0 + $1.dollars }, perTool.reduce(0) { $0 + $1.unpriced })
        }
        let currency = PanelModel.currency(from: d.state)
        func dollars(_ key: String) -> String { Pricing.formatMoney(costs[key]?.dollars ?? 0, currency: currency) }
        var notes = [Item]()
        let unpriced = costs.values.map(\.unpriced).max() ?? 0
        if unpriced != 0 {
            notes.append(.note("\(TokenMath.formatCount(unpriced)) tokens from unknown models not priced"))
        }
        if d.earlier != 0 {
            notes.append(.note("\(TokenMath.formatCount(d.earlier)) older tokens not priced (no model detail)"))
        }
        notes.append(.note("Estimate at API list prices. Subscriptions are"))
        notes.append(.note("flat-rate, so you aren't billed this."))
        return Tab(key: "cost", title: "Estimated API Cost", short: "Cost", icon: "dollarsign.circle", cards: [
            Card(title: nil, items: [
                .tiles([
                    Item.Tile("Today", dollars("today"), "sun.max"),
                    Item.Tile("This month", dollars("month"), "calendar"),
                ]),
            ]),
            Card(title: nil, items: [
                .row(label: "Last 7 days", value: dollars("week")),
                .row(label: "All logged usage", value: dollars("all")),
            ] + notes),
        ])
    }

    // MARK: - Usage limits

    /// What to say under Claude Code's limits when there are no percentages.
    static func claudeLimitNotes(_ state: JSONObject, _ levels: [Limits.Level], prefix: String) -> [Item] {
        var notes = [Item]()
        if flag(state, "claude_usage_enabled", default: true) {
            let usage = state.object("claude_usage") ?? [:]
            if let error = usage.string("error"), !error.isEmpty {
                notes += noteLines(prefix + error)
            } else if !JSON.truthy(usage["limits"]) {
                notes += noteLines(prefix + "Getting percentages from Anthropic…")
            }
        } else {
            var text = "Claude Code only records a limit once it's reached."
            if levels.isEmpty {
                text += " None is reached right now."
            }
            text += " Turn on Percentages from Anthropic in Settings to see how close you are."
            notes += noteLines(prefix + text)
        }
        return notes
    }

    static func limitsTab(_ d: PanelData, now: Double) -> Tab {
        let (view, key) = (d.view, d.view.key)
        let toolKeys: [String]
        if key == "all" {
            toolKeys = strings(d.state["enabled_tools"])
        } else if Tools.toolNames[key] != nil {
            toolKeys = [key]
        } else {
            toolKeys = []
        }

        var plan = [Item]()
        let levels = Limits.planLevels(d.state, toolKeys: toolKeys, now: now)
        for tool in toolKeys {
            let prefix = key == "all" ? "\(Tools.toolNames[tool] ?? tool): " : ""
            let found = levels.filter { $0.id.hasPrefix("\(tool):") }
            for level in found {
                var sub: String?
                if let resetsAt = level.resetsAt, resetsAt != 0 {
                    sub = "Resets \(Limits.formatReset(resetsAt, now: now))"
                }
                let value = level.reached ? "Reached" : String(format: "%.0f%%", level.percent)
                plan.append(.bar(label: Limits.displayName(level), value: value,
                                 fraction: Swift.min(level.percent / 100, 1.0), sub: sub))
            }
            if tool == "claude_code" {
                plan += claudeLimitNotes(d.state, found, prefix: prefix)
            } else if tool == "codex" && found.isEmpty {
                plan += noteLines(prefix + "Codex hasn't recorded its plan limits yet.")
            }
        }
        if plan.isEmpty {
            plan += noteLines("\(view.name) doesn't record plan limits on this Mac.")
        }

        var cards = [Card(title: "Plan limits", items: plan)]
        let windows = Limits.limitWindows(d.state, toolKeys: toolKeys, now: now)
        if !windows.isEmpty {
            cards.append(alertsCard(d.state, windows: windows))
        }
        return Tab(key: "limits", title: "Usage Limits", short: "Limits", icon: "speedometer", cards: cards)
    }

    /// When to be notified, for the limit `windows` this view has.
    static func alertsCard(_ state: JSONObject, windows: [String]) -> Card {
        let thresholds = JSON.array(state["alert_thresholds"] ?? [Limits.defaultAlertThreshold]) ?? []
        let windowsOn = state["alert_windows"].map(strings) ?? Limits.windows.map(\.key)
        var items: [Item] = [
            .switch(label: "Notify me", isOn: flag(state, "alerts_enabled", default: true), action: "alerts_enabled"),
            .choices(label: "When usage reaches", options: Limits.alertThresholds.map { "\($0)%" },
                     selected: Limits.alertThresholds.indices.filter {
                         index(of: Limits.alertThresholds[$0], in: thresholds) != nil
                     },
                     action: "alert_thresholds"),
        ]
        items += windows.map { window in
            .switch(label: "\(Limits.windowLabels[window] ?? window) limit", isOn: windowsOn.contains(window),
                    action: "alert_window:\(window)")
        }
        items.append(.buttons([Item.Button("Send Test Alert", "bell", "alert_test")]))
        return Card(title: "Notifications", items: items)
    }

    // MARK: - Active sessions

    /// Plugin tags split into lines that fit across a card.
    public static func tagLines(_ tags: [Item.Tag]) -> [[Item.Tag]] {
        var lines = [[Item.Tag]]()
        var line = [Item.Tag]()
        var used = 0
        for tag in tags {
            let cost = tag.text.unicodeScalars.count + tagSpace
            if !line.isEmpty && used + cost > tagLineChars {
                lines.append(line)
                line = []
                used = 0
            }
            line.append(tag)
            used += cost
        }
        if !line.isEmpty {
            lines.append(line)
        }
        return lines
    }

    /// How long ago `then` was, as "5 min ago".
    public static func formatAgo(_ then: Double, _ now: Double) -> String {
        let seconds = Swift.max(now - then, 0)
        if seconds < 60 {
            return "just now"
        }
        if seconds < 3600 {
            return "\(Int(seconds / 60)) min ago"
        }
        if seconds < 86400 {
            return "\(Int(seconds / 3600)) hr ago"
        }
        let days = Int(seconds / 86400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    static func plural(_ count: Int, _ word: String) -> String {
        "\(count) \(word)\(count == 1 ? "" : "s")"
    }

    static let activityWords: [(kind: String, word: String)] = [
        ("skill", "skill"), ("agent", "agent"), ("tool", "tool call"), ("hook", "hook"),
    ]

    static func pluginsCard(_ plugins: [Plugins.Row], now: Double) -> Card {
        var items = [Item]()
        for plugin in plugins {
            items.append(.row(label: plugin.label, value: plural(plugin.sessions, "session")))
            if let latest = plugin.latest {
                items.append(.note("\(latest.text) · \(formatAgo(latest.at, now))"))
            } else {
                items.append(.note("Enabled, not used yet"))
            }
            let counts = activityWords.compactMap { activity -> String? in
                guard let count = plugin.today[activity.kind], count != 0 else { return nil }
                return plural(count, activity.word)
            }
            if !counts.isEmpty {
                items.append(.note("Today: " + counts.joined(separator: ", ")))
            }
        }
        return Card(title: "Plugins (\(plugins.count) enabled)",
                    items: items.isEmpty ? [.note("No plugins enabled")] : items)
    }

    /// Open sessions, each with tags for the plugins it runs, then (when
    /// `plugins` is given: Claude Code's view or All AIs) what each plugin did.
    static func sessionsTab(_ view: Tools.View, _ sessions: [ActiveSessions.Session],
                            plugins: [Plugins.Row]? = nil, now: Double? = nil) -> Tab {
        var items = [Item]()
        for session in sessions {
            items.append(.row(label: session.label,
                              value: session.tokens.map(TokenMath.formatCount) ?? "running"))
            let tags = (session.plugins ?? []).map { Item.Tag($0.name, $0.runs) }
            items += tagLines(tags).map { .tags($0) }
        }
        if items.isEmpty {
            let name = view.key == "all" ? "" : "\(view.name) "
            items = [.note("No \(name)sessions running")]
        }
        var cards = [Card(title: "Sessions (\(sessions.count))", items: items)]
        if let plugins = plugins {
            cards.append(pluginsCard(plugins, now: now ?? Date().timeIntervalSince1970))
        }
        return Tab(key: "sessions", title: "Active Sessions", short: "Live", icon: "terminal", cards: cards)
    }

    // MARK: - Leaderboard

    static func leaderboardTab(_ state: JSONObject, _ friends: [JSONObject]) -> Tab {
        let view = state["leaderboard_view"] ?? "total"
        let viewKeys = leaderboardViews.map(\.key)
        let metric = JSON.isEqual(view, "total") ? "total_tokens" : "yesterday_tokens"
        var ranking: [Item] = [
            .segmented(label: nil, options: leaderboardViews.map(\.label),
                       selected: index(of: view, in: viewKeys) ?? 0, action: "leaderboard_view"),
        ]
        if friends.isEmpty {
            ranking.append(.note("No friends added yet"))
        } else {
            let most = friends.map { $0.int(metric) ?? 0 }.max() ?? 0
            let top = most != 0 ? most : 1
            for (offset, friend) in friends.enumerated() {
                let tokens = friend.int(metric) ?? 0
                ranking.append(.bar(label: "\(offset + 1). \(friend.string("name") ?? "Friend")",
                                    value: TokenMath.formatCount(tokens), fraction: Double(tokens) / Double(top)))
            }
        }

        let firstRow: [Item.Button]
        if JSON.truthy(state["my_gist_id"]) {
            firstRow = [
                Item.Button("Share Code", "square.and.arrow.up", "leaderboard_share"),
                Item.Button("Push Now", "arrow.up.circle", "leaderboard_push"),
            ]
        } else {
            firstRow = [Item.Button("Set Up Leaderboard", "person.crop.circle.badge.plus", "leaderboard_setup")]
        }
        let actions: [Item] = [
            .buttons(firstRow),
            .buttons([
                Item.Button("Add Friend", "person.badge.plus", "leaderboard_add"),
                Item.Button("Pull Now", "arrow.down.circle", "leaderboard_pull"),
            ]),
            .note("Scores are self-reported and can be faked. Just for fun."),
        ]
        return Tab(key: "leaderboard", title: "Leaderboard (Beta)", short: "Friends", icon: "trophy",
                   cards: [Card(title: "Ranking", items: ranking), Card(title: nil, items: actions)])
    }
}
