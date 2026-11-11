import Foundation

/// The panel's tabs, each built from `PanelData`.
extension PanelModel {
    // MARK: - Overview

    static func overviewTab(_ d: PanelData) -> Tab {
        let stats = UsageStats.history(d.daily, today: d.today)
        let lifetime = UsageStats.categoryTotals(d.lifetimeModels)
        let range = PanelModel.chartRange(from: d.state, today: d.today, earliest: UsageStats.earliestDay(d.daily))
        let (first, last, title, selectedRange): (Day, Day, String, Int)
        switch range {
        case let .days(days):
            (first, last, title) = (d.today.adding(days: -(days - 1)), d.today, "Last \(plural(days, "day"))")
            selectedRange = chartRanges.firstIndex(of: days) ?? chartRanges.firstIndex(of: defaultChartDays) ?? 0
        case let .allTime(from):
            (first, last, title, selectedRange) = (from, d.today, "All time", chartRanges.count)
        case let .custom(from, to):
            (first, last, title, selectedRange) = (from, to, "\(formatShortDate(from)) – \(formatShortDate(to))",
                                                   chartRanges.count + 1)
        }
        let series = UsageStats.rangeSeries(d.daily, from: first, to: last)
        let peak = series.map(\.tokens).max() ?? 0
        let run = (series.first.map { $0.start.days(to: $0.end) } ?? 0) + 1
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
        var chartItems: [Item] = [
            .segmented(label: nil, options: chartRanges.map { plural($0, "day") } + ["All", "Custom"],
                       selected: selectedRange, action: "chart_days"),
        ]
        if case .custom = range {
            // The dates are picked in a popup (rangePopupCard).
            chartItems.append(.buttons([Item.Button("Change dates", "calendar", "chart_edit")]))
        }
        chartItems.append(.chart(
            values: series.map(\.tokens),
            caption: peak == 0 ? "No usage in this range"
                : "Peak \(TokenMath.formatCount(peak))" + (run > 1 ? " per \(run) days" : ""),
            labels: series.map { $0.start == $0.end ? formatShortDate($0.start)
                : "\(formatShortDate($0.start)) – \(formatShortDate($0.end))" }))
        let chart = Card(title: title, items: chartItems)
        return Tab(key: "overview", title: "Overview", short: "Home", icon: "square.grid.2x2",
                   cards: [tiles] + accountCards(d) + byokOverviewCards(d)
                       + [chart, Card(title: "History", items: historyItems)] + accountInvite(d))
    }

    /// The Custom range popup's card: two calendars side by side, From and To.
    /// It starts from the range the chart shows (or the last 30 days).
    public static func rangePopupCard(_ view: Tools.View, state: JSONObject, today: Day? = nil) -> Card {
        let d = PanelData(view, today: today ?? Day.today(), state: state)
        return rangeCard(d)
    }

    static func rangeCard(_ d: PanelData) -> Card {
        let earliest = Swift.min(UsageStats.earliestDay(d.daily) ?? d.today, d.today)
        let (from, to): (Day, Day)
        switch chartRange(from: d.state, today: d.today, earliest: earliest) {
        case let .custom(a, b): (from, to) = (a, b)
        case let .allTime(a): (from, to) = (a, d.today)
        case let .days(days): (from, to) = (Swift.max(d.today.adding(days: -(days - 1)), earliest), d.today)
        }
        return Card(title: "Custom range", items: [
            .rangePicker(from: from, to: to, earliest: earliest, latest: d.today),
            .note("Usage is recorded from \(formatShortDate(earliest))."),
        ])
    }

    /// The Custom range page (kept for callers that build the tab directly).
    static func rangeTab(_ d: PanelData) -> Tab {
        Tab(key: "range", title: "Custom Range", short: "Range", icon: "calendar", cards: [rangeCard(d)])
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

    /// BYOK providers relevant to the current view: for `opencode` (or `all`
    /// with `opencode` tracked), all BYOK providers found in opencode; for a
    /// provider view, that provider if its key was found via BYOK.
    static func relevantBYOKProviders(_ d: PanelData) -> [String] {
        let key = d.view.key
        if key == "opencode" {
            return d.byokProviders
        }
        if key == "all" && strings(d.state["enabled_tools"]).contains("opencode") {
            return d.byokProviders
        }
        if Providers.providerNames[key] != nil && d.byokProviders.contains(key) {
            return [key]
        }
        return []
    }

    /// Models in the BYOK catalog that belong to the current view.
    static func relevantBYOKModels(_ d: PanelData) -> [(id: String, info: JSONObject)] {
        let providers = Set(relevantBYOKProviders(d))
        guard !providers.isEmpty else { return [] }
        return d.byokModels.compactMap { id, info -> (id: String, info: JSONObject)? in
            let p = info.string("provider") ?? Providers.providerOf(id) ?? ""
            guard providers.contains(p) else { return nil }
            return (id, info)
        }.sorted { a, b in
            let nameA = modelDisplayName(a.id, catalog: d.byokModels)
            let nameB = modelDisplayName(b.id, catalog: d.byokModels)
            return nameA < nameB
        }
    }

    /// Overview card(s) for BYOK credentials scanned from opencode.
    static func byokOverviewCards(_ d: PanelData) -> [Card] {
        let providers = relevantBYOKProviders(d)
        guard !providers.isEmpty else { return [] }
        // Don't duplicate a provider card if the user also added a manual Keychain key for that provider view.
        if Providers.providerNames[d.view.key] != nil, strings(d.state["provider_keys"]).contains(d.view.key) {
            return []
        }
        let fetched = OpencodeSource.byokState(d.state).object("fetched") ?? [:]
        var items = [Item]()
        for provider in providers {
            let pName = Providers.providerNames[provider] ?? provider
            let count = d.byokModels.values.filter { ($0.string("provider") ?? "") == provider }.count
            let summary = count > 0 ? "\(count) model\(count == 1 ? "" : "s")" : "API key active"
            items.append(.row(label: "\(pName) (BYOK)", value: summary))
            if let pFetched = fetched.object(provider) {
                for row in pFetched.array("rows") ?? [] {
                    let pair = JSON.array(row) ?? []
                    guard pair.count == 2, let label = JSON.string(pair[0]), let value = JSON.string(pair[1]),
                          label != "Models available"
                    else { continue }
                    items.append(.row(label: "\(pName) · \(label)", value: value))
                }
                if let error = pFetched.string("error"), !error.isEmpty {
                    items += noteLines("\(pName): \(error)")
                }
            }
        }
        items.append(.note("Scanned from opencode's configured API key."))
        return [Card(title: "BYOK API key", items: items)]
    }

    /// For a provider view without a key: a quiet, optional way to add one,
    /// below everything else. The numbers above never need it.
    static func accountInvite(_ d: PanelData) -> [Card] {
        let key = d.view.key
        guard let help = Accounts.keyHelp[key],
              !strings(d.state["provider_keys"]).contains(key),
              !d.byokProviders.contains(key)
        else {
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
                           efforts: [String: [String: Int]] = [:], order: ModelTiers.Order = .tokens,
                           catalog: [String: JSONObject] = [:]) -> Card {
        let totals = ModelTiers.sorted(UsageStats.modelTotals(models), by: order, catalog: catalog)
        let whole = totals.reduce(0) { $0 + $1.tokens }
        if totals.isEmpty {
            return Card(title: title, items: [.note("No usage yet")])
        }
        var items = [Item]()
        for total in totals {
            let name = modelDisplayName(total.name, catalog: catalog)
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
        let order = ModelTiers.order(from: d.state["model_sort"])
        var lifetime = modelsCard("Lifetime", d.lifetimeModels, efforts: lifetimeEfforts, order: order,
                                  catalog: d.byokModels)
        if d.earlier != 0 {
            lifetime.items.append(.note("Plus \(TokenMath.formatCount(d.earlier)) older tokens with no model detail"))
        }
        var cards = [modelsCard("Today", d.todayModels, efforts: todayEfforts, order: order,
                                catalog: d.byokModels), lifetime]
        cards += byokModelsCards(d)
        if hasEfforts {
            cards.insert(Card(title: nil, items: [
                .switch(label: "Show effort", isOn: showEffort, action: "show_effort"),
            ]), at: 0)
        }
        return Tab(key: "models", title: "Models", short: "Models", icon: "brain", cards: cards)
    }

    /// Available models discovered from a BYOK API key, with their context/output limits.
    static func byokModelsCards(_ d: PanelData) -> [Card] {
        let available = relevantBYOKModels(d)
        guard !available.isEmpty else { return [] }
        let used = Set(d.lifetimeModels.keys)
        // Put used models first, then others with context limits.
        let sorted = available.sorted { a, b in
            let (aUsed, bUsed) = (used.contains(a.id), used.contains(b.id))
            if aUsed != bUsed { return aUsed }
            return modelDisplayName(a.id, catalog: d.byokModels) < modelDisplayName(b.id, catalog: d.byokModels)
        }
        let shown = Array(sorted.prefix(8))
        var items: [Item] = shown.map { entry in
            let name = modelDisplayName(entry.id, catalog: d.byokModels)
            let ctx = entry.info.int("context") ?? 0
            let out = entry.info.int("output") ?? 0
            let value: String
            if ctx > 0 && out > 0 {
                value = "\(TokenMath.formatCount(ctx)) · \(TokenMath.formatCount(out)) out"
            } else if ctx > 0 {
                value = "\(TokenMath.formatCount(ctx)) ctx"
            } else {
                value = Providers.providerNames[entry.info.string("provider") ?? ""] ?? "Available"
            }
            return .row(label: name, value: value)
        }
        if available.count > shown.count {
            items.append(.note("Plus \(available.count - shown.count) more models on this API key"))
        }
        return [Card(title: "Available BYOK models (\(available.count))", items: items)]
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
    public static func folderParts(_ path: String) -> (name: String, parent: String?) {
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
        let extraPrices = OpencodeSource.byokPrices(d.state)
        var costs = [String: (dollars: Double, unpriced: Int)]()
        for range in ranges {
            let perTool = dailies.map { daily in
                Pricing.estimateCost(UsageStats.modelsInRange(daily, range.start, range.end),
                                     recorded: UsageStats.recordedCostInRange(daily, range.start, range.end),
                                     extraPrices: extraPrices)
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

    /// "Free resets remaining": the number when a source reports one, else
    /// "Unavailable" and why. Never a made-up count.
    static func freeResetsCard(_ resets: FreeResets, now: Double) -> Card {
        switch resets {
        case .available(let count, let renewsAt):
            var items: [Item] = [.row(label: "Free resets remaining", value: "\(count)")]
            if let renewsAt = renewsAt, renewsAt != 0 {
                items.append(.note("Renews \(Limits.formatReset(renewsAt, now: now))"))
            }
            return Card(title: nil, items: items)
        case .unavailable(let reason):
            return Card(title: nil, items: [.row(label: "Free resets remaining", value: "Unavailable"), .note(reason)])
        }
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
        let byokLimits = byokLimitItems(d)
        if plan.isEmpty && byokLimits.isEmpty {
            plan += noteLines("\(view.name) doesn't record plan limits on this Mac.")
        } else if plan.isEmpty {
            plan = byokLimits
        }

        var cards = [Card(title: "Plan limits", items: plan)]
        if !byokLimits.isEmpty && plan != byokLimits {
            cards.append(Card(title: "BYOK limits", items: byokLimits))
        }
        // Claude Code's limits are the ones with free resets, so the line shows
        // in its view and in All AIs when it is tracked.
        if toolKeys.contains("claude_code") {
            cards.append(freeResetsCard(FreeResets.current(d.state, now: now), now: now))
        }
        let windows = Limits.limitWindows(d.state, toolKeys: toolKeys, now: now)
        if !windows.isEmpty {
            cards.append(alertsCard(d.state, windows: windows))
        }
        return Tab(key: "limits", title: "Usage Limits", short: "Limits", icon: "speedometer", cards: cards)
    }

    static func subscriptionsTab(_ d: PanelData) -> Tab {
        let enabled = strings(d.state["enabled_tools"])
        let auto = d.state.object("subscriptions") ?? [:]
        let details = d.state.object("subscription_details") ?? [:]
        var cards = [Card]()
        for tool in Subscriptions.supportedTools where enabled.contains(tool) {
            let name = Tools.toolNames[tool] ?? tool
            let found = auto.object(tool) ?? [:]
            let saved = details.object(tool) ?? [:]
            let plan = found.string("plan").map(Subscriptions.displayPlan) ?? "Unavailable"
            let email = found.string("email") ?? saved.string("email") ?? "Unavailable"
            let boundEmail = saved.string("card_email")
            let cardMatches = boundEmail == nil || boundEmail == (found.string("email") ?? saved.string("email"))
            let card = (cardMatches ? saved.string("last_four") : nil).map { "•••• \($0)" } ?? "Unavailable"
            var items: [Item] = [
                .row(label: "Plan", value: plan),
                .row(label: "Email", value: email),
                .row(label: "Card", value: card),
            ]
            if tool == "codex" {
                items += noteLines("Plan and email come from Codex's local sign-in. Billing details are not included.")
                items += noteLines("Checked every 5 seconds after Codex updates its sign-in.")
            } else {
                items += noteLines("Plan and email come from Claude Code's local account profile when available. Billing details are not included.")
            }
            var buttons = [Item.Button]()
            if found.string("email") == nil {
                buttons.append(Item.Button(saved.string("email") == nil ? "Set Email" : "Edit Email",
                                           "envelope", "subscription_email:\(tool)"))
            }
            buttons.append(Item.Button(saved.string("last_four") == nil ? "Set Card" : "Edit Card",
                                       "creditcard", "subscription_card:\(tool)"))
            items.append(.buttons(buttons))
            cards.append(Card(title: name, items: items))
        }
        if cards.isEmpty {
            cards.append(Card(title: "Subscriptions", items: noteLines("Track Codex or Claude Code to see subscription details.")))
        }
        return Tab(key: "subscriptions", title: "Subscriptions", short: "Plans", icon: "creditcard", cards: cards)
    }

    /// Limits discovered from BYOK credentials and catalog (balance/rate rows
    /// and model context/output token limits).
    static func byokLimitItems(_ d: PanelData) -> [Item] {
        let providers = relevantBYOKProviders(d)
        let available = relevantBYOKModels(d)
        guard !providers.isEmpty || !available.isEmpty else { return [] }
        var items = [Item]()
        let fetched = OpencodeSource.byokState(d.state).object("fetched") ?? [:]
        for provider in providers {
            let pName = Providers.providerNames[provider] ?? provider
            items.append(.row(label: "\(pName) API key", value: "Active (opencode)"))
            if let pFetched = fetched.object(provider) {
                for row in pFetched.array("rows") ?? [] {
                    let pair = JSON.array(row) ?? []
                    guard pair.count == 2, let label = JSON.string(pair[0]), let value = JSON.string(pair[1]) else {
                        continue
                    }
                    items.append(.row(label: "\(pName) · \(label)", value: value))
                }
            }
        }
        let used = Set(d.lifetimeModels.keys)
        let withLimits = available.filter { ($0.info.int("context") ?? 0) > 0 || ($0.info.int("output") ?? 0) > 0 }
        let sorted = withLimits.sorted { a, b in
            let (aUsed, bUsed) = (used.contains(a.id), used.contains(b.id))
            if aUsed != bUsed { return aUsed }
            return modelDisplayName(a.id, catalog: d.byokModels) < modelDisplayName(b.id, catalog: d.byokModels)
        }
        let shown = sorted.filter { used.contains($0.id) }.isEmpty
            ? Array(sorted.prefix(5))
            : sorted.filter { used.contains($0.id) }
        for entry in shown {
            let name = modelDisplayName(entry.id, catalog: d.byokModels)
            let ctx = entry.info.int("context") ?? 0
            let out = entry.info.int("output") ?? 0
            let limitText: String
            if ctx > 0 && out > 0 {
                limitText = "\(TokenMath.formatCount(ctx)) ctx · \(TokenMath.formatCount(out)) out"
            } else if ctx > 0 {
                limitText = "\(TokenMath.formatCount(ctx)) ctx"
            } else {
                limitText = "\(TokenMath.formatCount(out)) out"
            }
            items.append(.row(label: name, value: limitText))
        }
        return items
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

    /// What a process is doing, for its card: paused, busy now, waiting for
    /// what, idle for how long, or just running when Claude Code doesn't say.
    static func processState(_ session: ActiveSessions.Session, now: Double, limit: Limits.Level? = nil) -> String {
        if session.stopped { return "paused" }
        if let limit = limit, isHeldByLimit(session) {
            let resets = limit.resetsAt.flatMap { $0 != 0 ? $0 : nil }.map { ", resets \(Limits.formatReset($0, now: now))" }
            return "paused: \(limit.label) limit hit\(resets ?? "")"
        }
        switch session.status {
        case "busy": return "busy now"
        case "waiting": return session.waitingFor.map { "waiting: \($0)" } ?? "waiting for you"
        case "idle":
            if session.log == nil && session.tokens == nil && session.title == nil { return "idle, no messages yet" }
            guard let since = session.since else { return "idle" }
            return "idle for " + formatDuration(Swift.max(now - since, 0))
        default: return "running"
        }
    }

    /// "5 min", "2 hr", "3 days": how long, without "ago".
    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "under a minute" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hr" }
        let days = Int(seconds / 86400)
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    /// The state a session is in: what the registry decided, or, for a
    /// session built without it, what Claude Code's status string says.
    static func effectiveState(_ session: ActiveSessions.Session) -> SessionRules.State {
        if let state = session.state { return state }
        switch session.status {
        case "busy": return .active
        case "waiting": return .waiting
        case "idle": return .idle
        default: return .unknown
        }
    }

    /// Whether a plan limit that is hit holds this session: it is a Claude Code
    /// session that would otherwise read as running (Active, or no state
    /// known). An Idle or Waiting one is not running, so the limit changes nothing.
    static func isHeldByLimit(_ session: ActiveSessions.Session) -> Bool {
        guard (session.tool ?? "claude_code") == "claude_code", !session.stopped else { return false }
        let state = effectiveState(session)
        return state == .active || state == .unknown
    }

    /// The word shown on the right of a session's status row, and its dot.
    /// A paused session reads "Paused" whatever its record says; one held by a
    /// plan limit that is hit (`limit`) reads "Limit hit".
    static func stateWord(_ session: ActiveSessions.Session,
                          limit: Limits.Level? = nil) -> (word: String, dot: LabelExtras.Dot) {
        if session.stopped { return ("Paused", .grey) }
        if limit != nil, isHeldByLimit(session) { return ("Limit hit", .yellow) }
        switch effectiveState(session) {
        case .active: return ("Active", .green)
        case .waiting: return ("Waiting", .yellow)
        case .idle: return ("Idle", .grey)
        case .unknown: return ("Unknown", .hollow)
        }
    }

    /// "2 active · 1 waiting · 1 paused": how many sessions are in each state
    /// (only the states that have any). A paused session is counted as paused
    /// only, as its row reads "Paused", so the numbers add up to the title's count.
    static func stateSummary(_ sessions: [ActiveSessions.Session], limit: Limits.Level? = nil) -> String {
        var counts = [SessionRules.State: Int]()
        var held = 0
        for session in sessions {
            if session.stopped { continue }  // counted below, as paused, and nowhere else
            if limit != nil, isHeldByLimit(session) {
                held += 1
            } else {
                counts[effectiveState(session), default: 0] += 1
            }
        }
        let words: [(SessionRules.State, String)] = [(.active, "active"), (.waiting, "waiting"), (.idle, "idle"),
                                                    (.unknown, "unknown")]
        var parts = words.compactMap { state, word in counts[state].map { "\($0) \(word)" } }
        if held > 0 { parts.append("\(held) limit hit") }
        let paused = sessions.filter(\.stopped).count
        if paused > 0 { parts.append("\(paused) paused") }
        return parts.joined(separator: " · ")
    }

    /// How many subagent lines one session shows before "…and N more".
    static let maxSubagentLines = 5

    /// One line per running subagent, indented one step per level of depth.
    static func subagentItems(_ subagents: [Subagent]) -> [Item] {
        var items = [Item]()
        for subagent in subagents.prefix(maxSubagentLines) {
            let indent = String(repeating: "  ", count: Swift.max(subagent.depth - 1, 0))
            let text = subagent.description.map { "\(subagent.type): \($0)" } ?? subagent.type
            items += noteLines("\(indent)↳ \(text)")
        }
        if subagents.count > maxSubagentLines {
            items.append(.note("↳ …and \(subagents.count - maxSubagentLines) more"))
        }
        return items
    }

    /// "N process(es) not counted": what the scan saw and left out, wrapped
    /// to the card's width.
    static func notCountedItems(_ count: Int) -> [Item] {
        noteLines(count == 1 ? "1 process not counted (a server, a helper or one with no terminal)"
                  : "\(count) processes not counted (servers, helpers or ones with no terminal)")
    }

    /// Open sessions as a status list: a summary card (the count, how many are
    /// in each state, Stop all and Quit all, a row with a dot, a name and a
    /// state for each session that can't be controlled, and a note of what
    /// was left out), a card of its own for each Claude Code session (its
    /// first row is the same dot, name and state; below it the tokens,
    /// process, subagents, plugins and Stop and Quit), a "Background" card
    /// for background agents (listed, not counted), and, when `plugins` is
    /// given (Claude Code's view or All AIs), what each plugin did. Before
    /// the first scan (`scanned` false) it says it is looking, not that
    /// there are 0 sessions.
    static func sessionsTab(_ view: Tools.View, _ sessions: [ActiveSessions.Session],
                            plugins: [Plugins.Row]? = nil, now: Double? = nil,
                            background: [ActiveSessions.Session] = [], scanned: Bool = true,
                            notCounted: Int = 0, error: String? = nil, limit: Limits.Level? = nil) -> Tab {
        let now = now ?? Date().timeIntervalSince1970
        func finish(_ cards: [Card]) -> Tab {
            Tab(key: "sessions", title: "Active Sessions", short: "Live", icon: "terminal", cards: cards)
        }
        if !scanned {
            return finish([Card(title: "Sessions", items: [.note(error ?? "Looking for sessions…")])])
        }
        // Just the folder's name, as in Projects; two folders with one name
        // also show their parent ("app · b").
        var foldersByName = [String: Set<String>]()
        for session in sessions + background {
            foldersByName[folderParts(session.label).name, default: []].insert(session.label)
        }
        func name(_ session: ActiveSessions.Session) -> String {
            let part = folderParts(session.label)
            if foldersByName[part.name, default: []].count > 1, let parent = part.parent {
                return "\(part.name) · \(parent)"
            }
            return part.name
        }
        func tagItems(_ sessions: [ActiveSessions.Session]) -> [Item] {
            var tags = [Item.Tag]()
            for tag in sessions.flatMap({ $0.plugins ?? [] }) {
                if let index = tags.firstIndex(where: { $0.text == tag.name }) {
                    tags[index].isOn = tags[index].isOn || tag.runs
                } else {
                    tags.append(Item.Tag(tag.name, tag.runs))
                }
            }
            return tagLines(tags).map { .tags($0) }
        }

        let processes = sessions.filter(\.isControllable)
        var items = [Item]()
        if let error = error { items += noteLines(error) }
        if sessions.isEmpty {
            let who = view.key == "all" ? "" : "\(view.name) "
            items.append(.note("No \(who)sessions running"))
        } else {
            items.append(.note(stateSummary(sessions, limit: limit)))
        }
        if !processes.isEmpty {
            items.append(.buttons([Item.Button("Stop all", "pause.circle", "sessions_stop_all"),
                                   Item.Button("Quit all", "xmark.circle", "sessions_quit_all")]))
            if processes.contains(where: \.stopped) {
                items.append(.buttons([Item.Button("Resume all", "play.circle", "sessions_resume_all")]))
            }
        }
        if notCounted > 0 { items += notCountedItems(notCounted) }

        var cards = [Card(title: "Sessions (\(sessions.count))", items: items)]
        for session in sessions {
            // The chat's title (as the editor shows it) tells the cards apart;
            // without one, the folder's name does (with the tool's name where
            // several tools show).
            let (word, dot) = stateWord(session, limit: limit)
            let tool = view.key == "all" ? Tools.toolNames[session.tool ?? ""] : nil
            let label = session.title ?? (tool.map { "\($0) · \(name(session))" } ?? name(session))
            var items: [Item] = [
                .row(label: label, value: word, extras: LabelExtras(dot: dot)),
            ]
            if session.stopped {
                items.append(.alert(text: "Paused · click Resume to continue", showIcon: true))
            } else {
                let state = processState(session, now: now, limit: limit)
                let toolNote = session.title != nil ? tool : nil
                items.append(.note([toolNote, session.kind, state].compactMap { $0 }.joined(separator: " · ")))
            }
            let info = [session.stopped && session.title != nil ? tool : nil,
                        session.title != nil ? name(session) : nil,
                        session.pid.map { "process \($0)" },
                        session.tokens.map { "\(TokenMath.formatCount($0)) tokens" }]
                .compactMap { $0 }.joined(separator: " · ")
            if !info.isEmpty {
                items += noteLines(info)
            }
            items += subagentItems(session.subagents)
            items += tagItems([session])
            if session.isControllable, let pid = session.pid {
                let pause = session.stopped ? Item.Button("Resume", "play.circle", "session_resume:\(pid)")
                    : Item.Button("Stop", "pause.circle", "session_stop:\(pid)")
                items.append(.buttons([pause, Item.Button("Quit", "xmark.circle", "session_quit:\(pid)")]))
            }
            cards.append(Card(title: nil, items: items))
        }
        if !background.isEmpty {
            var items: [Item] = [.note("Not counted in Sessions")]
            for agent in background {
                let (word, dot) = stateWord(agent)
                items.append(.row(label: agent.title ?? name(agent), value: word, extras: LabelExtras(dot: dot)))
            }
            cards.append(Card(title: "Background (\(background.count))", items: items))
        }
        if let plugins = plugins {
            cards.append(pluginsCard(plugins, now: now))
        }
        return finish(cards)
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
        ] + noteLines("The numbers are Claude Code totals, whichever AI you are viewing. Work in progress.")
        return Tab(key: "leaderboard", title: "Leaderboard (Beta · WIP)", short: "Board", icon: "trophy",
                   cards: [Card(title: "Ranking", items: ranking), Card(title: nil, items: actions)])
    }
}
