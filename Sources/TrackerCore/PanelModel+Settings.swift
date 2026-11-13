import Foundation

/// The Settings window's tab, the first-run picker, and which AIs the panel
/// can show.
extension PanelModel {
    /// The AI tools card: a switch for each detected or enabled tool, then
    /// one for each provider. Collapsed, it shows `toolsShown` switches and
    /// "Show N more"; a switch that is on always shows, so turning off what
    /// you use never needs a click first. Expanded, every switch and
    /// "Show less".
    static func toolsCard(_ state: JSONObject, detected: [String], expanded: Bool = false) -> Card {
        let enabled = strings(state["enabled_tools"])
        // Enabled tools stay listed even if their data has gone, so they can be
        // turned off.
        let keys = Tools.tools.map(\.key).filter { detected.contains($0) || enabled.contains($0) }
        let tools: [(item: Item, isOn: Bool)] = keys.map { key in
            (.switch(label: Tools.toolNames[key] ?? key, isOn: enabled.contains(key), action: "tool:\(key)"),
             enabled.contains(key))
        }
        let all = tools + providerSwitches(state)
        guard all.count > toolsShown else { return Card(title: "AI tools", items: all.map(\.item)) }
        if expanded {
            return Card(title: "AI tools", items: all.map(\.item)
                + [.buttons([Item.Button("Show less", "chevron.up", "tools_expand")])])
        }
        // Tools, then the providers that are on, then as many that are off
        // as fit under `toolsShown`.
        let providers = all.dropFirst(tools.count)
        let on = providers.filter(\.isOn)
        let off = providers.filter { !$0.isOn }
        let shown = tools + on + off.prefix(Swift.max(toolsShown - tools.count - on.count, 0))
        let hidden = all.count - shown.count
        guard hidden > 0 else { return Card(title: "AI tools", items: shown.map(\.item)) }
        return Card(title: "AI tools", items: shown.map(\.item)
            + [.buttons([Item.Button("Show \(hidden) more", "chevron.down", "tools_expand")])])
    }

    /// On/off switches for the supported model providers. Their optional API key
    /// lives on each provider's own Home tab, so turning one on asks nothing.
    static func providerSwitches(_ state: JSONObject) -> [(item: Item, isOn: Bool)] {
        let enabled = strings(state["enabled_providers"])
        return Providers.providers.map { provider in
            (.switch(label: provider.name, isOn: enabled.contains(provider.key), action: "provider:\(provider.key)"),
             enabled.contains(provider.key))
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

    /// The "Show more…" window: every AI. First the ones in the Tracking
    /// dropdown (the selected one ticked), then the ones that are off: providers,
    /// and tools found on this Mac. A click on one (`pick_tool:<key>`) tracks
    /// it, turning it on first if it's off.
    public static func trackingWindowTab(_ state: JSONObject, detected: [String], selected: String?) -> Tab {
        let choices = viewChoices(state, detected: detected)
        let tracked = choices.map { choice in
            Item.buttons([Item.Button(choice.name, choice.key == selected ? "checkmark" : nil, "pick_tool:\(choice.key)")])
        }
        let shown = Set(choices.map(\.key))
        let enabledTools = strings(state["enabled_tools"])
        let enabledProviders = strings(state["enabled_providers"])
        let off = Tools.tools.filter { detected.contains($0.key) && !enabledTools.contains($0.key) && !shown.contains($0.key) }
            + Providers.providers.filter { !enabledProviders.contains($0.key) && !shown.contains($0.key) }
        var cards = [Card(title: "Tracking", items: tracked)]
        if !off.isEmpty {
            cards.append(Card(title: "Not turned on", items: off.map {
                Item.buttons([Item.Button($0.name, "plus", "pick_tool:\($0.key)")])
            } + [.note("Picking one turns it on in Settings, AI tools.")]))
        }
        return Tab(key: "tracking", title: PanelLayout.trackingWindowTitle, short: "AIs", icon: "list.bullet",
                   cards: cards)
    }

    public static func settingsTab(_ state: JSONObject, intervalChoices: [Int], detected: [String],
                                   updateStatus: String? = nil,
                                   showCredits: Bool = false, toolsExpanded: Bool = false) -> Tab {
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
        general.insert(.popup(label: "Currency for prices",
                              options: Pricing.currencies.map { "\($0.code) · \($0.name)" },
                              selected: Pricing.currencies.firstIndex { $0.code == currency(from: state) } ?? 0,
                              action: "currency"), at: 0)
        let about = showCredits ? creditsItems() : aboutItems(updateStatus: updateStatus)
        return Tab(key: "settings", title: "Settings", short: "Settings", icon: "slider.horizontal.3", cards: [
            toolsCard(state, detected: detected, expanded: toolsExpanded),
            appearanceCard(state),
            Card(title: "Models", items: [
                .popup(label: "Sort model token usage by", options: ModelTiers.choices.map(\.label),
                       selected: ModelTiers.choices.firstIndex { $0.order == ModelTiers.order(from: state["model_sort"]) } ?? 0,
                       action: "model_sort"),
            ]),
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
                .buttons([Item.Button("Session diagnostics", "list.bullet.rectangle", "session_diagnostics")]),
                .note("Why each process was or was not counted as a session."),
            ]),
            Card(title: "General", items: general),
            Card(title: "About", items: about),
            Card(title: "FAQ", items: FaqEntries.items()),
        ])
    }

    /// The About card's switch between its two views.
    static func aboutSwitch(showCredits: Bool) -> Item {
        .segmented(label: nil, options: ["About", "Credits"], selected: showCredits ? 1 : 0, action: "about_view")
    }

    static func aboutItems(updateStatus: String?) -> [Item] {
        var items: [Item] = [aboutSwitch(showCredits: false), .row(label: "Version", value: Version.version)]
        if let status = updateStatus, !status.isEmpty {
            items.append(.row(label: "Updates", value: status))
        }
        return items + [
            .row(label: "Original app by", value: Version.originalAuthor),
            .row(label: "Redesign & new features by", value: Version.forkAuthor),
            .buttons([Item.Button("Check for Updates", "arrow.down.circle", "check_updates"),
                      Item.Button("View on GitHub", "arrow.up.right.square", "open_repo")]),
        ]
    }

    /// Everyone who made the app, with their GitHub usernames. The original
    /// creator keeps a section of their own, ahead of everyone else.
    static func creditsItems() -> [Item] {
        // Name on the left, @username on the right: the right-hand column is
        // narrow, so it only ever holds the username.
        func row(_ person: Credits.Contributor) -> Item {
            .row(label: person.name ?? person.login, value: "@\(person.login)")
        }
        return [aboutSwitch(showCredits: true),
                .note("Original creator"), row(Credits.originalCreator),
                .note("Contributors")] + Credits.contributors.map(row)
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
