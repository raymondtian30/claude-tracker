import Foundation

/// The Settings window's tab, the first-run picker, and which AIs the panel
/// can show.
extension PanelModel {
    static func toolsCard(_ state: JSONObject, detected: [String]) -> Card {
        let enabled = strings(state["enabled_tools"])
        // Enabled tools stay listed even if their data has gone, so they can be
        // turned off.
        let keys = Tools.tools.map(\.key).filter { detected.contains($0) || enabled.contains($0) }
        var items: [Item] = keys.map { key in
            .switch(label: Tools.toolNames[key] ?? key, isOn: enabled.contains(key), action: "tool:\(key)")
        }
        items += providerItems(state)
        return Card(title: "AI tools", items: items)
    }

    /// On/off switches for OpenAI, DeepSeek and Kimi. Their optional API key
    /// lives on each provider's own Home tab, so turning one on asks nothing.
    static func providerItems(_ state: JSONObject) -> [Item] {
        let enabled = strings(state["enabled_providers"])
        return Providers.providers.map { provider in
            .switch(label: provider.name, isOn: enabled.contains(provider.key), action: "provider:\(provider.key)")
        }
    }

    /// First-run picker: which AI tools to track.
    public static func welcomeTab(detected: [String], chosen: [String]) -> Tab {
        var items: [Item]
        if detected.isEmpty {
            items = [.note("No supported AI tools found on this Mac yet.")]
        } else {
            items = [.note("Which AI tools do you use?"),
                     .note("You can change this later in Settings.")]
            items += detected.map { key in
                .switch(label: Tools.toolNames[key] ?? key, isOn: chosen.contains(key), action: "welcome_tool:\(key)")
            }
        }
        items.append(.buttons([Item.Button("Continue", "arrow.right.circle", "welcome_done")]))
        return Tab(key: "welcome", title: "Welcome", short: "Welcome", icon: "hand.wave",
                   cards: [Card(title: "Choose your AI tools", items: items)])
    }

    /// [(key, name)] for the tool switcher: enabled tools that are on this
    /// Mac or have saved history, then enabled providers.
    public static func toolChoices(_ state: JSONObject, detected: [String]) -> [(key: String, name: String)] {
        let enabled = strings(state["enabled_tools"])
        var choices = [(key: String, name: String)]()
        for tool in Tools.tools where enabled.contains(tool.key) {
            let view = Tools.toolView(state, tool.key)
            if detected.contains(tool.key) || !view.daily.isEmpty || view.grandTotal != 0 {
                choices.append(tool)
            }
        }
        let providers = strings(state["enabled_providers"])
        choices += Providers.providers.filter { providers.contains($0.key) }
        return choices
    }

    /// [(key, name)] for the panel's "Tracking" dropdown: "All AIs" (every
    /// tool picked in Settings added up) once two or more tools are on, then
    /// each tool and provider.
    public static func viewChoices(_ state: JSONObject, detected: [String]) -> [(key: String, name: String)] {
        let choices = toolChoices(state, detected: detected)
        let tools = choices.filter { Tools.toolNames[$0.key] != nil }
        if tools.count >= 2 {
            return [(key: "all", name: "All AIs")] + choices
        }
        return choices
    }

    public static func settingsTab(_ state: JSONObject, intervalChoices: [Int], detected: [String],
                                   updateStatus: String? = nil) -> Tab {
        let mode = state["title_mode"] ?? "lifetime"
        let interval = state["scan_interval_seconds"] ?? intervalChoices[0]
        let fontSize = state["menu_bar_font_size"] ?? defaultMenuBarFontSize
        var general: [Item] = [
            .switch(label: "Start at login", isOn: flag(state, "start_at_login", default: true), action: "login"),
            .switch(label: "Show Leaderboard (Beta)", isOn: leaderboardEnabled(state), action: "leaderboard_enabled"),
        ]
        if strings(state["enabled_tools"]).contains("claude_code") {
            general.append(.switch(label: "Percentages from Anthropic",
                                   isOn: flag(state, "claude_usage_enabled", default: true),
                                   action: "claude_usage_enabled"))
        }
        var about: [Item] = [.row(label: "Version", value: Version.version)]
        if let status = updateStatus, !status.isEmpty {
            about.append(.row(label: "Updates", value: status))
        }
        about += [
            .row(label: "Original app by", value: Version.originalAuthor),
            .row(label: "Redesign & new features by", value: Version.forkAuthor),
            .buttons([Item.Button("Check for Updates", "arrow.down.circle", "check_updates"),
                      Item.Button("View on GitHub", "arrow.up.right.square", "open_repo")]),
        ]
        return Tab(key: "settings", title: "Settings", short: "Settings", icon: "slider.horizontal.3", cards: [
            toolsCard(state, detected: detected),
            appearanceCard(state),
            Card(title: "Menu bar", items: [
                .segmented(label: "Shows", options: titleModes.map(\.label),
                           selected: index(of: mode, in: titleModes.map(\.key)) ?? 0, action: "title_mode"),
                .popup(label: "Text size", options: menuBarFontSizes.map { "\($0) pt" },
                       selected: index(of: fontSize, in: menuBarFontSizes)
                           ?? menuBarFontSizes.firstIndex(of: defaultMenuBarFontSize)!,
                       action: "menu_bar_font_size"),
                .popup(label: "Animation", options: PanelSpeeds.animationSpeeds.map(\.label),
                       selected: animationIndex(state["panel_animation"] ?? PanelSpeeds.defaultAnimation),
                       action: "panel_animation"),
            ]),
            Card(title: "Scanning", items: [
                .popup(label: "Scan every", options: intervalChoices.map(formatInterval),
                       selected: index(of: interval, in: intervalChoices) ?? 0, action: "scan_interval"),
            ]),
            Card(title: "General", items: general),
            Card(title: "About", items: about),
        ])
    }

    static func appearanceCard(_ state: JSONObject) -> Card {
        let keys = PanelSpeeds.appearances.map(\.key)
        let current = state["appearance"] ?? PanelSpeeds.defaultAppearance
        return Card(title: "Appearance", items: [
            .segmented(label: "Mode", options: PanelSpeeds.appearances.map(\.label),
                       selected: index(of: current, in: keys) ?? 0, action: "appearance"),
        ])
    }

    static func animationIndex(_ key: Any) -> Int {
        let keys = PanelSpeeds.animationSpeeds.map(\.key)
        return index(of: key, in: keys) ?? keys.firstIndex(of: PanelSpeeds.defaultAnimation)!
    }

    /// Whether the Leaderboard tab (and its daily sync) is on. Defaults to on
    /// only for people who already set the leaderboard up.
    public static func leaderboardEnabled(_ state: JSONObject) -> Bool {
        flag(state, "leaderboard_enabled", default: JSON.truthy(state["my_gist_id"]))
    }
}
