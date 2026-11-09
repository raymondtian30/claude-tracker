import Foundation

/// The AI coding tools the app can track, and the "views" the panel shows.
///
/// A view is {"key", "name", "daily", "grand_total", "error"}: one tool's
/// per-day buckets and lifetime total, or every enabled tool merged ("all").
///
/// Claude Code's data stays in the state keys it has always used (grand_total,
/// file_offsets, daily); other tools live under state["sources"][tool].
///
/// Wave 1 ports only the tool list, which Limits needs; the rest of
/// tools.py (paths, scanning, views) comes with the sources.
public enum Tools {
    public static let tools: [(key: String, name: String)] = [
        ("claude_code", "Claude Code"), ("codex", "Codex"), ("opencode", "opencode"),
        ("gemini_cli", "Gemini CLI"),
    ]
    public static let toolNames: [String: String] = Dictionary(
        uniqueKeysWithValues: tools.map { ($0.key, $0.name) })
}
