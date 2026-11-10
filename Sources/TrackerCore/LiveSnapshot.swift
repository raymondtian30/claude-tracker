import Foundation

/// The open sessions and plugin activity the Live tab shows, as the last
/// background search found them. Finding them runs `ps` and `lsof` and reads
/// session logs (over half a second), so a click never waits for it: the
/// panel draws the saved result, and a search refreshes it now and then.
public struct LiveSnapshot: Equatable {
    /// The tools it was found for; nil before the first search.
    public var tools: [String]?
    public var sessions: [ActiveSessions.Session]
    /// nil when the view has no plugins to show.
    public var plugins: [Plugins.Row]?

    public init(tools: [String]? = nil, sessions: [ActiveSessions.Session] = [], plugins: [Plugins.Row]? = nil) {
        self.tools = tools
        self.sessions = sessions
        self.plugins = plugins
    }

    /// Whether this is what a search for `tools` found.
    public func isCurrent(for tools: [String]) -> Bool {
        self.tools == tools
    }

    /// What to draw for `tools`: this, or nothing when it was found for other
    /// tools (another AI's sessions must not show under this one's name).
    public func shown(for tools: [String]) -> (sessions: [ActiveSessions.Session], plugins: [Plugins.Row]?) {
        isCurrent(for: tools) ? (sessions, plugins) : ([], nil)
    }

    /// Whether drawing `new` would look different from drawing this.
    public func differs(from new: LiveSnapshot) -> Bool {
        self != new
    }

    /// The search itself: Claude Code sessions with their plugins, and the
    /// running sessions of the other tools. Slow; call it off the main thread.
    /// A tool that can't be listed is skipped, with `report` told why.
    public static func find(tools: [String], withPlugins: Bool,
                            report: (String) -> Void = { _ in }) -> LiveSnapshot {
        var sessions = [ActiveSessions.Session]()
        for tool in tools {
            do {
                sessions += tool == "claude_code" ? try ActiveSessions.activeSessions()
                    : try ActiveSessions.runningToolSessions(tool)
            } catch {
                report("Couldn't list \(tool) sessions: \(error)")
            }
        }
        // Tags each Claude Code session with the plugins it runs.
        let plugins = withPlugins ? Plugins.livePlugins(&sessions) : nil
        return LiveSnapshot(tools: tools, sessions: sessions, plugins: plugins)
    }
}
