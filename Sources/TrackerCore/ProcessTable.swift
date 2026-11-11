import Foundation

/// One running process, as the process reader sees it.
public struct ProcInfo: Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// The controlling terminal ("ttys011"), or nil when it has none.
    public var tty: String?
    /// `ps` state letters; a `T` means paused (Ctrl-Z, or SIGSTOP from Stop).
    public var state: String
    /// When it started, as `ps` prints it under `TZ=UTC` ("Tue Nov 10 18:46:36
    /// 2026"): the same text Claude Code writes as `procStart`.
    public var start: String
    /// The executable's name, without its folder ("claude", "codex").
    public var program: String
    /// The whole command line. Read only for processes that might be an AI
    /// tool (see `ProcessTable.candidatePrograms`); nil for the rest.
    public var args: String?
    /// The folder it runs in. Read only for processes of an AI tool.
    public var folder: String?

    public init(pid: Int32, ppid: Int32, tty: String?, state: String, start: String, program: String,
                args: String? = nil, folder: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.state = state
        self.start = start
        self.program = program
        self.args = args
        self.folder = folder
    }

    public var stopped: Bool { state.contains("T") }
}

/// The process table: every running process with its parent, terminal, state
/// and start time, plus the command line and folder of the ones that might be
/// an AI tool. Three spawns however many processes there are (`ps` for all,
/// `ps -p` for the candidates' command lines, `lsof -b` for their folders: `-b`
/// keeps `lsof` from waiting on a folder that lives on a dead network mount),
/// instead of one or two per process. Takes about 70 ms with 500 processes.
public enum ProcessTable {
    /// Gives the whole table. Injected into the registry so tests need no `ps`.
    public typealias Reader = () throws -> [ProcInfo]

    /// Programs whose command line is read: the AI tools' own, and `node`
    /// (Gemini CLI is a Node script).
    public static let candidatePrograms: Set<String> = ["claude", "codex", "opencode", "node"]

    /// The tool key for programs that name a tool by themselves.
    static let programTools = ["claude": "claude_code", "codex": "codex", "opencode": "opencode"]

    /// Which tool a process belongs to, from its program and command line, or
    /// nil for any other process.
    public static func toolKey(program: String, args: String) -> String? {
        if let tool = programTools[program] { return tool }
        guard program == "node" else { return nil }
        let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
        for (tool, script) in ActiveSessions.nodeScripts
        where words.count >= 2 && ActiveSessions.basename(words[0]) == "node"
            && ActiveSessions.basename(words[1]) == script {
            return tool
        }
        return nil
    }

    /// Reads the table. Throws when `ps` itself fails (the caller keeps what
    /// it had); a failed or partial `ps -p` or `lsof` only leaves command
    /// lines or folders empty, since both exit non-zero when a process ended
    /// between the calls.
    public static func read(run: Subprocess.Runner = Subprocess.run) throws -> [ProcInfo] {
        let listed = run(["env", "TZ=UTC", "LC_ALL=C", "ps", "-axww", "-o", "pid=,ppid=,tty=,stat=,lstart=,comm="], nil)
        guard listed.status == 0 else {
            throw ActiveSessions.CommandFailed(description: "ps exited with \(listed.status)")
        }
        var table = parseTable(listed.stdout)
        // Output that is there but parses to nothing means the format changed:
        // say so, instead of answering "no processes".
        if table.isEmpty, listed.stdout.contains(where: { !$0.isWhitespace }) {
            throw ActiveSessions.CommandFailed(description: "the output of ps could not be read")
        }
        let candidates = table.indices.filter { candidatePrograms.contains(table[$0].program) }
        guard !candidates.isEmpty else { return table }

        let argList = candidates.map { String(table[$0].pid) }.joined(separator: ",")
        let args = parseArgs(run(["ps", "-ww", "-o", "pid=,args=", "-p", argList], nil).stdout)
        for index in candidates {
            table[index].args = args[table[index].pid]
        }

        let tools = candidates.filter {
            toolKey(program: table[$0].program, args: table[$0].args ?? "") != nil
        }
        guard !tools.isEmpty else { return table }
        let folderList = tools.map { String(table[$0].pid) }.joined(separator: ",")
        let folders = parseFolders(run(["lsof", "-b", "-a", "-p", folderList, "-d", "cwd", "-Fpn"], nil).stdout)
        for index in tools {
            table[index].folder = folders[table[index].pid]
        }
        return table
    }

    /// `ps -axww -o pid=,ppid=,tty=,stat=,lstart=,comm=` output. The program
    /// path comes last because it may hold spaces.
    static func parseTable(_ text: String) -> [ProcInfo] {
        var found = [ProcInfo]()
        for line in ActiveSessions.pythonLines(text) {
            // pid ppid tty stat, five words of start time, then the program path.
            let parts = line.split(maxSplits: 9, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 10, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            let tty = String(parts[2])
            let path = parts[9].trimmingCharacters(in: .whitespaces)
            found.append(ProcInfo(pid: pid, ppid: ppid, tty: tty == "??" || tty == "?" ? nil : tty,
                                  state: String(parts[3]), start: parts[4...8].joined(separator: " "),
                                  program: ActiveSessions.basename(path)))
        }
        return found
    }

    /// `ps -ww -o pid=,args=` output: each pid's whole command line.
    static func parseArgs(_ text: String) -> [Int32: String] {
        var found = [Int32: String]()
        for line in ActiveSessions.pythonLines(text) {
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard let first = parts.first, let pid = Int32(first) else { continue }
            found[pid] = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return found
    }

    /// `lsof -Fpn` output: a `p<pid>` line, then that process's `n<folder>`.
    static func parseFolders(_ text: String) -> [Int32: String] {
        var found = [Int32: String]()
        var pid: Int32?
        for line in ActiveSessions.pythonLines(text) {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let current = pid, found[current] == nil {
                found[current] = String(line.dropFirst())
            }
        }
        return found
    }

    /// Whether two start-time texts name the same second. `ps` pads a
    /// single-digit day with a space, so only the spacing is ignored; an
    /// empty text matches nothing.
    public static func sameStart(_ a: String, _ b: String) -> Bool {
        func squeezed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let left = squeezed(a)
        return !left.isEmpty && left == squeezed(b)
    }
}
