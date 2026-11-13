import Foundation

// The Usage Limits tab: one "Limits" card with a section for every AI being
// tracked (a heading per AI in All AIs), then free resets and Notifications.
// A section shows the AI's limits, or "No data"; numbers that may be out of
// date carry a note saying how old they are.
extension PanelModel {
    static func limitsTab(_ d: PanelData, now: Double) -> Tab {
        let keys = Limits.trackedKeys(d.view.key, state: d.state)
        let all = d.view.key == "all"
        var items = [Item]()
        for key in keys {
            if all {
                items.append(.heading(Tools.toolNames[key] ?? Providers.providerNames[key] ?? key))
            }
            items += limitSection(d, key: key, underHeading: all, now: now)
        }
        if items.isEmpty {
            items = [noData]
        }
        var cards = [Card(title: "Limits", items: items)]
        let toolKeys = keys.filter { Tools.toolNames[$0] != nil }
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

    static let noData = Item.row(label: "Limits", value: "No data")

    /// One AI's part of the Limits card.
    static func limitSection(_ d: PanelData, key: String, underHeading: Bool, now: Double) -> [Item] {
        let name = Tools.toolNames[key] ?? Providers.providerNames[key] ?? key
        switch key {
        case "claude_code":
            return claudeSection(d.state, underHeading: underHeading, now: now)
        case "codex":
            let shown = Limits.codexShown(d.state, now: now)
            if shown.levels.isEmpty {
                return [noData] + noteLines("Codex hasn't recorded its plan limits yet.")
            }
            return limitBars(shown, underHeading: underHeading, now: now)
        default:
            let providers: [String]
            if key == "opencode" {
                // In All AIs a provider tracked on its own shows its rows there.
                let own = underHeading ? Set(strings(d.state["enabled_providers"])) : []
                providers = d.byokProviders.filter { !own.contains($0) }
            } else if Providers.providerNames[key] != nil {
                providers = [key]
            } else {
                providers = []
            }
            let rows = providerLimitItems(d, providers: providers, now: now)
            if rows.isEmpty {
                return [noData] + noteLines("\(name) doesn't record plan limits on this Mac.")
            }
            return rows
        }
    }

    /// Bars for `shown`, then the stale note if they may be out of date.
    /// Under a heading the bars drop the AI's name ("5-hour").
    static func limitBars(_ shown: Limits.Shown, underHeading: Bool, now: Double) -> [Item] {
        var items: [Item] = shown.levels.map { level in
            var sub: String?
            if let resetsAt = level.resetsAt, resetsAt != 0 {
                sub = "Resets \(Limits.formatReset(resetsAt, now: now))"
            }
            let value = level.reached ? "Reached" : String(format: "%.0f%%", level.percent)
            return .bar(label: underHeading ? Limits.windowName(level) : Limits.displayName(level), value: value,
                        fraction: Swift.min(level.percent / 100, 1.0), sub: sub)
        }
        if shown.stale {
            items += noteLines(staleNote(shown.updatedAt, now: now))
        }
        return items
    }

    /// "Last updated 2 hr ago, so this may be out of date."
    static func staleNote(_ updatedAt: Double?, now: Double) -> String {
        guard let updatedAt = updatedAt else {
            return "Last updated at an unknown time, so this may be out of date."
        }
        return "Last updated \(formatAgo(updatedAt, now)), so this may be out of date."
    }

    /// Claude Code: its bars, or why there are none.
    static func claudeSection(_ state: JSONObject, underHeading: Bool, now: Double) -> [Item] {
        let shown = Limits.claudeShown(state, now: now)
        let usage = state.object("claude_usage") ?? [:]
        let percentages = flag(state, "claude_usage_enabled", default: true)
        let error = usage.string("error").flatMap { $0.isEmpty ? nil : $0 }
        var items = [Item]()
        if !shown.levels.isEmpty {
            items = limitBars(shown, underHeading: underHeading, now: now)
        } else if percentages && error == nil {
            items = [.row(label: "Limits", value: "Loading…")]
        } else {
            items = [noData]
        }
        if percentages {
            if let error = error {
                items += noteLines(error)
            }
        } else if !shown.levels.contains(where: \.reached) {
            items += noteLines("Claude Code only records a limit once it's reached. None is reached right now. "
                + "Turn on Percentages from Anthropic in Settings to see how close you are.")
        } else {
            items += noteLines("Claude Code only records a limit once it's reached. "
                + "Turn on Percentages from Anthropic in Settings to see how close you are.")
        }
        return items
    }

    /// Account rows that are not limits.
    static let notLimitRows: Set<String> = ["Models available", "Total spent"]

    /// What `providers` report about their limits: each API key found in
    /// opencode, the balance and rate rows fetched with it or with the key
    /// added in Claude Tracker, and the token limits of the models in use
    /// (or the first five, when none is used yet). Rows that may be out of
    /// date get the stale note, per provider.
    static func providerLimitItems(_ d: PanelData, providers: [String], now: Double) -> [Item] {
        guard !providers.isEmpty else { return [] }
        var items = [Item]()
        let fetched = OpencodeSource.byokState(d.state).object("fetched") ?? [:]
        let accounts = d.state.object("accounts") ?? [:]
        func rows(_ saved: JSONObject, _ prefix: String) -> [Item] {
            (saved.array("rows") ?? []).compactMap { row -> Item? in
                let pair = JSON.array(row) ?? []
                guard pair.count == 2, let label = JSON.string(pair[0]), let value = JSON.string(pair[1]),
                      !notLimitRows.contains(label)
                else { return nil }
                return .row(label: prefix + label, value: value)
            }
        }
        func staleness(_ saved: JSONObject) -> [Item] {
            let at = saved.string("fetched_at").flatMap(LocalTime.parseISO)
            let failed = JSON.truthy(saved["error"])
            guard failed || (at.map { now - $0 > Limits.accountStaleAfter } ?? false) else { return [] }
            return noteLines(staleNote(at, now: now))
        }
        let several = providers.count > 1
        for provider in providers {
            let pName = Providers.providerNames[provider] ?? provider
            let prefix = several ? "\(pName) · " : ""
            var found = [Item]()
            if d.byokProviders.contains(provider) {
                found.append(.row(label: "\(pName) API key", value: "Active (opencode)"))
                if let saved = fetched.object(provider) {
                    let fetchedRows = rows(saved, prefix)
                    found += fetchedRows
                    if !fetchedRows.isEmpty {
                        found += staleness(saved)
                    }
                }
            }
            if strings(d.state["provider_keys"]).contains(provider), let saved = accounts.object(provider) {
                let accountRows = rows(saved, prefix)
                found += accountRows
                if !accountRows.isEmpty {
                    found += staleness(saved)
                }
            }
            items += found
        }
        let wanted = Set(providers)
        let available = d.byokModels.compactMap { id, info -> (id: String, info: JSONObject)? in
            // As in the provider views: a model the integrations disagree on goes by its name.
            let listed = JSON.truthy(info["provider_ambiguous"]) ? nil : info.string("provider")
            guard wanted.contains(listed ?? Providers.providerOf(id) ?? "") else { return nil }
            return (id, info)
        }
        let used = Set(d.lifetimeModels.keys)
        let withLimits = available.filter { ($0.info.int("context") ?? 0) > 0 || ($0.info.int("output") ?? 0) > 0 }
        let sorted = withLimits.sorted { a, b in
            let (aUsed, bUsed) = (used.contains(a.id), used.contains(b.id))
            if aUsed != bUsed { return aUsed }
            return modelDisplayName(a.id, catalog: d.byokModels) < modelDisplayName(b.id, catalog: d.byokModels)
        }
        let inUse = sorted.filter { used.contains($0.id) }
        for entry in inUse.isEmpty ? Array(sorted.prefix(5)) : inUse {
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
            items.append(.row(label: modelDisplayName(entry.id, catalog: d.byokModels), value: limitText))
        }
        return items
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
}
