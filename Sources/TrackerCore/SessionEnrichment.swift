import Foundation

/// What is known about a session beyond whether it exists: its log, tokens,
/// title, plugins and running subagents. Looked up after the rules have
/// decided what the sessions are, and never able to add or remove one.
public struct SessionDetails: Equatable {
    public var tokens: Int?
    public var title: String?
    /// Path of the session's log, when it has one yet.
    public var log: String?
    public var plugins: [Plugins.Tag]?
    public var subagents: [Subagent]

    public init(tokens: Int? = nil, title: String? = nil, log: String? = nil,
                plugins: [Plugins.Tag]? = nil, subagents: [Subagent] = []) {
        self.tokens = tokens
        self.title = title
        self.log = log
        self.plugins = plugins
        self.subagents = subagents
    }
}

/// A subagent a Claude Code session started with its Agent tool.
public struct Subagent: Equatable {
    public var id: String
    /// The kind of agent ("general-purpose", "Explore").
    public var type: String
    /// One short line of what it was asked to do.
    public var description: String?
    /// 1 for a subagent of the session, 2 for one started by a subagent...
    public var depth: Int

    public init(id: String, type: String, description: String? = nil, depth: Int = 1) {
        self.id = id
        self.type = type
        self.description = description
        self.depth = depth
    }
}

/// What the enrichment pass remembers between scans, in memory only: how far
/// each log has been read and what it held, and which subagents have finished.
public struct EnrichmentCache: Equatable {
    struct Log: Equatable {
        /// Bytes of complete lines already summed.
        var offset = 0
        var tokens = 0
        /// The file it was read from; another one at the same path starts over.
        var inode: UInt64 = 0
        var title: String?
        /// The size and time the title was read at.
        var titleSize = -1
        var titleMtime = 0.0
    }

    var logs: [String: Log] = [:]
    /// Paths of subagent metadata files that said `finished`; that does not
    /// go back, so they are not read again.
    var finishedSubagents: Set<String> = []

    public init() {}
}

/// The result of one enrichment pass.
public struct EnrichmentResult: Equatable {
    public var details: [Int32: SessionDetails]
    /// What each plugin did in open sessions; nil when not asked for.
    public var pluginRows: [Plugins.Row]?

    public init(details: [Int32: SessionDetails] = [:], pluginRows: [Plugins.Row]? = nil) {
        self.details = details
        self.pluginRows = pluginRows
    }
}

public enum SessionEnrichment {
    /// Looks up the log, tokens, title, plugin tags and running subagents of
    /// each counted Claude Code session. A log is found from the record's
    /// session id; a `claude` process with no record takes the newest log in
    /// its folder that no record owns (the CLI does not say which file is
    /// whose), in order of process id. Tokens are summed from the saved
    /// offset on, and a failed read leaves that field empty instead of
    /// dropping the session. `cache` is updated and pruned to what is live.
    public static func enrich(_ scan: SessionRules.Scan, cache: inout EnrichmentCache, withPlugins: Bool,
                              projectsDir: URL = TokenMath.claudeProjectsDir,
                              claudeDir: URL = Plugins.claudeDir) -> EnrichmentResult {
        let sessions = scan.entries.filter { $0.counted && $0.tool == "claude_code" }
        let manager = FileManager.default

        func projectDir(_ entry: SessionRules.Entry) -> URL? {
            (entry.recordFolder ?? entry.folder).map { ActiveSessions.projectDirForCwd($0, projectsDir: projectsDir) }
        }
        func logPath(_ entry: SessionRules.Entry) -> String? {
            guard let id = entry.sessionId, let dir = projectDir(entry) else { return nil }
            return dir.appendingPathComponent("\(id).jsonl").path
        }

        // Logs a record owns, counted or not, are not free for pairing.
        var claimed = Set<String>()
        var logs = [Int32: String]()
        for entry in scan.entries where entry.tool == "claude_code" && entry.claimsLog {
            guard let path = logPath(entry), manager.fileExists(atPath: path) else { continue }
            claimed.insert(path)
            if entry.counted { logs[entry.pid] = path }
        }

        let unrecorded = sessions.filter { $0.sessionId == nil }
        for folder in Set(unrecorded.compactMap(\.folder)).sorted() {
            let dir = ActiveSessions.projectDirForCwd(folder, projectsDir: projectsDir)
            let names = (try? manager.contentsOfDirectory(atPath: dir.path)) ?? []
            let free = names.filter { $0.hasSuffix(".jsonl") }
                .map { dir.path + "/" + $0 }
                .filter { !claimed.contains($0) }
                .compactMap { path in SourceFile.Stat(path).map { (path, $0.mtime) } }
                .sorted { ($1.1, $0.0) < ($0.1, $1.0) }  // newest first, then by name
            let here = unrecorded.filter { $0.folder == folder }.sorted { $0.pid < $1.pid }
            for (position, entry) in here.enumerated() where position < free.count {
                logs[entry.pid] = free[position].0
            }
        }

        var details = [Int32: SessionDetails]()
        var subagentDirs = [String]()
        for entry in sessions {
            var detail = SessionDetails()
            if let path = logs[entry.pid] {
                detail.log = path
                detail.tokens = tokens(path, &cache)
                detail.title = title(path, &cache)
            }
            if let id = entry.sessionId, entry.claimsLog, let dir = projectDir(entry) {
                detail.subagents = Subagents.running(projectDir: dir, sessionId: id, cache: &cache)
                subagentDirs.append(dir.appendingPathComponent(id).path + "/")
            }
            details[entry.pid] = detail
        }

        var pluginRows: [Plugins.Row]?
        if withPlugins {
            var tagged = [ActiveSessions.Session]()
            var pids = [Int32]()
            for entry in sessions {
                guard let path = logs[entry.pid] else { continue }
                tagged.append(ActiveSessions.Session(label: entry.folder ?? "", tokens: nil,
                                                     cwd: entry.recordFolder ?? entry.folder, log: path,
                                                     tool: entry.tool))
                pids.append(entry.pid)
            }
            pluginRows = Plugins.livePlugins(&tagged, claudeDir: claudeDir)
            for (session, pid) in zip(tagged, pids) { details[pid]?.plugins = session.plugins }
        }

        let live = Set(logs.values)
        cache.logs = cache.logs.filter { live.contains($0.key) }
        cache.finishedSubagents = cache.finishedSubagents.filter { path in subagentDirs.contains { path.hasPrefix($0) } }
        return EnrichmentResult(details: details, pluginRows: pluginRows)
    }

    /// Tokens in `path`, summed from where the last read stopped. Nil when it
    /// could not be read at all yet; after that, the last good total.
    private static func tokens(_ path: String, _ cache: inout EnrichmentCache) -> Int? {
        guard let stat = SourceFile.Stat(path) else { return nil }
        let known = cache.logs[path]
        var log = known ?? EnrichmentCache.Log()
        // Shorter than before, or not the same file: a replacement, read from the start.
        if known != nil, stat.size < log.offset || stat.inode != log.inode { log = EnrichmentCache.Log() }
        if known == nil || stat.size > log.offset {
            guard let (more, newOffset) = try? TokenMath.sumUsageSince(path, offset: log.offset) else {
                return known == nil ? nil : log.tokens
            }
            log.tokens += more
            log.offset = newOffset
        }
        log.inode = stat.inode
        cache.logs[path] = log
        return log.tokens
    }

    /// The chat title, read again only when the log changed.
    private static func title(_ path: String, _ cache: inout EnrichmentCache) -> String? {
        guard let stat = SourceFile.Stat(path), var log = cache.logs[path] else { return nil }
        if log.titleSize != stat.size || log.titleMtime != stat.mtime {
            log.title = ActiveSessions.chatTitle(log: path)
            log.titleSize = stat.size
            log.titleMtime = stat.mtime
            cache.logs[path] = log
        }
        return log.title
    }
}
