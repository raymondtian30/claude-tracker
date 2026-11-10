import Foundation

/// app.py's decisions that don't need AppKit: what a setting change does to
/// state.json, which view the panel shows, what's due to be fetched, and the
/// leaderboard's bookkeeping. The app controller does the clicking, the
/// threads and the dialogs around these.
extension AppState {
    /// The strings in a JSON list (anything else is skipped).
    public static func strings(_ value: Any?) -> [String] {
        (JSON.array(value) ?? []).compactMap(JSON.string)
    }

    /// `keys` with `key` added or removed, in `order`.
    static func toggled(_ keys: [String], _ key: String, on: Bool, order: [String]) -> [String] {
        var set = Set(keys)
        if on { set.insert(key) } else { set.remove(key) }
        return order.filter(set.contains)
    }

    // MARK: - Chart range

    /// What a Home chart choice does to state.json (any other action does
    /// nothing). Custom starts as the last 30 days the first time; after that
    /// it keeps the dates picked. The dates stay in order, not after `today`
    /// and not before `earliest` (the first day with usage, when there is one).
    public static func applyChart(_ action: AppAction, to state: inout JSONObject, today: Day,
                                  earliest: Day? = nil) {
        let low = Swift.min(earliest ?? Day.min, today)
        func day(_ key: String) -> Day? { state.string(key).flatMap { Day(iso: $0) } }
        switch action {
        case .chartDays(let days):
            state["chart_mode"] = "days"
            state["chart_days"] = days
        case .chartAll:
            state["chart_mode"] = "all"
        case .chartCustom:
            state["chart_mode"] = "custom"
            if day("chart_from") == nil || day("chart_to") == nil {
                state["chart_from"] = today.adding(days: -29).iso
                state["chart_to"] = today.iso
            }
        case .chartFrom(let picked):
            let from = Swift.min(Swift.max(picked, low), today)
            state["chart_from"] = from.iso
            state["chart_to"] = Swift.max(day("chart_to") ?? today, from).iso
        case .chartTo(let picked):
            let to = Swift.min(Swift.max(picked, low), today)
            state["chart_to"] = to.iso
            state["chart_from"] = Swift.min(day("chart_from") ?? to, to).iso
        default:
            break
        }
    }

    // MARK: - AIs

    /// Turn a tool on or off in Settings, keeping `Tools.tools` order.
    public static func setToolEnabled(_ state: inout JSONObject, _ key: String, _ on: Bool) {
        state["enabled_tools"] = toggled(strings(state["enabled_tools"]), key, on: on,
                                         order: Tools.tools.map(\.key))
    }

    /// Turn a provider on or off in Settings, keeping `Providers.providers` order.
    public static func setProviderEnabled(_ state: inout JSONObject, _ key: String, _ on: Bool) {
        state["enabled_providers"] = toggled(strings(state["enabled_providers"]), key, on: on,
                                             order: Providers.providers.map(\.key))
    }

    /// The welcome picker's choices after one switch: the key moves to the end
    /// when turned on, as app.py's list does.
    public static func welcomeChoice(_ chosen: [String], _ key: String, _ on: Bool) -> [String] {
        chosen.filter { $0 != key } + (on ? [key] : [])
    }

    /// "Continue" in the welcome picker: track the chosen tools (in
    /// `Tools.tools` order), show the first, and don't ask again.
    public static func finishWelcome(_ state: inout JSONObject, chosen: [String]) {
        let tools = Tools.tools.map(\.key).filter(chosen.contains)
        state["enabled_tools"] = tools
        if let first = tools.first {
            state["selected_tool"] = first
        }
        state["onboarding_done"] = true
    }

    /// A provider key was saved to the Keychain: note it, and drop numbers
    /// fetched with an older key.
    public static func addProviderKey(_ state: inout JSONObject, _ provider: String) {
        var keys = Set(strings(state["provider_keys"]))
        keys.insert(provider)
        state["provider_keys"] = Providers.providers.map(\.key).filter(keys.contains)
        dropAccount(&state, provider)
    }

    /// A provider key was deleted from the Keychain.
    public static func removeProviderKey(_ state: inout JSONObject, _ provider: String) {
        state["provider_keys"] = strings(state["provider_keys"]).filter { $0 != provider }
        dropAccount(&state, provider)
    }

    private static func dropAccount(_ state: inout JSONObject, _ provider: String) {
        if var accounts = state.object("accounts") {
            accounts[provider] = nil
            state["accounts"] = accounts
        }
    }

    // MARK: - Alerts and limits

    /// The alerted windows after one window's switch, in `Limits.windows` order.
    public static func setAlertWindow(_ state: inout JSONObject, _ window: String, _ on: Bool) {
        state["alert_windows"] = toggled(strings(state["alert_windows"]), window, on: on,
                                         order: Limits.windows.map(\.key))
    }

    /// The picked thresholds. Keeps at least one: "Notify me" is the way to
    /// turn alerts off. False if nothing changed.
    @discardableResult
    public static func setAlertThresholds(_ state: inout JSONObject, _ thresholds: [Int]) -> Bool {
        guard !thresholds.isEmpty else { return false }
        state["alert_thresholds"] = thresholds
        return true
    }

    /// "Percentages from Anthropic": turning it off forgets the last fetch.
    public static func setClaudeUsageEnabled(_ state: inout JSONObject, _ on: Bool) {
        state["claude_usage_enabled"] = on
        if !on {
            state["claude_usage"] = nil
        }
    }

    /// Messages for limits that just reached an alert threshold. Updates
    /// state["alerts_above"]; `changed` says whether it did (so it's saved).
    /// `seeding` is the process's first pass: keys are saved, nothing is sent.
    public static func checkAlerts(_ state: inout JSONObject, now: Double, seeding: Bool = false)
        -> (messages: [String], changed: Bool) {
        guard JSON.truthy(state["alerts_enabled"]) else { return ([], false) }
        let levels = Limits.levelsForAlerts(state, now: now)
        let thresholds = (JSON.array(state["alert_thresholds"]) ?? []).compactMap(JSON.int)
        let before = strings(state["alerts_above"])
        let (messages, above) = Limits.alertsToSend(levels, thresholds: thresholds,
                                                    windowsOn: strings(state["alert_windows"]),
                                                    above: before, seeding: seeding,
                                                    unknownIDPrefixes: Limits.unknownIDPrefixes(state, now: now),
                                                    now: now)
        let changed = above != before
        if changed {
            state["alerts_above"] = above
        }
        return (messages, changed)
    }

    // MARK: - Which view the panel shows

    /// The view the panel and menu bar show: the selected tool or provider,
    /// or every enabled tool combined.
    public static func currentView(_ state: JSONObject, detected: [String]) -> Tools.View {
        let enabled = strings(state["enabled_tools"])
        let choices = PanelModel.viewChoices(state, detected: detected).map(\.key)
        guard let firstSingle = choices.first(where: { $0 != "all" }) else {
            return Tools.combinedView(state, enabled: enabled)
        }
        let selected = state.string("selected_tool") ?? ""
        // Fall back to the first tool, not "All AIs", as before it existed.
        let key = choices.contains(selected) ? selected : firstSingle
        if key == "all" {
            return Tools.combinedView(state, enabled: enabled)
        }
        if Providers.providerNames[key] != nil {
            return Providers.providerView(state, key)
        }
        return Tools.toolView(state, key)
    }

    /// The tools whose running sessions the Live tab lists for `viewKey`:
    /// none for a provider (a session can't be tied to one).
    public static func sessionTools(_ viewKey: String, enabled: [String]) -> [String] {
        if Providers.providerNames[viewKey] != nil {
            return []
        }
        return viewKey == "all" ? enabled : [viewKey]
    }

    /// Whether the Live tab lists plugins: only Claude Code has them.
    public static func showsPlugins(_ viewKey: String, enabled: [String]) -> Bool {
        viewKey == "claude_code" || (viewKey == "all" && enabled.contains("claude_code"))
    }

    /// The menu bar's count for `view` in `titleMode`, or nil in icon-only mode.
    public static func menuBarCount(_ view: Tools.View, titleMode: String?, today: Day) -> String? {
        switch titleMode {
        case "today":
            return TokenMath.formatCount(UsageStats.totalInRange(view.daily, today, today))
        case "icon":
            return nil
        default:
            return TokenMath.formatCount(view.grandTotal)
        }
    }

    // MARK: - Background fetches

    /// Providers whose account numbers should be fetched now: enabled, with
    /// a key, not already being fetched, and due (every 15 minutes) or `force`d.
    public static func accountsToFetch(_ state: JSONObject, inFlight: Set<String>, force: String? = nil,
                                       now: Double = Date().timeIntervalSince1970) -> [String] {
        let saved = state.object("accounts") ?? [:]
        let keys = strings(state["provider_keys"])
        return strings(state["enabled_providers"]).filter { key in
            keys.contains(key) && !inFlight.contains(key)
                && (key == force || Accounts.accountDue(saved.object(key), now: now))
        }
    }

    /// A failed account fetch's result, shaped like a good one so it can be
    /// stored (its numbers stay empty).
    public static func failedAccountResult(_ error: String, now: Double) -> JSONObject {
        ["daily": JSONObject(), "cost": JSONObject(), "rows": [Any](), "notes": [Any](),
         "error": error, "fetched_at": Accounts.isoSeconds(now)]
    }

    /// Whether to fetch Claude Code's limit percentages now: every 5 minutes
    /// while Claude Code is tracked and the switch is on.
    public static func claudeUsageDue(_ state: JSONObject, inFlight: Bool,
                                      now: Double = Date().timeIntervalSince1970) -> Bool {
        !inFlight && JSON.truthy(state["claude_usage_enabled"])
            && strings(state["enabled_tools"]).contains("claude_code")
            && ClaudeUsage.usageDue(state.object("claude_usage"), now: now)
    }

    // MARK: - Leaderboard

    /// What's shared in your gist.
    public static func leaderboardPayload(_ state: JSONObject, yesterdayTokens: Int, today: Day) -> JSONObject {
        let name = JSON.truthy(state["leaderboard_name"]) ? state["leaderboard_name"]! : "Anonymous"
        return [
            "name": name,
            "total_tokens": state["grand_total"] ?? 0,
            "yesterday_tokens": yesterdayTokens,
            "updated_at": today.iso,
        ]
    }

    /// `friends` with a new friend for `gistID`, or nil if they're already there.
    public static func addingFriend(_ friends: [JSONObject], gistID: String) -> [JSONObject]? {
        if friends.contains(where: { $0.string("gist_id") == gistID }) {
            return nil
        }
        return friends + [["gist_id": gistID, "name": gistID, "total_tokens": 0, "yesterday_tokens": 0]]
    }

    /// Each friend's latest numbers from their gist; a friend whose gist
    /// can't be read keeps the numbers they had.
    public static func pulledFriends(_ friends: [JSONObject], fetch: (String) throws -> Any) -> [JSONObject] {
        friends.map { friend in
            guard let gistID = friend.string("gist_id"),
                  let data = (try? fetch(gistID)).flatMap(JSON.object)
            else { return friend }
            return [
                "gist_id": gistID,
                "name": data["name"] ?? friend["name"] ?? "Friend",
                "total_tokens": data["total_tokens"] ?? 0,
                "yesterday_tokens": data["yesterday_tokens"] ?? 0,
            ]
        }
    }

    /// Whether the once-a-day push and pull is due.
    public static func leaderboardSyncDue(_ state: JSONObject, today: Day) -> Bool {
        PanelModel.leaderboardEnabled(state) && state.string("last_leaderboard_sync_date") != today.iso
    }
}
