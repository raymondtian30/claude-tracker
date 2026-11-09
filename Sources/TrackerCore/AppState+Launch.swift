import Foundation

/// app.py's start-up: where the app's files live, and the settings it adds
/// to (or drops from) state.json on launch.
extension AppState {
    /// Menu bar refresh, in seconds, until one is picked in Settings.
    public static let refreshSeconds = 15
    /// The Settings window's "Scan every" choices, in seconds.
    public static let scanIntervalChoices = [5, 15, 30, 60, 300]
    /// The Info.plist key build.sh writes the project folder into.
    public static let projectDirKey = "ClaudeTrackerProjectDir"
    /// Where the project folder is set when running straight from `.build`.
    public static let projectDirEnvironment = "CLAUDE_TRACKER_PROJECT_DIR"

    /// The project folder (the git clone), which holds state.json,
    /// friends.json and the lock file: the bundle's Info.plist entry, else
    /// the environment variable (a `swift run` build has no Info.plist),
    /// else the current folder.
    public static func projectDirectory(infoValue: String?, environment: [String: String],
                                        currentDirectory: String) -> URL {
        let candidates = [infoValue, environment[projectDirEnvironment]]
        let found = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? currentDirectory
        return URL(fileURLWithPath: found, isDirectory: true).standardizedFileURL
    }

    /// The files the app keeps in the project folder.
    public struct Files {
        public let projectDir: URL
        public var state: URL { projectDir.appendingPathComponent("state.json") }
        public var friends: URL { projectDir.appendingPathComponent("friends.json") }
        public var lock: URL { projectDir.appendingPathComponent(".claude-tracker.lock") }

        public init(projectDir: URL) {
            self.projectDir = projectDir
        }
    }

    /// Where install.sh puts the app: /Applications when it's writable,
    /// else ~/Applications (build_app.py's `default_dest`).
    public static func defaultDest(applicationsWritable: Bool = FileManager.default.isWritableFile(atPath: "/Applications"),
                                   home: String = NSHomeDirectory()) -> URL {
        applicationsWritable ? URL(fileURLWithPath: "/Applications")
            : URL(fileURLWithPath: home).appendingPathComponent("Applications")
    }

    /// The "Claude Tracker.app" this is running from, or where install.sh
    /// puts it when run as a bare executable (e.g. from `.build`).
    public static func bundlePath(running bundleURL: URL, defaultDest: URL) -> URL {
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        return defaultDest.appendingPathComponent("\(Version.appName).app")
    }

    /// Everything app.py's `__init__` sets up in state.json before the first
    /// scan: the tool and provider settings, a default for every preference
    /// (nothing already there changes), the alert settings' migration, and
    /// keys from older versions dropped. `today` becomes the tracking start
    /// on a first launch.
    public static func applyLaunchDefaults(_ state: inout JSONObject, freshInstall: Bool, today: Day) {
        initToolState(&state, freshInstall: freshInstall)
        initProviderState(&state)
        let defaults: [(String, Any)] = [
            ("first_seen_at", NSNull()),
            ("start_at_login", true),
            ("scan_interval_seconds", refreshSeconds),
            ("leaderboard_view", "total"),
            ("my_gist_id", NSNull()),
            ("leaderboard_name", NSNull()),
            ("last_leaderboard_sync_date", NSNull()),
            ("title_mode", "lifetime"),
            ("menu_bar_font_size", PanelModel.defaultMenuBarFontSize),
            ("panel_animation", PanelSpeeds.defaultAnimation),
            ("appearance", PanelSpeeds.defaultAppearance),
            ("alerts_enabled", true),
        ]
        for (key, value) in defaults where state[key] == nil {
            state[key] = value
        }
        Limits.migrateAlertState(&state)
        if state["alert_windows"] == nil {
            state["alert_windows"] = Limits.windows.map(\.key)
        }
        if state["claude_usage_enabled"] == nil {
            state["claude_usage_enabled"] = true
        }
        state["budgets"] = nil  // token budgets, since removed
        state["stats_tab"] = nil  // from the earlier in-menu tabs
        state["panel_tab"] = nil  // the panel always opens on Home now
        if JSON.isNull(state["first_seen_at"]) {
            state["first_seen_at"] = today.iso
        }
    }
}
