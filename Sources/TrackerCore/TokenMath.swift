import Foundation

/// Claude Code's token totals: reading its session logs (jsonl files) a
/// little at a time, and the lifetime total kept in state.json.
public enum TokenMath {
    public static let claudeProjectsDir = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".claude").appendingPathComponent("projects")

    public static func loadState(_ stateFile: URL) throws -> JSONObject {
        if let state = try JSON.loadObject(stateFile) {
            return state
        }
        return ["grand_total": 0, "file_offsets": JSONObject(), "first_seen_at": NSNull()]
    }

    public static func saveState(_ state: JSONObject, _ stateFile: URL) throws {
        try JSON.write(state, to: stateFile)
    }

    /// Remember when a Claude limit was reached: {limit type: reset time}.
    static func noteLimit(_ entry: JSONObject, _ limitHits: inout JSONObject) {
        let info = entry.object("apiErrorParams")?.object("rate_limit_info") ?? [:]
        guard info.string("status") == "rejected", let resetsAt = info["resetsAt"],
              let reset = JSON.double(resetsAt), reset != 0
        else { return }
        let kind = info.string("rateLimitType").flatMap { $0.isEmpty ? nil : $0 } ?? "five_hour"
        if reset > (limitHits.double(kind) ?? 0) {
            limitHits[kind] = resetsAt
        }
    }

    /// Sum token usage from an assistant-log jsonl file starting at a byte offset.
    ///
    /// Only consumes complete (newline-terminated) lines so a session file being
    /// actively written to never has a half-written JSON line parsed.
    /// `onEntry` gets each assistant entry read, for recording it into per-day
    /// buckets (see `UsageStats`) or noting reached limits; the overloads below
    /// do that. If `stopAt` is given, reading stops at that byte offset.
    /// Returns (tokensFound, newOffset).
    @discardableResult
    public static func sumUsageSince(_ path: String, offset: Int, stopAt: Int? = nil,
                                     onEntry: (JSONObject) -> Void = { _ in }) throws
        -> (tokens: Int, newOffset: Int) {
        var tokens = 0
        // Line by line, each in its own autorelease pool: parsing leaves a
        // lot of temporary objects that otherwise pile up until this whole
        // read is over, which for months of logs was over a gigabyte.
        let consumed = try forEachCompleteLine(path, from: offset, upTo: stopAt) { line in
            autoreleasepool {
                guard let entry = JSON.parseObject(line), entry.string("type") == "assistant" else {
                    return
                }
                onEntry(entry)
                guard let usage = entry.object("message")?.object("usage"), !usage.isEmpty else {
                    return
                }
                tokens += usageTokens(usage)
            }
        }
        return (tokens, offset + consumed)
    }

    /// `sumUsageSince` recording each entry into `daily` and, if given,
    /// reached limits into `limitHits`.
    @discardableResult
    public static func sumUsageSince(_ path: String, offset: Int, stopAt: Int? = nil,
                                     daily: inout JSONObject) throws -> (tokens: Int, newOffset: Int) {
        try sumUsageSince(path, offset: offset, stopAt: stopAt) { entry in
            UsageStats.recordEntry(&daily, entry)
        }
    }

    /// `sumUsageSince` noting reached limits into `limitHits`.
    @discardableResult
    public static func sumUsageSince(_ path: String, offset: Int, stopAt: Int? = nil,
                                     limitHits: inout JSONObject) throws -> (tokens: Int, newOffset: Int) {
        try sumUsageSince(path, offset: offset, stopAt: stopAt) { entry in
            noteLimit(entry, &limitHits)
        }
    }

    /// input + output + cache writes + cache reads of one usage object.
    static func usageTokens(_ usage: JSONObject) -> Int {
        (usage.int("input_tokens") ?? 0)
            + (usage.int("output_tokens") ?? 0)
            + (usage.int("cache_creation_input_tokens") ?? 0)
            + (usage.int("cache_read_input_tokens") ?? 0)
    }

    /// Calls `body` with each complete line of `path` from byte `offset` to
    /// `stopAt` (or the end), reading `chunk` bytes at a time so a log of
    /// hundreds of megabytes never sits in memory whole. Lines are the same as
    /// `completeLines` gives (see it for the rules); returns the bytes they
    /// take, which is how far to move the saved offset.
    @discardableResult
    static func forEachCompleteLine(_ path: String, from offset: Int, upTo stopAt: Int?,
                                    chunk: Int = 1 << 20, _ body: (Data) -> Void) throws -> Int {
        // Plain read(2) into one buffer that is reused: FileHandle hands back a
        // new object for every piece, and those were not being released.
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }
        guard lseek(descriptor, off_t(Swift.max(offset, 0)), SEEK_SET) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var remaining = stopAt.map { Swift.max($0 - offset, 0) }
        var buffer = [UInt8](repeating: 0, count: Swift.max(chunk, 1))
        var pending = [UInt8]()  // read but not yet a whole line
        var consumed = 0
        while remaining != 0 {
            let want = Swift.min(buffer.count, remaining ?? buffer.count)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, want) }
            if count < 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if count == 0 {
                break
            }
            if let left = remaining {
                remaining = left - count
            }
            pending.append(contentsOf: buffer[0..<count])
            var start = 0
            var index = 0
            while index < pending.count {
                let byte = pending[index]
                if byte == 0x0A {
                    body(Data(pending[start...index]))
                    consumed += index - start + 1
                    start = index + 1
                } else if byte == 0x0D {
                    if index + 1 >= pending.count {
                        break  // the next piece says whether it's "\r\n"
                    }
                    if pending[index + 1] != 0x0A {
                        return consumed  // a lone "\r": the line isn't complete
                    }
                    index += 1
                    body(Data(pending[start...index]))
                    consumed += index - start + 1
                    start = index + 1
                }
                index += 1
            }
            pending.removeFirst(start)
        }
        return consumed
    }

    /// The lines of `data` with their line endings, up to the first one that
    /// doesn't end in "\n" (a line still being written). Lines split as
    /// Python's `bytes.splitlines(keepends=True)` splits them: at "\n",
    /// "\r\n" and a lone "\r", so a line ending in a lone "\r" stops reading.
    static func completeLines(_ data: Data) -> [Data] {
        var lines = [Data]()
        let bytes = [UInt8](data)
        var start = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A {
                lines.append(Data(bytes[start...index]))
                start = index + 1
            } else if byte == 0x0D {
                let crlf = index + 1 < bytes.count && bytes[index + 1] == 0x0A
                if !crlf {
                    return lines  // a line ending in a lone "\r": not complete
                }
                index += 1
                lines.append(Data(bytes[start...index]))
                start = index + 1
            }
            index += 1
        }
        return lines
    }

    /// Every jsonl file under `dir`, as `str(path)` would spell it in
    /// Python, so the keys of state["file_offsets"] stay the same.
    static func jsonlFiles(in dir: URL) -> [String] {
        let root = dir.path
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var files = [String]()
        while let relative = walker.nextObject() as? String {
            guard relative.hasSuffix(".jsonl"), walker.fileAttributes?[.type] as? FileAttributeType != .typeDirectory
            else { continue }
            files.append(root + "/" + relative)
        }
        return files
    }

    /// Mutates `state` with grand_total updated by any newly-seen tokens.
    ///
    /// Files no longer on disk (pruned after 30 days) are dropped from tracking
    /// without touching grand_total, since their tokens were already counted
    /// while they existed.
    public static func refreshGrandTotal(_ state: inout JSONObject,
                                         projectsDir: URL = claudeProjectsDir) throws {
        var offsets = state.object("file_offsets") ?? [:]
        var daily = state.object("daily") ?? [:]
        var limitHits = state.object("claude_limit_hits") ?? [:]
        let currentFiles = Set(jsonlFiles(in: projectsDir))

        for trackedPath in offsets.keys where !currentFiles.contains(trackedPath) {
            offsets[trackedPath] = nil
        }

        var grandTotal = state.int("grand_total") ?? 0
        defer {
            // Keep what was read even if a file fails partway through.
            state["file_offsets"] = offsets
            state["daily"] = daily
            state["claude_limit_hits"] = limitHits
            state["grand_total"] = grandTotal
        }
        for path in currentFiles {
            let offset = offsets.int(path) ?? 0
            let (tokens, newOffset) = try sumUsageSince(path, offset: offset) { entry in
                noteLimit(entry, &limitHits)
                UsageStats.recordEntry(&daily, entry)
            }
            grandTotal += tokens
            offsets[path] = newOffset
        }

        state["claude_recent"] = nil  // from the 5-hour budgets, since removed
    }

    /// One-time read of the last week's logs (up to what's already counted)
    /// for reached limits, so the Limits tab is right straight after updating.
    public static func backfillLimits(_ state: inout JSONObject,
                                      now: Double = Date().timeIntervalSince1970) throws {
        if state.bool("limits_backfilled") == true {
            return
        }
        var limitHits = state.object("claude_limit_hits") ?? [:]
        defer { state["claude_limit_hits"] = limitHits }
        for (path, offset) in state.object("file_offsets") ?? [:] {
            guard let modified = modificationTime(path) else { continue }  // gone
            if modified < now - 8 * 24 * 3600 {
                continue
            }
            try skippingMissing {
                try sumUsageSince(path, offset: 0, stopAt: JSON.int(offset) ?? 0, limitHits: &limitHits)
            }
        }
        state["limits_backfilled"] = true
    }

    /// One-time fill of the per-day buckets from logs still on disk.
    ///
    /// Installs from before per-day tracking existed have offsets but no buckets.
    /// Re-reads each tracked file from the start up to its saved offset (so it
    /// never overlaps what refreshGrandTotal records) without touching
    /// grand_total. Logs Claude Code already pruned can't be recovered.
    public static func backfillDaily(_ state: inout JSONObject) throws {
        if state.bool("daily_backfilled") == true {
            return
        }
        var daily = state.object("daily") ?? [:]
        defer { state["daily"] = daily }
        for (path, offset) in state.object("file_offsets") ?? [:] {
            try skippingMissing {
                try sumUsageSince(path, offset: 0, stopAt: JSON.int(offset) ?? 0, daily: &daily)
            }
        }
        state["daily_backfilled"] = true
    }

    /// One-time read of the effort levels of what's already counted.
    ///
    /// Re-reads each tracked file from the start up to its saved offset into a
    /// scratch copy of the buckets, and copies only the `efforts` maps into
    /// saved buckets that have none. Logs Claude Code already pruned have no
    /// effort left: their tokens show as a plain model row.
    public static func backfillEfforts(_ state: inout JSONObject) throws {
        if state.bool("efforts_backfilled") == true {
            return
        }
        var scratch = JSONObject()
        for (path, offset) in state.object("file_offsets") ?? [:] {
            try skippingMissing {
                try sumUsageSince(path, offset: 0, stopAt: JSON.int(offset) ?? 0, daily: &scratch)
            }
        }
        var daily = state.object("daily") ?? [:]
        for (iso, value) in scratch {
            guard let efforts = JSON.object(value)?.object("efforts"), !efforts.isEmpty,
                  var bucket = daily.object(iso), bucket["efforts"] == nil
            else { continue }
            bucket["efforts"] = efforts
            daily[iso] = bucket
        }
        state["daily"] = daily
        state["efforts_backfilled"] = true
    }

    /// Runs `body`, ignoring a "no such file" error (Python's FileNotFoundError).
    static func skippingMissing(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
    }

    static func modificationTime(_ path: String) -> Double? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
    }

    static func sumUsageForDateInFile(_ path: String, _ targetDate: Day) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var total = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            guard let entry = JSON.parseObject(Data(line)), entry.string("type") == "assistant",
                  let timestamp = entry.string("timestamp"), !timestamp.isEmpty,
                  let usage = entry.object("message")?.object("usage"), !usage.isEmpty,
                  UsageStats.localDateOf(timestamp) == targetDate
            else { continue }
            total += usageTokens(usage)
        }
        return total
    }

    /// Sum tokens from assistant entries whose own timestamp falls on `today`.
    ///
    /// Filters by each entry's actual timestamp rather than by when it was
    /// scanned, so a first-ever run doesn't misreport the entire historical
    /// backlog as "today". Only files modified today or later are opened in
    /// full, since a file untouched today can't contain any of today's entries.
    public static func sumUsageForToday(projectsDir: URL = claudeProjectsDir, today: Day? = nil) throws -> Int {
        let today = today ?? Day.today()
        var total = 0
        for path in jsonlFiles(in: projectsDir) {
            guard let modified = modificationTime(path), Day(timestamp: modified) >= today else {
                continue
            }
            total += try sumUsageForDateInFile(path, today)
        }
        return total
    }

    /// 1234 -> "1.2K", 2_500_000 -> "2.5M", rounded as Python's "%.1f" does.
    public static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            return String(format: "%.1fB", Double(n) / 1_000_000_000)
        }
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return String(n)
    }
}
