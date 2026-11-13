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
public enum CodexSource {
    public static let codexSessionsDir = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".codex").appendingPathComponent("sessions")

    static let knownTypes: Set<String> = [
        "session_meta", "turn_context", "event_msg", "response_item", "token_usage_record",
    ]
    static let usageKeys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"]

    /// Codex usage -> the app's categories. Codex's input count already
    /// includes cached tokens, so they're split out here.
    static func parts(_ usage: JSONObject) -> [String: Int] {
        let cached = usage.int("cached_input_tokens") ?? 0
        return [
            "input": max((usage.int("input_tokens") ?? 0) - cached, 0),
            "output": usage.int("output_tokens") ?? 0,
            "cache_write_5m": usage.int("cache_write_input_tokens") ?? 0,
            "cache_write_1h": 0,
            "cache_read": cached,
        ]
    }

    /// Parsed JSON objects for each newline-terminated line. A last line
    /// still being written (no newline yet) is left for the next scan.
    static func completeEntries(_ path: String) throws -> [JSONObject] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return TokenMath.completeLines(data).compactMap { line in autoreleasepool { JSON.parseObject(line) } }
    }

    /// This file's per-day buckets. Counts per-response usage records
    /// (de-duplicated by response id); files without any fall back to the growth
    /// of Codex's running total, ignoring repeats.
    public static func readCodexFile(_ path: String) throws -> JSONObject {
        try readCodex(path).daily
    }

    /// {"at": timestamp, "rate_limits": {...}} from the newest token_count
    /// event that carries Codex's plan limits, or nil. Codex also writes
    /// records for other meters (`limit_id` "premium") with no windows; the
    /// plan's record is preferred (see `rank`), so a newer one of those never
    /// hides the plan's 5-hour and weekly numbers.
    static func latestRateLimits(_ entries: [JSONObject]) -> JSONObject? {
        var records = [JSONObject]()
        for entry in entries {
            let payload = entry.object("payload") ?? [:]
            guard entry.string("type") == "event_msg", payload.string("type") == "token_count",
                  let rateLimits = payload["rate_limits"], JSON.truthy(rateLimits),
                  let timestamp = nonEmpty(entry.string("timestamp"))
            else { continue }
            records.append(["at": timestamp, "rate_limits": rateLimits])
        }
        return newestBest(records)
    }

    /// How useful a {"at", "rate_limits"} record is: 2 for the plan's own
    /// meter (`limit_id` missing or "codex"), windows or not, so its newest
    /// record always wins (a plan without windows shows none); 1 for another
    /// meter with a window; 0 for another meter without one.
    static func rank(_ record: JSONObject) -> Int {
        let limits = record.object("rate_limits") ?? [:]
        let id = limits.string("limit_id")
        if id == nil || id == "codex" {
            return 2
        }
        return ["primary", "secondary"].contains { !(limits.object($0) ?? [:]).isEmpty } ? 1 : 0
    }

    /// The best-ranked record, newest among equals. ISO timestamps sort as
    /// text; of two with the same time, the later one in the list wins.
    static func newestBest(_ records: [JSONObject]) -> JSONObject? {
        var best: JSONObject?
        for record in records {
            guard let current = best else { best = record; continue }
            let (r, c) = (rank(record), rank(current))
            if r > c || (r == c && (record.string("at") ?? "") >= (current.string("at") ?? "")) {
                best = record
            }
        }
        return best
    }

    /// (per-day buckets, latest rate limits) for one session file.
    /// Bumped when a newer app reads more from a file, so each file saved by
    /// an older one is read once more. 2: effort level; 3: hourly totals;
    /// 4: the plan's rate limits preferred over window-less records.
    static let fileVersion = 4

    static func readCodex(_ path: String) throws -> (daily: JSONObject, limits: JSONObject?) {
        let entries = try completeEntries(path)
        if !entries.isEmpty, !entries.contains(where: { knownTypes.contains($0.string("type") ?? "") }) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            throw UsageStats.SourceFormatError("\(name) doesn't look like a Codex session log")
        }

        let hasRecords = entries.contains { $0.string("type") == "token_usage_record" }
        var daily = JSONObject()
        var model = "unknown"
        var effort: String?
        var cwd: String?
        // Response ids already counted; a missing id counts as one id, as
        // Python's None does.
        var seenResponses = Set<AnyHashable>()
        var previousTotal: JSONObject?

        for entry in entries {
            let kind = entry.string("type")
            let payload = entry.object("payload") ?? [:]
            if kind == "session_meta" || kind == "turn_context" {
                cwd = nonEmpty(payload.string("cwd")) ?? cwd
                model = nonEmpty(payload.string("model")) ?? model
                if kind == "turn_context" {
                    // The level can change between turns; a turn with none keeps the last.
                    effort = UsageStats.normalizeEffort(payload["effort"])
                        ?? UsageStats.normalizeEffort(payload.object("collaboration_mode")?.object("settings")?["reasoning_effort"])
                        ?? effort
                }
                continue
            }
            guard let timestamp = nonEmpty(entry.string("timestamp")) else { continue }

            let parts: [String: Int]
            if hasRecords && kind == "token_usage_record" {
                let responseId = (payload["response_id"] as? AnyHashable) ?? AnyHashable(NSNull())
                if seenResponses.contains(responseId) {
                    continue
                }
                seenResponses.insert(responseId)
                parts = self.parts(payload.object("usage") ?? [:])
            } else if !hasRecords && kind == "event_msg" && payload.string("type") == "token_count" {
                guard let total = payload.object("info")?.object("total_token_usage"), !total.isEmpty,
                      !JSON.isEqual(total, previousTotal)
                else { continue }
                let before = previousTotal ?? [:]
                var growth = JSONObject()
                for key in usageKeys {
                    growth[key] = max((total.int(key) ?? 0) - (before.int(key) ?? 0), 0)
                }
                previousTotal = total
                parts = self.parts(growth)
            } else {
                continue
            }

            // A timestamp that can't be read is skipped (Python would stop
            // with an error there).
            if parts.values.reduce(0, +) != 0, let at = LocalTime.parseISO(timestamp) {
                let day = Day(timestamp: at)
                UsageStats.addUsage(&daily, day: day, model: model, project: UsageStats.projectLabel(cwd),
                                    parts: parts, effort: effort, at: at)
            }
        }
        return (daily, latestRateLimits(entries))
    }

    /// Update `sourceState` from Codex's session logs. Sets
    /// sourceState["error"] to a message if a file couldn't be read, else null.
    public static func scanCodex(_ sourceState: inout JSONObject, sessionsDir: URL = codexSessionsDir) {
        var files = sourceState.object("files") ?? [:]
        var errors = [String]()
        for path in SourceFile.find(in: sessionsDir, suffixes: [".jsonl"]) {
            guard let stat = SourceFile.Stat(path) else { continue }
            // Files saved before rate limits were read ("limits" missing), or by
            // an older `fileVersion`, are read once more.
            if let saved = files.object(path), stat.matches(saved), saved["limits"] != nil,
               (saved.int("v") ?? 0) >= fileVersion {
                continue
            }
            do {
                let (daily, limits) = try readCodex(path)
                files[path] = ["size": stat.size, "mtime": stat.mtime, "daily": daily,
                               "limits": limits ?? NSNull(), "v": fileVersion] as JSONObject
            } catch {
                errors.append(SourceFile.message(error))
            }
        }
        sourceState["files"] = files
        sourceState["error"] = errors.first ?? NSNull()
    }

    /// Codex's plan limits as last recorded in any session, or nil.
    public static func codexRateLimits(_ sourceState: JSONObject) -> JSONObject? {
        latestRecord(sourceState)?.object("rate_limits")
    }

    /// When the record `codexRateLimits` reads was written (Unix time), or nil.
    public static func codexRateLimitsAt(_ sourceState: JSONObject) -> Double? {
        latestRecord(sourceState)?.string("at").flatMap(LocalTime.parseISO)
    }

    /// The best {"at", "rate_limits"} record across session files (see
    /// `newestBest`); files are taken in path order so ties are settled the
    /// same way every time.
    static func latestRecord(_ sourceState: JSONObject) -> JSONObject? {
        let files = sourceState.object("files") ?? [:]
        let records = files.keys.sorted().compactMap { path -> JSONObject? in
            guard let limits = JSON.object(files[path])?.object("limits"), !limits.isEmpty else { return nil }
            return limits
        }
        return newestBest(records)
    }

    public static func codexDaily(_ sourceState: JSONObject) -> JSONObject {
        UsageStats.mergeDaily(SourceFile.dailies(sourceState))
    }

    public static func codexTotal(_ sourceState: JSONObject) -> Int {
        SourceFile.dailies(sourceState).reduce(0) { $0 + SourceFile.total($1) }
    }

    static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Helpers shared by the sources that read one file per session (Codex,
/// Gemini CLI): finding the files, telling when one changed, and totals.
enum SourceFile {
    /// Size and modification time of a file, as Python's `os.stat` gives
    /// them, so the values saved in state.json compare equal across the two.
    struct Stat {
        let size: Int
        let mtime: Double
        /// The file's identity: a file put in its place has another one.
        let inode: UInt64

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            size = Int(info.st_size)
            inode = UInt64(info.st_ino)
            // Python's st_mtime: seconds + nanoseconds * 1e-9, as a double.
            mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) * 1e-9
        }

        /// True when `saved` ({"size", "mtime", ...}) was read from this file
        /// as it is now.
        func matches(_ saved: JSONObject) -> Bool {
            saved.int("size") == size && saved.double("mtime") == mtime
        }
    }

    /// Files under `dir` (any depth) whose names end in one of `suffixes`,
    /// sorted as Python sorts paths, spelled as `str(path)` would spell
    /// them so state.json keys stay the same.
    static func find(in dir: URL, suffixes: [String]) -> [String] {
        let root = dir.path
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var files = [String]()
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            guard suffixes.contains(where: { name.hasSuffix($0) }),
                  walker.fileAttributes?[.type] as? FileAttributeType != .typeDirectory
            else { continue }
            files.append(root + "/" + relative)
        }
        return sortedPaths(files)
    }

    /// Paths in the order Python's `sorted()` puts `Path` objects: part by
    /// part, so "a/b" comes before "a-b/c".
    static func sortedPaths(_ paths: [String]) -> [String] {
        paths.map { ($0, $0.split(separator: "/")) }
            .sorted { $0.1.lexicographicallyPrecedes($1.1) }
            .map { $0.0 }
    }

    /// The message to show for a file that couldn't be read.
    static func message(_ error: Error) -> String {
        if let error = error as? UsageStats.SourceFormatError {
            return error.description
        }
        return error.localizedDescription
    }

    /// Each saved file's per-day buckets.
    static func dailies(_ sourceState: JSONObject) -> [JSONObject] {
        (sourceState.object("files") ?? [:]).values.map { JSON.object($0)?.object("daily") ?? [:] }
    }

    /// Every token in a set of per-day buckets.
    static func total(_ daily: JSONObject) -> Int {
        daily.values.reduce(0) { total, bucket in
            (JSON.object(bucket)?.object("models") ?? [:]).values.reduce(total) { sum, parts in
                (JSON.object(parts) ?? [:]).values.reduce(sum) { $0 + (JSON.int($1) ?? 0) }
            }
        }
    }
}
