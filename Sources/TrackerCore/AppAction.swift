import Foundation

/// What a click in the panel or the Settings window asks the app to do.
///
/// Controls hand back an action string and a value (see `ActionValue`), as
/// app.py's `handle_action(action, value)` got them. `parse` turns the pair
/// into one of these cases, reading indexes into the option lists they came
/// from, so the app controller only has to act on them.
public enum AppAction: Equatable {
    // Panel chrome
    case quit
    case openSettings
    case selectTool(index: Int)
    // Welcome picker
    case welcomeTool(key: String, on: Bool)
    case welcomeDone
    // AIs
    case tool(key: String, on: Bool)
    case provider(key: String, on: Bool)
    case providerKey(String)
    case providerKeyRemove(String)
    // Leaderboard
    case leaderboardSetup
    case leaderboardShare
    case leaderboardAdd
    case leaderboardPush
    case leaderboardPull
    case leaderboardView(String)
    case leaderboardEnabled(Bool)
    // Menu bar and look
    case titleMode(String)
    case menuBarFontSize(Int)
    case appearance(String)
    case panelAnimation(String)
    // Usage limit alerts
    case alertsEnabled(Bool)
    case alertThresholds([Int])
    case alertWindow(window: String, on: Bool)
    case alertTest
    case claudeUsageEnabled(Bool)
    // General
    case scanInterval(seconds: Int)
    case login(Bool)
    case projectsExpand
    // Live tab: pause, carry on, or end a Claude Code session's process
    case sessionStop(Int32)
    case sessionResume(Int32)
    case sessionQuit(Int32)
    case sessionsStopAll
    case sessionsQuitAll
    case sessionsResumeAll
    /// Opens the session diagnostics window (Settings > Scanning).
    case sessionDiagnostics
    case showEffort(Bool)
    case chartDays(Int)
    case chartAll
    case chartCustom
    /// "Change dates": opens the Custom range page again.
    case chartEdit
    /// Cancel on the Custom range page.
    case chartCancel
    /// Both Custom dates, once the check mark is clicked.
    case chartRange(Day, Day)
    case currency(String)
    /// How the models card orders models: a `ModelTiers.Order` raw value.
    case modelSort(String)
    case aboutView(showCredits: Bool)
    case checkUpdates
    case openRepo
    // Expandable rows
    case toggleRow(id: String)

    /// The case for `action` and `value`, or nil for one the app doesn't
    /// handle (or an index outside its options). `scanIntervals` are the
    /// Settings window's "Scan every" choices.
    public static func parse(_ action: String, _ value: ActionValue,
                             scanIntervals: [Int] = AppState.scanIntervalChoices) -> AppAction? {
        // Python's action.partition(":"): "provider_key:openai" -> name and argument.
        let name: String
        let argument: String
        if let colon = action.firstIndex(of: ":") {
            name = String(action[..<colon])
            argument = String(action[action.index(after: colon)...])
        } else {
            (name, argument) = (action, "")
        }
        let isOn = value.isOn

        switch action {
        case "quit": return .quit
        case "open_settings": return .openSettings
        case "leaderboard_setup": return .leaderboardSetup
        case "leaderboard_share": return .leaderboardShare
        case "leaderboard_add": return .leaderboardAdd
        case "leaderboard_push": return .leaderboardPush
        case "leaderboard_pull": return .leaderboardPull
        case "leaderboard_view":
            return pick(value, PanelModel.leaderboardViews.map(\.key)).map(AppAction.leaderboardView)
        case "title_mode":
            return pick(value, PanelModel.titleModes.map(\.key)).map(AppAction.titleMode)
        case "menu_bar_font_size":
            return pick(value, PanelModel.menuBarFontSizes).map(AppAction.menuBarFontSize)
        case "appearance":
            return pick(value, PanelSpeeds.appearances.map(\.key)).map(AppAction.appearance)
        case "panel_animation":
            return pick(value, PanelSpeeds.animationSpeeds.map(\.key)).map(AppAction.panelAnimation)
        case "alerts_enabled": return .alertsEnabled(isOn)
        case "alert_thresholds":
            guard case .indices(let picked) = value,
                  picked.allSatisfy(Limits.alertThresholds.indices.contains)
            else { return nil }
            return .alertThresholds(picked.map { Limits.alertThresholds[$0] })
        case "alert_test": return .alertTest
        case "claude_usage_enabled": return .claudeUsageEnabled(isOn)
        case "scan_interval":
            return pick(value, scanIntervals).map { .scanInterval(seconds: $0) }
        case "login": return .login(isOn)
        case "leaderboard_enabled": return .leaderboardEnabled(isOn)
        case "projects_expand": return .projectsExpand
        case "sessions_stop_all": return .sessionsStopAll
        case "sessions_quit_all": return .sessionsQuitAll
        case "sessions_resume_all": return .sessionsResumeAll
        case "session_diagnostics": return .sessionDiagnostics
        case "show_effort": return .showEffort(isOn)
        case "chart_days":
            // The day counts, then "All", then "Custom".
            if case .index(let index) = value, index >= PanelModel.chartRanges.count {
                return [AppAction.chartAll, .chartCustom][safe: index - PanelModel.chartRanges.count]
            }
            return pick(value, PanelModel.chartRanges).map(AppAction.chartDays)
        case "chart_edit": return .chartEdit
        case "chart_cancel": return .chartCancel
        case "chart_range":
            guard case .text(let text) = value else { return nil }
            let days = text.split(separator: ",", omittingEmptySubsequences: false).map { Day(iso: String($0)) }
            guard days.count == 2, let from = days[0], let to = days[1] else { return nil }
            return .chartRange(from, to)
        case "currency": return pick(value, Pricing.currencies.map(\.code)).map(AppAction.currency)
        case "model_sort": return pick(value, ModelTiers.choices.map(\.order.rawValue)).map(AppAction.modelSort)
        case "about_view":
            return pick(value, [false, true]).map { .aboutView(showCredits: $0) }
        case "check_updates": return .checkUpdates
        case "open_repo": return .openRepo
        case "select_tool":
            guard case .index(let index) = value else { return nil }
            return .selectTool(index: index)
        case "welcome_done": return .welcomeDone
        default:
            break
        }
        switch name {
        // Only providers with an account API have a key.
        case "provider_key" where Accounts.keyHelp[argument] != nil: return .providerKey(argument)
        case "provider_key_remove" where Accounts.keyHelp[argument] != nil: return .providerKeyRemove(argument)
        case "session_stop": return processID(argument).map(AppAction.sessionStop)
        case "session_resume": return processID(argument).map(AppAction.sessionResume)
        case "session_quit": return processID(argument).map(AppAction.sessionQuit)
        case "provider" where Providers.providerNames[argument] != nil: return .provider(key: argument, on: isOn)
        case "alert_window": return .alertWindow(window: argument, on: isOn)
        case "toggle_row" where !argument.isEmpty: return .toggleRow(id: argument)
        case "welcome_tool": return .welcomeTool(key: argument, on: isOn)
        case "tool": return .tool(key: argument, on: isOn)
        default: return nil
        }
    }

    /// A process id to signal: plain digits, above 1 (0, 1 and negative ids mean
    /// every process, launchd or a whole group).
    private static func processID(_ text: String) -> Int32? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
              let pid = Int32(text), pid > 1
        else { return nil }
        return pid
    }

    /// `options[index]` for a popup or segmented control's pick.
    private static func pick<T>(_ value: ActionValue, _ options: [T]) -> T? {
        guard case .index(let index) = value, options.indices.contains(index) else { return nil }
        return options[index]
    }

    /// Dialogs can't sit on top of the popover, so these close it first.
    public var opensDialog: Bool {
        switch self {
        case .leaderboardSetup, .leaderboardShare, .leaderboardAdd, .providerKey, .providerKeyRemove, .sessionQuit,
             .sessionsQuitAll:
            return true
        default:
            return false
        }
    }
}

extension ActionValue {
    /// A switch's on/off (anything else reads as off).
    var isOn: Bool {
        if case .bool(let on) = self { return on }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
