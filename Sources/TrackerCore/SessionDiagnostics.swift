import Foundation

/// The diagnostics report: for every process the scan considered, why it was
/// counted or not. Built on demand from one fresh scan by a pure function, and
/// pasted into bug reports, so it carries only what is needed to explain a
/// decision: the program name, known subcommand words and flag names (never
/// their values, prompts or full paths), the home folder as `~`, and no
/// environment, chat title or subagent description.
public enum SessionDiagnostics {
    /// Bumped when the report's layout changes, so a pasted report says which
    /// layout it has.
    public static let formatVersion = 1

    /// Subcommand words that are safe to print. A positional word that is not
    /// one of these (a prompt, a value) is left out.
    static let knownWords: Set<String> = Set(ActiveSessions.serverSubcommands.values.flatMap { $0 }).union([
        "daemon", "pid-update-loop", "exec", "run", "resume", "login", "logout", "mcp", "review", "apply", "completion",
    ])

    public static func report(processes: [ProcInfo], records: [Int32: ClaudeRecords.Record],
                              previous: SessionRegistry.Snapshot? = nil, now: Double,
                              timings: [(phase: String, ms: Int)] = [], home: String? = nil,
                              version: String = Version.version) -> String {
        let snapshot = SessionRegistry.reduce(previous: previous, processes: processes, records: records, now: now)
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = snapshot.scan.entries

        func name(_ tool: String) -> String { Tools.toolNames[tool] ?? tool }
        func folder(_ path: String?) -> String { path.map { ActiveSessions.displayName($0, home: home) } ?? "unknown" }

        func block(_ entry: SessionRules.Entry, withState: Bool) -> [String] {
            var lines = ["- \(name(entry.tool)), pid \(entry.pid), started \(entry.start) UTC"]
            if let process = byPid[entry.pid] {
                let shown = command(program: process.program, args: process.args ?? "")
                if shown != process.program { lines.append("  command: \(shown)") }
            }
            var facts = ["in path \(folder(entry.folder))", "terminal: \(entry.terminal ?? "none")"]
            if withState { facts.append("state: \(stateWord(entry))") }
            lines.append("  " + facts.joined(separator: " · "))
            lines.append("  why: " + entry.reasons.map(describe).joined(separator: ", "))
            if !entry.children.isEmpty {
                let ids = entry.children.map { String($0.pid) }.joined(separator: ", ")
                lines.append("  helpers: pid\(entry.children.count == 1 ? "" : "s") \(ids)")
            }
            return lines
        }

        func section(_ title: String, _ items: [[String]]) -> String {
            ([("\(title) (\(items.count))")] + items.flatMap { $0 }).joined(separator: "\n")
        }

        let counted = entries.filter(\.counted).map { block($0, withState: true) }
        let background = entries.filter { $0.role == .background }.map { block($0, withState: true) }
        let notCounted = entries.filter { !$0.counted && $0.role != .background }.map { block($0, withState: false) }
        let ignored = snapshot.scan.staleRecords.map { ["- pid \($0.pid): \(describe($0.reason))"] }
        let ended = snapshot.ended.map { ["- \(name($0.tool)), pid \($0.pid), started \($0.start) UTC"] }

        let toolProcesses = processes.filter {
            ProcessTable.toolKey(program: $0.program, args: $0.args ?? "") != nil
        }.count
        var scan = "Scan: \(processes.count) processes, \(toolProcesses) of them tool processes"
        for timing in timings { scan += " · \(timing.phase) \(timing.ms) ms" }

        let head = ["Claude Tracker session diagnostics",
                    "Format \(formatVersion) · Claude Tracker \(version) · \(utc(now))", scan].joined(separator: "\n")
        return ([head, section("Counted sessions", counted), section("Background agents", background),
                 section("Not counted", notCounted), section("Records ignored", ignored),
                 section("Ended since the last scan", ended)]).joined(separator: "\n\n") + "\n"
    }

    /// The program, the known subcommand words after it and the names of its
    /// flags, in order: `codex app-server --listen --managed-daemon`. Values
    /// of flags, prompts and paths are left out.
    static func command(program: String, args: String) -> String {
        let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
        var shown = [program]
        guard let at = words.firstIndex(where: { ActiveSessions.basename($0) == program }) else { return program }
        var rest = words[(at + 1)...]
        // A Node script (Gemini CLI): the script's name stands in for the tool.
        if program == "node", let script = rest.first, ActiveSessions.nodeScripts.values.contains(ActiveSessions.basename(script)) {
            shown.append(ActiveSessions.basename(script))
            rest = rest.dropFirst()
        }
        var flags = 0
        for word in rest {
            if word.hasPrefix("-") {
                guard flags < 12 else { continue }
                flags += 1
                shown.append(String(word.prefix { $0 != "=" }))
            } else if knownWords.contains(word) {
                shown.append(word)
            }
        }
        return shown.joined(separator: " ")
    }

    private static func stateWord(_ entry: SessionRules.Entry) -> String {
        let word: String
        switch entry.state {
        case .active: word = "active"
        case .waiting: word = "waiting"
        case .idle: word = "idle"
        case .unknown: word = "unknown"
        }
        return entry.paused ? "\(word), paused" : word
    }

    static func describe(_ reason: SessionRules.Reason) -> String {
        func raw(_ text: String) -> String { String(text.filter { !$0.isNewline }.prefix(30)) }
        switch reason {
        case .interactiveRecord: return "interactive record"
        case .recordKindUnrecognized(let kind): return "record kind \"\(raw(kind))\" not recognized, counted as Unknown"
        case .recordKindMissing: return "record has no kind, counted as Unknown"
        case .noRecord: return "no record for this process, counted as Unknown"
        case .unverifiedRecord: return "record has no start time to check, state Unknown"
        case .hasTerminal: return "has a terminal"
        case .noTerminal: return "no terminal"
        case .server: return "server command"
        case .backgroundAgent(let kind): return "background agent (\(raw(kind)))"
        case .otherToolChild(let pid): return "started by the session with pid \(pid) (another tool)"
        case .duplicateSessionId(let pid): return "same session id as pid \(pid) (newer); does not claim the log"
        }
    }

    static func describe(_ reason: SessionRules.StaleReason) -> String {
        switch reason {
        case .noProcess: return "no process with that id"
        case .differentProgram: return "the process is now another program"
        case .startTimeDiffers: return "the process started at a different time (the id was reused)"
        }
    }

    private static func utc(_ seconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: seconds)) + " UTC"
    }
}
