import Foundation

/// Which running processes are sessions: the counting rules, as a pure
/// function of the process table and Claude Code's records. A process counts
/// only with positive evidence that it is an interactive session (a Claude
/// Code record of kind `interactive`; for the other tools a controlling
/// terminal and no server subcommand). Everything else is kept, with the
/// reason, for diagnostics and the Live tab's lists of what is not counted.
/// Logs are never read here: tokens, titles and plugins are looked up
/// separately and cannot add or remove a session.
public enum SessionRules {
    /// What a tool process is for.
    public enum Role: Equatable {
        /// A chat someone works in (counted unless it has another reason).
        case session
        /// A Claude Code background agent (`bg`, `daemon`, `daemon-worker`).
        case background
        /// A process of a tool that is not known to be a chat: a server, or
        /// one with no terminal.
        case unclassified
        /// A process started by another tool's counted session.
        case crossToolChild
    }

    /// What a session is doing. Paused is a separate flag.
    public enum State: Equatable {
        case active
        case waiting
        case idle
        case unknown
    }

    /// Why an entry is counted, or is not: one typed reason per decision.
    public enum Reason: Equatable {
        case interactiveRecord
        case recordKindUnrecognized(String)
        case recordKindMissing
        /// A `claude` process with no valid record: counted, state Unknown.
        case noRecord
        /// The record has no start time to check, so it is accepted unverified.
        case unverifiedRecord
        case hasTerminal
        case noTerminal
        case server
        case backgroundAgent(String)
        case otherToolChild(of: Int32)
        case duplicateSessionId(withPid: Int32)
    }

    /// A process that belongs to a session as one of its helpers.
    public struct Child: Equatable {
        public var pid: Int32
        public var start: String
    }

    public struct Entry: Equatable {
        public var tool: String
        public var pid: Int32
        public var start: String
        public var parentPid: Int32
        public var folder: String?
        /// The folder Claude Code's record names; it decides which project
        /// folder holds the session's log.
        public var recordFolder: String?
        public var terminal: String?
        /// The tool's own session id; only Claude Code has one.
        public var sessionId: String?
        /// Where Claude Code was started from ("claude-vscode", "cli").
        public var entrypoint: String?
        public var role: Role
        public var counted: Bool
        public var state: State
        public var paused: Bool
        /// When the state last changed (Unix seconds), if the tool says.
        public var since: Double?
        public var waitingFor: String?
        public var children: [Child]
        /// Whether this process's log is its own to read. False for the older
        /// of two live processes sharing one session id.
        public var claimsLog: Bool
        public var reasons: [Reason]
    }

    public enum StaleReason: Equatable {
        case noProcess
        case differentProgram
        case startTimeDiffers
    }

    /// A Claude record that was ignored, and why.
    public struct StaleRecord: Equatable {
        public var pid: Int32
        public var reason: StaleReason
    }

    public struct Scan: Equatable {
        /// Every tool process that is not a helper of another, counted or not,
        /// in a stable order: tool, folder, start time, pid.
        public var entries: [Entry]
        public var staleRecords: [StaleRecord]
    }

    public static func scan(processes: [ProcInfo], records: [Int32: ClaudeRecords.Record], now: Double) -> Scan {
        var byPid = [Int32: ProcInfo]()
        for process in processes.sorted(by: { $0.pid < $1.pid }) where byPid[process.pid] == nil {
            byPid[process.pid] = process
        }
        func toolOf(_ process: ProcInfo) -> String? {
            ProcessTable.toolKey(program: process.program, args: process.args ?? "")
        }

        // Which records belong to the process now running under their pid.
        var valid = [Int32: (record: ClaudeRecords.Record, verified: Bool)]()
        var stale = [StaleRecord]()
        for (pid, record) in records.sorted(by: { $0.key < $1.key }) {
            guard let process = byPid[pid] else {
                stale.append(StaleRecord(pid: pid, reason: .noProcess))
                continue
            }
            guard toolOf(process) == "claude_code" else {
                stale.append(StaleRecord(pid: pid, reason: .differentProgram))
                continue
            }
            if let started = record.procStart, !started.isEmpty {
                if ProcessTable.sameStart(started, process.start) {
                    valid[pid] = (record, true)
                } else {
                    stale.append(StaleRecord(pid: pid, reason: .startTimeDiffers))
                }
            } else {
                valid[pid] = (record, false)
            }
        }

        func ancestors(_ process: ProcInfo) -> [ProcInfo] {
            var chain = [ProcInfo]()
            var seen: Set<Int32> = [process.pid]
            var next = process.ppid
            while next > 0, !seen.contains(next), let parent = byPid[next], chain.count < 64 {
                chain.append(parent)
                seen.insert(next)
                next = parent.ppid
            }
            return chain
        }

        // Tool processes, ancestors before descendants.
        let toolProcesses = byPid.values.compactMap { process in toolOf(process).map { (process, $0, ancestors(process)) } }
            .sorted { ($0.2.count, $0.0.pid) < ($1.2.count, $1.0.pid) }

        var entries = [Entry]()
        var anchors = [Int32: Int]()  // roots that helpers can join: pid -> index in entries
        for (process, tool, chain) in toolProcesses {
            let own = tool == "claude_code" ? valid[process.pid] : nil
            if let index = chain.compactMap({ anchors[$0.pid] }).first {
                let anchor = entries[index]
                if anchor.tool == tool {
                    // A helper of the same tool joins its session, unless it
                    // has a record of its own for a different session.
                    if own == nil || own?.record.sessionId == anchor.sessionId {
                        entries[index].children.append(Child(pid: process.pid, start: process.start))
                        continue
                    }
                } else if anchor.counted {
                    entries.append(entry(process, tool, own: nil, role: .crossToolChild, counted: false,
                                         reasons: [.otherToolChild(of: anchor.pid)]))
                    continue
                }
            }
            let classified = classify(process, tool, own)
            entries.append(classified)
            if classified.counted || classified.role == .background {
                anchors[process.pid] = entries.count - 1
            }
        }

        // Two live processes with one session id are two sessions; only the
        // newer one's record owns the log.
        var byId = [String: [Int]]()
        for (index, entry) in entries.enumerated() where entry.sessionId != nil && entry.role != .crossToolChild {
            byId[entry.sessionId!, default: []].append(index)
        }
        for indices in byId.values where indices.count > 1 {
            let ordered = indices.sorted {
                let left = (valid[entries[$0].pid]?.record.startedAt ?? 0, entries[$0].pid)
                let right = (valid[entries[$1].pid]?.record.startedAt ?? 0, entries[$1].pid)
                return left < right
            }
            guard let newest = ordered.last else { continue }
            for index in ordered.dropLast() {
                entries[index].claimsLog = false
                entries[index].reasons.append(.duplicateSessionId(withPid: entries[newest].pid))
            }
        }

        let toolOrder = Tools.tools.map(\.key)
        entries.sort { left, right in
            let keyLeft = (toolOrder.firstIndex(of: left.tool) ?? Int.max, left.folder ?? "",
                           ProcessTable.startTime(left.start) ?? 0, left.pid)
            let keyRight = (toolOrder.firstIndex(of: right.tool) ?? Int.max, right.folder ?? "",
                            ProcessTable.startTime(right.start) ?? 0, right.pid)
            return keyLeft < keyRight
        }
        return Scan(entries: entries, staleRecords: stale)
    }

    private static func entry(_ process: ProcInfo, _ tool: String,
                              own: (record: ClaudeRecords.Record, verified: Bool)?,
                              role: Role, counted: Bool, reasons: [Reason]) -> Entry {
        Entry(tool: tool, pid: process.pid, start: process.start, parentPid: process.ppid,
              folder: process.folder ?? own?.record.cwd, recordFolder: own?.record.cwd, terminal: process.tty,
              sessionId: own?.record.sessionId, entrypoint: own?.record.entrypoint, role: role,
              counted: counted, state: .unknown, paused: process.stopped, since: nil, waitingFor: nil,
              children: [], claimsLog: true, reasons: reasons)
    }

    private static func classify(_ process: ProcInfo, _ tool: String,
                                 _ own: (record: ClaudeRecords.Record, verified: Bool)?) -> Entry {
        guard tool == "claude_code" else {
            let server = ActiveSessions.isBackgroundServer(tool, args: process.args ?? "")
            if process.tty != nil && !server {
                return entry(process, tool, own: nil, role: .session, counted: true, reasons: [.hasTerminal])
            }
            var reasons = [Reason]()
            if process.tty == nil { reasons.append(.noTerminal) }
            if server { reasons.append(.server) }
            return entry(process, tool, own: nil, role: .unclassified, counted: false, reasons: reasons)
        }
        guard let (record, verified) = own else {
            return entry(process, tool, own: nil, role: .session, counted: true, reasons: [.noRecord])
        }
        var role = Role.session
        var counted = true
        var reasons = [Reason]()
        var showsStatus = true
        switch record.kind {
        case .interactive: reasons.append(.interactiveRecord)
        case .background: (role, counted) = (.background, false); reasons.append(.backgroundAgent("bg"))
        case .daemon: (role, counted) = (.background, false); reasons.append(.backgroundAgent("daemon"))
        case .daemonWorker: (role, counted) = (.background, false); reasons.append(.backgroundAgent("daemon-worker"))
        case .unrecognized(let raw): showsStatus = false; reasons.append(.recordKindUnrecognized(raw))
        case .missing: showsStatus = false; reasons.append(.recordKindMissing)
        }
        var result = entry(process, tool, own: own, role: role, counted: counted, reasons: reasons)
        if !verified {
            result.reasons.append(.unverifiedRecord)
        } else if showsStatus {
            switch record.status {
            case .busy: result.state = .active
            case .waiting: result.state = .waiting
            case .idle: result.state = .idle
            case .shell, .unrecognized, .missing: result.state = .unknown
            }
            result.since = record.statusUpdatedAt
            if record.status == .waiting { result.waitingFor = record.waitingFor }
        }
        return result
    }
}

extension ProcessTable {
    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    /// The start-time text as Unix seconds (it is UTC), or nil if it isn't in
    /// `ps`'s format. Used to order rows only; whether two start times are the
    /// same is `sameStart`, which compares the text.
    public static func startTime(_ text: String) -> Double? {
        let squeezed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return startFormatter.date(from: squeezed)?.timeIntervalSince1970
    }
}
