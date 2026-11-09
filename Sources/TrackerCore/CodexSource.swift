import Foundation

/// Codex usage, read from the session logs Codex writes on this Mac.
///
/// Codex keeps one JSONL "rollout" file per session under ~/.codex/sessions.
/// Only token counts, model, timestamp and the session's folder are read;
/// prompts and code in the same files are skipped.
///
/// Each file is re-read whole when it changes and its contribution replaces the
/// previous one, so files Codex rewrites or migrates can't be counted twice.
/// Files that disappear keep their last contribution, so lifetime totals
/// survive Codex pruning old sessions.
///
/// Wave 1 ports only `codexRateLimits`, which Limits needs; the scanner
/// comes with the other sources.
public enum CodexSource {
    /// Codex's plan limits as last recorded in any session, or nil.
    public static func codexRateLimits(_ sourceState: JSONObject) -> JSONObject? {
        let records = (sourceState.object("files") ?? [:]).values.compactMap { file -> JSONObject? in
            guard let limits = JSON.object(file)?.object("limits"), !limits.isEmpty else { return nil }
            return limits
        }
        // ISO timestamps sort as text, as Python's max(key=r["at"]) compares them.
        let latest = records.max { ($0.string("at") ?? "") < ($1.string("at") ?? "") }
        return latest?.object("rate_limits")
    }
}
