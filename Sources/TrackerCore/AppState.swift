import Foundation

/// Pure helpers from app.py: settings the app adds to state.json on launch,
/// and the menu bar's text.
public enum AppState {
    /// Add the multi-tool settings to `state` without touching anything
    /// already there. Existing installs keep tracking just Claude Code and skip
    /// the welcome picker; fresh installs track nothing until a tool is chosen.
    public static func initToolState(_ state: inout JSONObject, freshInstall: Bool) {
        if state["enabled_tools"] == nil {
            state["enabled_tools"] = freshInstall ? [String]() : ["claude_code"]
        }
        // "Combine all tools" used to be a Settings switch; it's now "All AIs" in
        // the panel's dropdown, so someone who had it on lands there.
        let combine = state.removeValue(forKey: "combine_tools")
        if JSON.truthy(combine) {
            state["selected_tool"] = "all"
        }
        if state["selected_tool"] == nil {
            state["selected_tool"] = state.array("enabled_tools")?.first ?? "claude_code"
        }
        if state["onboarding_done"] == nil {
            state["onboarding_done"] = !freshInstall
        }
    }

    /// Provider tracking starts off; nothing already in `state` changes.
    public static func initProviderState(_ state: inout JSONObject) {
        if state["enabled_providers"] == nil {
            state["enabled_providers"] = [String]()
        }
        if state["provider_keys"] == nil {
            state["provider_keys"] = [String]()  // which providers have a key in the Keychain
        }
    }

    /// (text, showIcon) for the menu bar. A single tool shows its own icon
    /// when one was found; the combined view (or a missing icon) shows the coin.
    /// `countText` is nil in icon-only mode.
    public static func menuBarLabel(_ viewKey: String, _ countText: String?, hasIcon: Bool)
        -> (text: String, showIcon: Bool) {
        let count = countText.flatMap { $0.isEmpty ? nil : $0 }
        if viewKey != "all" && hasIcon {
            return (count.map { " \($0)" } ?? "", true)
        }
        return (count.map { "🪙 \($0)" } ?? "🪙", false)
    }
}
