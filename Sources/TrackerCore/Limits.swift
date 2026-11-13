import Foundation

/// Usage limits: each tool's real plan limits, and when to send an alert
/// about them.
///
/// - Codex saves its plan's limits in its session logs (percent used, window
///   length, reset time), so those are exact. Which windows it has depends on
///   the plan: the free plan has one 30-day window, paid plans a 5-hour and a
///   weekly one.
/// - Claude Code's percentages (5-hour and weekly) come from Anthropic (see
///   ClaudeUsage). Without them, its logs still say when a limit was
///   reached, which shows as 100% until the reset.
///
/// Kept free of AppKit so it can be unit-tested.
public enum Limits {
    public static let windows: [(key: String, label: String)] = [
        ("five_hour", "5-hour"), ("weekly", "Weekly"), ("monthly", "Monthly"),
    ]
    public static let windowLabels: [String: String] = Dictionary(
        uniqueKeysWithValues: windows.map { ($0.key, $0.label) })
    // Claude Code's plans have a 5-hour and a weekly limit.
    public static let claudeWindows = ["five_hour", "weekly"]

    public static let alertThresholds = [50, 60, 70, 75, 80, 90, 95]
    public static let defaultAlertThreshold = 75

    // Claude Code's names for its limits -> the app's windows.
    public static let claudeLimitTypes = [
        "five_hour": "five_hour", "seven_day": "weekly",
        "seven_day_opus": "weekly", "seven_day_sonnet": "weekly",
    ]

    /// The kind Anthropic gives the limits that share a window with another
    /// ("weekly_opus"), for Claude's own names for them. Fallback levels use
    /// it so their ids match the fetched ones.
    public static let claudeLimitKinds = [
        "seven_day_opus": "weekly_opus", "seven_day_sonnet": "weekly_sonnet",
    ]

    /// One plan limit and how much of it is used. As an alert level it also
    /// has `id` ("tool:kind") and `name` (the tool's name).
    public struct Level: Equatable {
        public var id: String = ""
        public var name: String = ""
        /// Claude's own kind of limit, from Anthropic ("five_hour",
        /// "weekly_opus"...); nil for limits read from logs.
        public var kind: String?
        public var window: String
        public var label: String
        public var percent: Double
        public var resetsAt: Double?
        /// True for a Claude Code limit its logs say was reached.
        public var reached: Bool = false

        public init(id: String = "", name: String = "", kind: String? = nil, window: String,
                    label: String, percent: Double, resetsAt: Double?, reached: Bool = false) {
            self.id = id
            self.name = name
            self.kind = kind
            self.window = window
            self.label = label
            self.percent = percent
            self.resetsAt = resetsAt
            self.reached = reached
        }

        /// A limit as ClaudeUsage stores it in state.json: {"kind", "window",
        /// "label", "percent", "resets_at"}.
        public init?(json: JSONObject) {
            guard let window = json.string("window"), let percent = json.double("percent") else {
                return nil
            }
            self.init(kind: json.string("kind"), window: window,
                      label: json.string("label") ?? windowLabels[window] ?? window,
                      percent: percent, resetsAt: json.double("resets_at"),
                      reached: json.bool("reached") ?? false)
        }

        /// The state.json shape `init(json:)` reads.
        public var json: JSONObject {
            var object: JSONObject = ["window": window, "label": label, "percent": percent,
                                      "resets_at": resetsAt.map { $0 as Any } ?? NSNull()]
            if let kind = kind {
                object["kind"] = kind
            }
            if reached {
                object["reached"] = true
            }
            return object
        }
    }

    public static func windowForMinutes(_ minutes: Double) -> String {
        if minutes <= 12 * 60 {
            return "five_hour"
        }
        if minutes <= 14 * 24 * 60 {
            return "weekly"
        }
        return "monthly"
    }

    /// Codex's limits from its latest `rate_limits` record. A window whose
    /// reset time has passed reads 0% until Codex records a new one.
    public static func codexLimits(_ rateLimits: JSONObject?, now: Double) -> [Level] {
        var limits = [Level]()
        for slot in ["primary", "secondary"] {
            guard let info = rateLimits?.object(slot), !info.isEmpty,
                  let minutes = info.double("window_minutes")
            else { continue }
            let window = windowForMinutes(minutes)
            let resetsAt = info.double("resets_at")
            let reset = resetsAt.map { $0 <= now } ?? false
            limits.append(Level(window: window, label: windowLabels[window]!,
                                percent: reset ? 0.0 : (info.double("used_percent") ?? 0.0),
                                resetsAt: reset ? nil : resetsAt))
        }
        return limits
    }

    /// Claude Code's reached limits ({limit type: reset time}) that haven't
    /// reset yet, at 100%.
    public static func reachedClaudeLimits(_ hits: JSONObject?, now: Double) -> [Level] {
        var limits = [Level]()
        for kind in (hits ?? [:]).keys.sorted() {
            let window = claudeLimitTypes[kind] ?? "five_hour"
            if let resetsAt = hits?.double(kind), resetsAt != 0, resetsAt > now {
                limits.append(Level(kind: claudeLimitKinds[kind], window: window,
                                    label: windowLabels[window]!, percent: 100.0,
                                    resetsAt: resetsAt, reached: true))
            }
        }
        return limits
    }

    /// Claude Code's limits: Anthropic's percentages if the last fetch
    /// worked, else the reached limits from its logs. A limit whose reset time
    /// has passed reads 0% until the next fetch.
    public static func claudeLimits(_ state: JSONObject, now: Double) -> [Level] {
        let usage = state.object("claude_usage") ?? [:]
        let fetched = (usage.array("limits") ?? []).compactMap { JSON.object($0).flatMap(Level.init(json:)) }
        let enabled = state["claude_usage_enabled"].map { JSON.truthy($0) } ?? true
        if enabled, !fetched.isEmpty {
            // A reset time of 0 means "not known", the same as none.
            return clearingPassedResets(fetched, now: now)
        }
        return reachedClaudeLimits(state.object("claude_limit_hits"), now: now)
    }

    /// "3:30 PM" for a reset later today, "Nov 20" for a later day.
    public static func formatReset(_ resetsAt: Double, now: Double) -> String {
        let reset = LocalTime.parts(of: resetsAt)
        if reset.day == Day(timestamp: now) {
            let hour = reset.hour % 12 == 0 ? 12 : reset.hour % 12
            return String(format: "%d:%02d %@", hour, reset.minute, reset.hour < 12 ? "AM" : "PM")
        }
        return "\(monthAbbreviations[reset.day.month - 1]) \(reset.day.day)"
    }

    /// strftime's "%b" in the C locale Python uses.
    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Which alerts to send now. A message names the threshold that was crossed
    /// ("usage reached 50%"), even if the percentage is a little past it by the
    /// time it is noticed. `thresholds` are the percents to alert at;
    /// `above` lists "id@threshold" keys already alerted and still over that
    /// threshold. Returns (messages, new `above`). A level alerts once when it
    /// reaches each threshold, and again only after it has dropped back below it
    /// (e.g. when its window resets). Passing several thresholds at once (75 and
    /// 90 on the way to 95) sends one alert, not one per threshold.
    ///
    /// A level missing from `levels` keeps its keys only when that means
    /// "unknown" and not "gone": its id is present with its window switched off,
    /// or its prefix ("claude_code:") is in `unknownIDPrefixes`. Otherwise the
    /// keys are dropped, so the level alerts again when it comes back.
    /// `seeding` (the first pass after launch) records keys and sends nothing.
    public static func alertsToSend(_ levels: [Level], thresholds: [Int], windowsOn: [String],
                                    above: [String], seeding: Bool = false,
                                    unknownIDPrefixes: Set<String> = [],
                                    now: Double? = nil) -> (messages: [String], above: [String]) {
        var messages = [String]()
        var newAbove = [String]()
        var activeIDs = Set<String>()
        for level in levels where windowsOn.contains(level.window) {
            activeIDs.insert(level.id)
            let keys = thresholds.sorted().filter { level.percent >= Double($0) }.map { "\(level.id)@\($0)" }
            newAbove += keys
            if seeding || keys.allSatisfy({ above.contains($0) }) {
                continue
            }
            // The threshold that was crossed, not the percentage at the moment
            // of looking: Claude's percentages arrive every few minutes, so a
            // 50% alert that went out at 54% should still say 50%. Of several
            // crossed at once, the highest new one. A limit that is full says 100%.
            let fresh = thresholds.sorted().filter { level.percent >= Double($0) && !above.contains("\(level.id)@\($0)") }
            let crossed = level.percent >= 100 || level.reached ? 100 : (fresh.last ?? 0)
            var message = "\(displayName(level)) usage reached \(crossed)%."
            if let resetsAt = level.resetsAt, resetsAt != 0 {
                let when = formatReset(resetsAt, now: now ?? Date().timeIntervalSince1970)
                let startsWithDigit = when.first?.isNumber ?? false
                message += " Resets \(startsWithDigit ? "at" : "on") \(when)."
            }
            messages.append(message)
        }
        let presentIDs = Set(levels.map(\.id))
        for key in above where !newAbove.contains(key) {
            guard let at = key.lastIndex(of: "@") else { continue }
            let id = String(key[..<at])
            if activeIDs.contains(id) {
                continue  // present and switched on: below this threshold now
            }
            let prefix = id.firstIndex(of: ":").map { String(id[...$0]) } ?? id
            if presentIDs.contains(id) || unknownIDPrefixes.contains(prefix) {
                newAbove.append(key)
            }
        }
        return (messages, newAbove)
    }

    /// The id prefixes ("claude_code:") whose levels are missing because they
    /// are unknown right now, not gone: a disabled tool; Claude Code while
    /// Percentages from Anthropic is on and the fetched list is empty (the
    /// fetch failed or has not happened); Codex with no rate-limit record.
    static func unknownIDPrefixes(_ state: JSONObject, now: Double) -> Set<String> {
        var prefixes = Set<String>()
        let enabled = Set((state.array("enabled_tools") ?? []).compactMap(JSON.string))
        for tool in Tools.tools.map(\.key) where !enabled.contains(tool) {
            prefixes.insert("\(tool):")
        }
        let usage = state.object("claude_usage") ?? [:]
        let fetched = (usage.array("limits") ?? []).compactMap { JSON.object($0).flatMap(Level.init(json:)) }
        let percentages = state["claude_usage_enabled"].map { JSON.truthy($0) } ?? true
        if percentages, fetched.isEmpty {
            prefixes.insert("claude_code:")
        }
        let codex = state.object("sources")?.object("codex") ?? [:]
        if CodexSource.codexRateLimits(codex) == nil {
            prefixes.insert("codex:")
        }
        return prefixes
    }

    /// Before several thresholds could be picked, state had one
    /// "alert_threshold" and alerted ids without "@threshold": carry both over.
    public static func migrateAlertState(_ state: inout JSONObject) {
        if state["alert_thresholds"] == nil {
            let old = state.int("alert_threshold") ?? defaultAlertThreshold
            state["alert_threshold"] = nil
            state["alert_thresholds"] = [old]
            let keys = (state.array("alerts_above") ?? []).compactMap(JSON.string)
            state["alerts_above"] = keys.map { $0.contains("@") ? $0 : "\($0)@\(old)" }
        }
        if state["alerts_above"] == nil {
            state["alerts_above"] = [String]()
        }
    }

    /// One name for a limit, in the panel and in notifications:
    /// "Tool (Window)", or "Tool (Window, Model)" when Claude gives the
    /// limit its own kind ("weekly_opus" gives "Opus"). Never built from the
    /// saved `label`, so it needs no migration.
    public static func displayName(_ level: Level) -> String {
        let prefix = level.id.firstIndex(of: ":").map { String(level.id[..<$0]) } ?? level.id
        let tool = [level.name, Tools.toolNames[prefix] ?? "", prefix].first { !$0.isEmpty } ?? ""
        return "\(tool) (\(windowName(level)))"
    }

    /// The window part of `displayName`: "5-hour", "Weekly, Opus". Used on
    /// its own under a heading that names the tool.
    public static func windowName(_ level: Level) -> String {
        var window = windowLabels[level.window] ?? level.label
        // A window the app doesn't know has its limit's name in its label already.
        if windowLabels[level.window] != nil, let kind = level.kind, kind != level.window,
           kind.hasPrefix(level.window + "_") {
            let words = kind.dropFirst(level.window.count + 1).split(separator: "_")
            if !words.isEmpty {
                window += ", " + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
        }
        return window
    }

    /// The real plan limits recorded for `toolKeys`, as alert levels.
    public static func planLevels(_ state: JSONObject, toolKeys: [String], now: Double) -> [Level] {
        var levels = [Level]()
        for key in toolKeys {
            let found: [Level]
            if key == "claude_code" {
                found = claudeLimits(state, now: now)
            } else if key == "codex" {
                let codex = state.object("sources")?.object("codex") ?? [:]
                found = codexLimits(CodexSource.codexRateLimits(codex), now: now)
            } else {
                continue
            }
            levels += named(found, key)
        }
        return levels
    }

    /// The Claude Code plan limit for all models that is hit right now, if any:
    /// one its logs say was reached, or Anthropic's percentage at 100, and not
    /// yet reset.
    /// The 5-hour window comes first when several are. While one is hit, the
    /// Live tab shows running sessions as paused by it.
    public static func hitClaudeLimit(_ state: JSONObject, now: Double) -> Level? {
        let hit = planLevels(state, toolKeys: ["claude_code"], now: now).filter { level in
            // A limit for one model (Opus only, say) does not stop sessions on others:
            // only the all-model limits, whose kind is their window's own, count.
            (level.kind == nil || level.kind == level.window)
                && (level.reached || level.percent >= 100) && (level.resetsAt ?? 0 == 0 || (level.resetsAt ?? 0) > now)
        }
        return hit.first { $0.window == "five_hour" } ?? hit.first
    }

    /// The windows `toolKeys` have limits in, in `windows` order: Claude
    /// Code's two, plus whichever Codex has recorded.
    public static func limitWindows(_ state: JSONObject, toolKeys: [String], now: Double) -> [String] {
        var found = Set(planLevels(state, toolKeys: toolKeys, now: now).map(\.window))
        if toolKeys.contains("claude_code") {
            found.formUnion(claudeWindows)
        }
        return windows.map(\.key).filter(found.contains)
    }

    /// Everything an alert can be about: the plan limits of the enabled tools.
    public static func levelsForAlerts(_ state: JSONObject, now: Double) -> [Level] {
        let enabled = (state.array("enabled_tools") ?? []).compactMap(JSON.string)
        return planLevels(state, toolKeys: enabled, now: now)
    }
}

// MARK: - What the Limits tab shows

extension Limits {
    /// The AIs the Limits tab has a section for: in All AIs every tracked
    /// tool, then every tracked provider (each in the app's own order); in one
    /// AI's view just that AI.
    public static func trackedKeys(_ viewKey: String, state: JSONObject) -> [String] {
        if viewKey == "all" {
            let tools = Set((state.array("enabled_tools") ?? []).compactMap(JSON.string))
            let providers = Set((state.array("enabled_providers") ?? []).compactMap(JSON.string))
            return Tools.tools.map(\.key).filter(tools.contains)
                + Providers.providers.map(\.key).filter(providers.contains)
        }
        return Tools.toolNames[viewKey] != nil || Providers.providerNames[viewKey] != nil ? [viewKey] : []
    }

    /// Claude's percentages are fetched every 5 minutes: three missed
    /// fetches make them old.
    public static let claudeStaleAfter = 3 * ClaudeUsage.refreshSeconds
    /// Codex writes its numbers only on a turn, so they go old more slowly
    /// than a fetch would (a note every 15 minutes would mean nothing).
    public static let codexStaleAfter = 60.0 * 60
    /// Provider accounts and API keys are fetched every 15 minutes.
    public static let accountStaleAfter = 3 * Accounts.refreshSeconds

    /// Limits for the Limits tab, with how old they are. `updatedAt` is when
    /// the numbers were read (nil when not known); `stale` says they may be
    /// out of date: too old, the latest fetch failed, or a reset time has
    /// passed since (the 0% shown then is a guess).
    public struct Shown: Equatable {
        public var levels: [Level]
        public var updatedAt: Double?
        public var stale: Bool
    }

    /// Whether any of `raw` (as saved, before a passed reset reads 0%)
    /// reset after `updatedAt` and by `now`.
    static func resetSince(_ raw: [Level], updatedAt: Double?, now: Double) -> Bool {
        raw.contains { level in
            guard let resetsAt = level.resetsAt, resetsAt > 0 else { return false }
            return resetsAt <= now && resetsAt > (updatedAt ?? 0)
        }
    }

    /// A passed reset reads 0% with no reset time (as `claudeLimits` does).
    static func clearingPassedResets(_ levels: [Level], now: Double) -> [Level] {
        levels.map { level in
            var level = level
            if let resetsAt = level.resetsAt, resetsAt > 0, resetsAt <= now {
                level.percent = 0.0
                level.resetsAt = nil
            }
            return level
        }
    }

    static func named(_ levels: [Level], _ key: String) -> [Level] {
        levels.map { limit in
            var level = limit
            level.id = "\(key):\(limit.kind ?? limit.window)"
            level.name = Tools.toolNames[key] ?? key
            return level
        }
    }

    /// Claude Code for the Limits tab: Anthropic's latest answer; if that
    /// failed, its last good answer (stale), with any limit its logs say is
    /// reached put over it; else the reached limits from its logs.
    public static func claudeShown(_ state: JSONObject, now: Double) -> Shown {
        let usage = state.object("claude_usage") ?? [:]
        let enabled = state["claude_usage_enabled"].map { JSON.truthy($0) } ?? true
        func parse(_ list: [Any]?) -> [Level] {
            (list ?? []).compactMap { JSON.object($0).flatMap(Level.init(json:)) }
        }
        func time(_ value: Any?) -> Double? {
            JSON.double(value).flatMap { $0 > 0 ? $0 : nil }
        }
        let fetched = parse(usage.array("limits"))
        if enabled, !fetched.isEmpty {
            let at = time(usage["fetched_at"])
            let stale = at.map { now - $0 > claudeStaleAfter } ?? true
                || resetSince(fetched, updatedAt: at, now: now)
            return Shown(levels: named(clearingPassedResets(fetched, now: now), "claude_code"),
                         updatedAt: at, stale: stale)
        }
        let reached = reachedClaudeLimits(state.object("claude_limit_hits"), now: now)
        let lastGood = usage.object("last_good") ?? [:]
        let old = parse(lastGood.array("limits"))
        if enabled, !old.isEmpty {
            var levels = clearingPassedResets(old, now: now)
            for hit in reached {
                let key = hit.kind ?? hit.window
                if let index = levels.firstIndex(where: { ($0.kind ?? $0.window) == key }) {
                    levels[index] = hit
                } else {
                    levels.append(hit)
                }
            }
            return Shown(levels: named(levels, "claude_code"), updatedAt: time(lastGood["fetched_at"]), stale: true)
        }
        return Shown(levels: named(reached, "claude_code"), updatedAt: nil, stale: false)
    }

    /// Codex for the Limits tab: its plan's newest record.
    public static func codexShown(_ state: JSONObject, now: Double) -> Shown {
        let codex = state.object("sources")?.object("codex") ?? [:]
        let rateLimits = CodexSource.codexRateLimits(codex)
        let levels = codexLimits(rateLimits, now: now)
        let at = CodexSource.codexRateLimitsAt(codex)
        let raw = ["primary", "secondary"].compactMap { slot -> Level? in
            guard let resetsAt = rateLimits?.object(slot)?.double("resets_at") else { return nil }
            return Level(window: "five_hour", label: "", percent: 0, resetsAt: resetsAt)
        }
        let stale = !levels.isEmpty
            && ((at.map { now - $0 > codexStaleAfter } ?? true) || resetSince(raw, updatedAt: at, now: now))
        return Shown(levels: named(levels, "codex"), updatedAt: at, stale: stale)
    }
}

/// How many free resets of a usage limit are left. The app only shows a number
/// a source reports; today none does (not Anthropic's usage answer, not Claude
/// Code's local files, not Codex's `rate_limits`), so `current` says
/// unavailable and why. A source that appears later fills in `available`, and
/// the `switch` in `PanelModel.freeResetsCard` makes the compiler point at
/// every place that has to show it.
public enum FreeResets: Equatable {
    case available(count: Int, renewsAt: Double?)
    case unavailable(reason: String)

    /// What is known now. Never a guessed number.
    public static func current(_ state: JSONObject, now: Double) -> FreeResets {
        .unavailable(reason: "No count is reported anywhere this app reads.")
    }
}
