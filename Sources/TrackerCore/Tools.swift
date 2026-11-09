import Foundation

/// The AI coding tools the app can track, and the "views" the panel shows.
///
/// A view is {"key", "name", "daily", "grand_total", "error"}: one tool's
/// per-day buckets and lifetime total, or every enabled tool merged ("all").
///
/// Claude Code's data stays in the state keys it has always used (grand_total,
/// file_offsets, daily); other tools live under state["sources"][tool].
public enum Tools {
    public static let tools: [(key: String, name: String)] = [
        ("claude_code", "Claude Code"), ("codex", "Codex"), ("opencode", "opencode"),
        ("gemini_cli", "Gemini CLI"),
    ]
    public static let toolNames: [String: String] = Dictionary(
        uniqueKeysWithValues: tools.map { ($0.key, $0.name) })

    public static let defaultPaths: [String: URL] = [
        "claude_code": TokenMath.claudeProjectsDir,
        "codex": CodexSource.codexSessionsDir,
        "opencode": OpencodeSource.opencodeDB,
        "gemini_cli": GeminiSource.geminiDir,
    ]

    /// One tool's usage (or several merged): what the panel and menu bar show.
    public struct View {
        /// A tool key, a provider key, or "all".
        public var key: String
        public var name: String
        /// Per-day buckets (see `UsageStats`).
        public var daily: JSONObject
        public var grandTotal: Int
        /// Why the tool's data couldn't be read, or nil.
        public var error: String?
        /// Each tool's own view, e.g. to price tools separately: set for the
        /// combined and provider views, nil for a single tool's.
        public var views: [View]?

        public init(key: String, name: String, daily: JSONObject, grandTotal: Int, error: String?,
                    views: [View]? = nil) {
            self.key = key
            self.name = name
            self.daily = daily
            self.grandTotal = grandTotal
            self.error = error
            self.views = views
        }
    }

    /// Keys of the tools whose data exists on this Mac, in `tools` order.
    public static func detectTools(paths: [String: URL] = defaultPaths) -> [String] {
        let paths = paths.isEmpty ? defaultPaths : paths
        return tools.map(\.key).filter { key in
            paths[key].map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    /// Read new usage for each enabled tool into `state`.
    public static func scanTools(_ state: inout JSONObject, enabled: [String],
                                 paths: [String: URL] = defaultPaths) throws {
        let paths = paths.isEmpty ? defaultPaths : paths
        var sources = state.object("sources") ?? [:]
        state["sources"] = sources
        defer { state["sources"] = sources }
        if enabled.contains("claude_code"), let dir = paths["claude_code"] {
            try TokenMath.refreshGrandTotal(&state, projectsDir: dir)
        }
        if enabled.contains("codex"), let dir = paths["codex"] {
            var source = sources.object("codex") ?? [:]
            CodexSource.scanCodex(&source, sessionsDir: dir)
            sources["codex"] = source
        }
        if enabled.contains("opencode"), let db = paths["opencode"] {
            var source = sources.object("opencode") ?? [:]
            OpencodeSource.scanOpencode(&source, dbPath: db)
            sources["opencode"] = source
        }
        if enabled.contains("gemini_cli"), let dir = paths["gemini_cli"] {
            var source = sources.object("gemini_cli") ?? [:]
            GeminiSource.scanGemini(&source, geminiDir: dir)
            sources["gemini_cli"] = source
        }
    }

    public static func toolView(_ state: JSONObject, _ key: String) -> View {
        let daily: JSONObject
        let total: Int
        let error: String?
        if key == "claude_code" {
            (daily, total, error) = (state.object("daily") ?? [:], state.int("grand_total") ?? 0, nil)
        } else {
            let source = state.object("sources")?.object(key) ?? [:]
            if key == "codex" {
                (daily, total) = (CodexSource.codexDaily(source), CodexSource.codexTotal(source))
            } else if key == "gemini_cli" {
                (daily, total) = (GeminiSource.geminiDaily(source), GeminiSource.geminiTotal(source))
            } else {
                (daily, total) = (OpencodeSource.opencodeDaily(source), OpencodeSource.opencodeTotal(source))
            }
            // An empty message counts as none, as Python's truth test reads it.
            error = CodexSource.nonEmpty(source.string("error"))
        }
        return View(key: key, name: toolNames[key] ?? key, daily: daily, grandTotal: total, error: error)
    }

    public static func combinedView(_ state: JSONObject, enabled: [String]) -> View {
        let views = tools.map(\.key).filter(enabled.contains).map { toolView(state, $0) }
        let errors = views.compactMap { view in view.error.map { "\(view.name): \($0)" } }
        return View(
            key: "all",
            name: "All AIs",
            daily: UsageStats.mergeDaily(views.map(\.daily)),
            grandTotal: views.reduce(0) { $0 + $1.grandTotal },
            error: errors.first,
            views: views  // each tool's own view, e.g. to price tools separately
        )
    }
}
