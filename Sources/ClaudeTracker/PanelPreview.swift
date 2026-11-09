import AppKit
import TrackerCore

// Hard-coded sample data showing every kind of panel item, for checking the
// panel by eye until the real app controller (a later wave) replaces
// main.swift. Delete this file then.

enum PanelPreview {
    static let tabs: [Tab] = [overview, models, limits, sessions]

    static let toolChoices: [(key: String, name: String)] = [
        ("claude_code", "Claude Code"), ("codex", "Codex"), ("opencode", "opencode"),
    ]

    static let footer = "Tracking since March 3, 2026"

    static let overview = Tab(key: "overview", title: "Overview", short: "Home", icon: "square.grid.2x2", cards: [
        Card(title: nil, items: [
            .alert(text: "Couldn't read 2 log files.", showIcon: true),
            .alert(text: "Check the folder's permissions.", showIcon: false),
        ]),
        Card(title: nil, items: [.tiles([
            Item.Tile("Today", "1.2M", "sun.max.fill"),
            Item.Tile("All time", "48.3M", "infinity"),
        ])]),
        Card(title: "Last 14 days", items: [
            .chart(values: [120, 340, 80, 0, 560, 900, 410, 300, 1200, 640, 720, 200, 950, 1100],
                   caption: "Peak 1.2K tokens on Mar 12"),
        ]),
        Card(title: "Stats", items: [
            .row(label: "Average per day", value: "412.6K"),
            .row(label: "Busiest day", value: "2.1M"),
            .row(label: "Sessions", value: "1,284"),
            .note("Counts include cache reads."),
        ]),
    ])

    static let models = Tab(key: "models", title: "Models", short: "Models", icon: "cpu", cards: [
        Card(title: "Models", items: [
            .bar(label: "claude-opus-4-5-20251101", value: "31.2M · 64%", fraction: 0.64),
            .bar(label: "claude-sonnet-4-5-20250929-with-a-very-long-suffix-name", value: "15.0M · 31%",
                 fraction: 0.31),
            .bar(label: "claude-haiku-4-5", value: "2.1M · 5%", fraction: 0.05),
            .bar(label: "unused", value: "0", fraction: 0),
        ]),
        Card(title: "Projects", items: [
            .row(label: "/Users/raymond/projects/some/really/deep/folder/claude-tracker", value: "12.4M"),
            .row(label: "~/scratch", value: "310K"),
            .buttons([Item.Button("Show more", "chevron.down", "projects_more")]),
        ]),
    ])

    static let limits = Tab(key: "limits", title: "Usage Limits", short: "Limits", icon: "gauge.with.dots.needle.33percent", cards: [
        Card(title: "Plan limits", items: [
            .bar(label: "Session (5 hours)", value: "42%", fraction: 0.42),
            .bar(label: "Weekly", value: "87%", fraction: 0.87),
            .note("Resets in 2 h 14 min"),
        ]),
        Card(title: "Notifications", items: [
            .choices(label: "Alert at", options: ["50%", "60%", "70%", "80%", "90%", "95%", "100%"],
                     selected: [2, 4, 6], action: "alert_thresholds"),
            .switch(label: "Session limit", isOn: true, action: "alert_window:five_hour"),
            .switch(label: "Weekly limit", isOn: false, action: "alert_window:seven_day"),
            .buttons([Item.Button("Send test alert", "bell", "test_alert"),
                      Item.Button("Settings", nil, "notification_settings")]),
        ]),
    ])

    static let sessions = Tab(key: "sessions", title: "Active Sessions", short: "Sessions", icon: "bolt.horizontal", cards: [
        Card(title: "Sessions", items: [
            .row(label: "claude-tracker", value: "3 min ago"),
            .tags([Item.Tag("superpowers", true), Item.Tag("caveman", true), Item.Tag("old-plugin", false)]),
            .row(label: "website", value: "1 h ago"),
            .tags([Item.Tag("a-plugin-with-a-long-name", true), Item.Tag("another-long-plugin-name", true),
                   Item.Tag("third", false), Item.Tag("fourth-one", true)]),
        ]),
        Card(title: "View", items: [
            .segmented(label: "Sort by", options: ["Recent", "Tokens"], selected: 0, action: "sessions_sort"),
            .segmented(label: nil, options: ["Today", "Week", "All"], selected: 1, action: "sessions_range"),
        ]),
    ])

    static let settings = Tab(key: "settings", title: "Settings", short: "Settings", icon: "gear", cards: [
        Card(title: "AI tools", items: [
            .switch(label: "Claude Code", isOn: true, action: "tool:claude_code"),
            .switch(label: "Codex", isOn: true, action: "tool:codex"),
        ]),
        Card(title: "Appearance", items: [
            .segmented(label: nil, options: ["Auto", "Light", "Dark"], selected: 0, action: "appearance"),
            .popup(label: "Menu bar shows", options: ["Lifetime", "Today", "Icon only"], selected: 0,
                   action: "title_mode"),
            .segmented(label: "Animation", options: ["Off", "Fast", "Normal", "Slow"], selected: 2,
                       action: "panel_animation"),
        ]),
        Card(title: "About", items: [
            .row(label: "Version", value: Version.version),
            .note("Originally by BrodyKretz; fork by Raymond Tian."),
            .buttons([Item.Button("Check for Updates", "arrow.down.circle", "check_updates")]),
        ]),
    ])

    static let welcome = Tab(key: "welcome", title: "Which AIs do you use?", short: "", icon: "", cards: [
        Card(title: "Found on this Mac", items: [
            .switch(label: "Claude Code", isOn: true, action: "welcome_tool:claude_code"),
            .switch(label: "Codex", isOn: false, action: "welcome_tool:codex"),
            .buttons([Item.Button("Start tracking", "checkmark", "welcome_done")]),
        ]),
    ])
}
