import Foundation

/// The AI tool sessions running right now, found from the process list
/// (`ps`) and each process's working folder (`lsof`).
public enum ActiveSessions {
    /// One running session, as the Active Sessions tab lists it.
    public struct Session: Equatable {
        public var label: String
        /// Tokens used so far, or nil for tools without per-session counts.
        public var tokens: Int?
        /// Claude Code sessions only: the folder it runs in and its log file.
        public var cwd: String?
        public var log: String?
        /// The plugins a Claude Code session runs, set by `Plugins.livePlugins`.
        public var plugins: [Plugins.Tag]?
        /// Claude Code sessions only: the process it runs in, and whether that
        /// is paused. nil when the process isn't known (the Live tab then has
        /// no Stop or Quit for it).
        public var pid: Int32?
        public var stopped: Bool
        /// What Claude Code says it is doing: "busy" or "idle" (nil when it
        /// doesn't say), and since when (Unix seconds).
        public var status: String?
        public var since: Double?
        /// The chat's title, as the editor shows it, to tell sessions apart.
        public var title: String?
        /// Where it runs: "VS Code" or "Terminal", when Claude Code says.
        public var kind: String?

        public init(label: String, tokens: Int?, cwd: String? = nil, log: String? = nil,
                    plugins: [Plugins.Tag]? = nil, pid: Int32? = nil, stopped: Bool = false,
                    status: String? = nil, since: Double? = nil, title: String? = nil, kind: String? = nil) {
            self.status = status
            self.since = since
            self.title = title
            self.kind = kind
            self.label = label
            self.tokens = tokens
            self.cwd = cwd
            self.log = log
            self.plugins = plugins
            self.pid = pid
            self.stopped = stopped
        }
    }

    /// What a command printed and how it exited.
    public struct CommandResult {
        public var status: Int32
        public var stdout: String

        public init(status: Int32, stdout: String) {
            self.status = status
            self.stdout = stdout
        }
    }

    /// Runs a command (found on PATH, like Python's subprocess) and returns
    /// what it printed. Injectable so tests needn't run `ps` or `lsof`.
    public typealias Run = (_ arguments: [String]) throws -> CommandResult

    /// A command that must succeed didn't (Python's CalledProcessError).
    public struct CommandFailed: Error, CustomStringConvertible {
        public let description: String
    }

    /// Runs `arguments` through /usr/bin/env, capturing stdout and dropping
    /// stderr.
    public static func runCommand(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read before waiting, so a full pipe can't stall the command.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }

    /// Return the working directory of each currently running `claude` CLI
    /// process, one entry per process (duplicates if several share a directory).
    public static func runningClaudeCwds(run: Run = runCommand) throws -> [String] {
        try runningCwds("claude", run: run)
    }

    // Tools that run as a Node script, so their process is "node": matched by
    // the script in the command line instead (tool key -> script name).
    public static let nodeScripts = ["gemini_cli": "gemini"]

    /// The process ids of the running processes whose executable is `name`
    /// (or, for a Node-based tool in `nodeScripts`, that runs its script).
    static func toolPids(_ name: String, _ run: Run) throws -> [String] {
        if let script = nodeScripts[name] {
            return pidsRunningScript(try checkedOutput(["ps", "-eo", "pid,args"], run), script)
        }
        return pidsNamed(try checkedOutput(["ps", "-eo", "pid,comm"], run), name)
    }

    /// Working directory of each running process whose executable is `name`
    /// (or, for a Node-based tool in `nodeScripts`, that runs its script).
    public static func runningCwds(_ name: String, run: Run = runCommand) throws -> [String] {
        let pids = try toolPids(name, run)

        var cwds = [String]()
        for pid in pids {
            let result = try run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"])
            for line in pythonLines(result.stdout) where line.hasPrefix("n") {
                cwds.append(String(line.dropFirst()))
            }
        }
        return cwds
    }

    /// Where Claude Code records each running process (`<pid>.json`).
    public static let claudeSessionsDir = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    /// What Claude Code's record of a process says that is worth showing.
    public struct SessionInfo: Equatable {
        public var sessionId: String
        public var status: String?
        /// When the status last changed (Unix seconds), if recorded.
        public var updatedAt: Double?
        /// Where it was started from ("claude-vscode", "cli"...), if recorded.
        public var entrypoint: String? = nil
    }

    /// Claude Code's record of process `pid` running in `cwd`: its session
    /// (so its exact log file) and whether it is busy or idle. Only those
    /// fields are read; the file holds more. nil when there is no record, it
    /// isn't that process (a leftover under a reused id) or the id isn't a
    /// plain session id (it becomes part of a file name).
    public static func sessionInfo(pid: Int32, cwd: String, sessionsDir: URL = claudeSessionsDir) -> SessionInfo? {
        let url = sessionsDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              object.int("pid") == Int(pid), object.string("cwd") == cwd,
              let id = object.string("sessionId"), !id.isEmpty,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        let milliseconds = JSON.double(object["statusUpdatedAt"]) ?? JSON.double(object["updatedAt"])
        return SessionInfo(sessionId: id, status: object.string("status"), updatedAt: milliseconds.map { $0 / 1000 },
                           entrypoint: object.string("entrypoint"))
    }

    /// What to call where a session runs, for the entrypoints Claude Code
    /// records; nil for any other.
    public static func kindLabel(entrypoint: String?) -> String? {
        switch entrypoint {
        case "claude-vscode": return "VS Code"
        case "cli": return "Terminal"
        default: return nil
        }
    }

    /// How much of the end of a log is searched for the chat's title.
    static let titleTailBytes = 512 * 1024

    /// The chat's title: the one the user typed, else the generated one, as the
    /// editor shows it on the chat's tab. Claude Code writes it into the log
    /// again and again, so only the end of the log is read. One short line, or
    /// nil when there is none. Shown on the Live tab only, never saved.
    public static func chatTitle(log path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(titleTailBytes) ? size - UInt64(titleTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // it begins part way through a line
        var generated: String?
        for line in lines.reversed() where line.contains("-title") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSONObject else { continue }
            if object.string("type") == "custom-title", let title = oneLine(object.string("customTitle")) {
                return title
            }
            if generated == nil, object.string("type") == "ai-title" {
                generated = oneLine(object.string("aiTitle"))
            }
        }
        return generated
    }

    /// `text` on one line of at most 60 characters, or nil if nothing is left.
    private static func oneLine(_ text: String?) -> String? {
        let words = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.isEmpty { return nil }
        return words.count > 60 ? String(words.prefix(59)) + "…" : words
    }

    /// A running process: its id, the folder it runs in and whether it is paused.
    public struct Proc: Equatable {
        public var pid: Int32
        public var cwd: String
        public var stopped: Bool

        public init(pid: Int32, cwd: String, stopped: Bool) {
            self.pid = pid
            self.cwd = cwd
            self.stopped = stopped
        }
    }

    /// A process found in `ps -eo pid,stat,comm`, before its folder is known.
    public struct Listed: Equatable {
        public var pid: Int32
        public var stopped: Bool
    }

    /// The processes named `name` in `ps -eo pid,stat,comm` output. A process
    /// is paused when its state has a `T` (Ctrl-Z, or SIGSTOP from Stop).
    public static func processesNamed(_ psOutput: String, _ name: String) -> [Listed] {
        var found = [Listed]()
        for line in pythonLines(psOutput).dropFirst() {
            let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let comm = parts[2].trimmingCharacters(in: .whitespaces)
            if basename(comm) == name {
                found.append(Listed(pid: pid, stopped: parts[1].contains("T")))
            }
        }
        return found
    }

    /// Each running process named `name`, with its working folder. One `ps`
    /// and one `lsof` per process, so this is slow-ish: call it off the main thread.
    public static func runningProcesses(_ name: String, run: Run = runCommand) throws -> [Proc] {
        let listed = processesNamed(try checkedOutput(["ps", "-eo", "pid,stat,comm"], run), name)
        var found = [Proc]()
        for process in listed {
            let result = try run(["lsof", "-a", "-p", String(process.pid), "-d", "cwd", "-Fn"])
            for line in pythonLines(result.stdout) where line.hasPrefix("n") {
                found.append(Proc(pid: process.pid, cwd: String(line.dropFirst()), stopped: process.stopped))
            }
        }
        return found
    }

    /// stdout of a command that must exit 0 (Python's `check=True`).
    static func checkedOutput(_ arguments: [String], _ run: Run) throws -> String {
        let result = try run(arguments)
        guard result.status == 0 else {
            throw CommandFailed(description: "\(arguments.joined(separator: " ")) exited with \(result.status)")
        }
        return result.stdout
    }

    /// Python's `str.splitlines()`: no empty last line for a trailing newline.
    static func pythonLines(_ text: String) -> [String] {
        var lines = [String]()
        text.enumerateLines { line, _ in lines.append(line) }
        return lines
    }

    public static func claudePids(_ psOutput: String) -> [String] {
        pidsNamed(psOutput, "claude")
    }

    /// PIDs of processes named `name` in `ps -eo pid,comm` output.
    ///
    /// macOS `ps` prints the full executable path in the comm column (e.g. the
    /// VS Code extension's .../native-binary/claude), so match on the basename.
    public static func pidsNamed(_ psOutput: String, _ name: String) -> [String] {
        var pids = [String]()
        for line in pythonLines(psOutput).dropFirst() {
            // Python's line.split(None, 1): the pid, then the rest as is.
            let trimmed = line.drop { $0.isWhitespace }
            guard let gap = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            let pid = trimmed[..<gap]
            let comm = trimmed[gap...].trimmingCharacters(in: .whitespaces)
            if comm.isEmpty {
                continue
            }
            if basename(comm) == name {
                pids.append(String(pid))
            }
        }
        return pids
    }

    /// PIDs of `node <...>/script ...` processes in `ps -eo pid,args` output.
    public static func pidsRunningScript(_ psOutput: String, _ script: String) -> [String] {
        var pids = [String]()
        for line in pythonLines(psOutput).dropFirst() {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count >= 3, basename(parts[1]) == "node", basename(parts[2]) == script {
                pids.append(parts[0])
            }
        }
        return pids
    }

    /// Python's `os.path.basename`: whatever follows the last "/".
    static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    public static func projectDirForCwd(_ cwd: String, projectsDir: URL = TokenMath.claudeProjectsDir) -> URL {
        // Claude Code names each project's log folder after its cwd with every
        // non-alphanumeric character (slashes, spaces, dots...) replaced by "-".
        let name = String(String.UnicodeScalarView(cwd.unicodeScalars.map { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? scalar : "-"
        }))
        return projectsDir.appendingPathComponent(name)
    }

    public static func displayName(_ cwd: String, home: String? = nil) -> String {
        let home = home ?? UsageStats.homeDirectory
        if cwd == home {
            return "~"
        }
        if cwd.hasPrefix(home + "/") {
            return "~/" + cwd.dropFirst(home.count + 1)
        }
        return cwd
    }

    /// The Claude Code sessions running right now.
    ///
    /// With `processes` (what `runningProcesses` found), a process that Claude
    /// Code has a record of (`sessionInfo`) gets exactly its own log and its
    /// busy or idle status, and is listed even before its first message.
    /// Any other process is matched to the most recently written log in its
    /// folder that no other process owns (the CLI doesn't say which file is
    /// whose); when several share a folder, the top-N logs there are used and
    /// paired in order of process id.
    ///
    /// Without `processes`, each running `claude` folder (or the given
    /// `cwds`) is matched that way, with no process attached.
    ///
    /// Returns sessions with label, tokens, cwd and log (the session file's
    /// path), most tokens first.
    public static func activeSessions(projectsDir: URL = TokenMath.claudeProjectsDir, cwds: [String]? = nil,
                                      processes: [Proc]? = nil, sessionsDir: URL = claudeSessionsDir,
                                      run: Run = runCommand) throws -> [Session] {
        var sessions = [Session]()
        var claimed = Set<String>()
        var unknown = processes
        if let processes = processes {
            var stillUnknown = [Proc]()
            for process in processes {
                guard let info = sessionInfo(pid: process.pid, cwd: process.cwd, sessionsDir: sessionsDir) else {
                    stillUnknown.append(process)
                    continue
                }
                let log = projectDirForCwd(process.cwd, projectsDir: projectsDir)
                    .appendingPathComponent("\(info.sessionId).jsonl").path
                let exists = FileManager.default.fileExists(atPath: log)
                if exists { claimed.insert(log) }
                sessions.append(Session(label: displayName(process.cwd),
                                        tokens: exists ? try TokenMath.sumUsageSince(log, offset: 0).0 : nil,
                                        cwd: process.cwd, log: exists ? log : nil, pid: process.pid,
                                        stopped: process.stopped, status: info.status, since: info.updatedAt,
                                        title: exists ? chatTitle(log: log) : nil,
                                        kind: kindLabel(entrypoint: info.entrypoint)))
            }
            unknown = stillUnknown
        }

        let cwds = try cwds ?? unknown?.map(\.cwd) ?? runningClaudeCwds(run: run)
        // Python's Counter: each folder once, in first-seen order, with a count.
        var order = [String]()
        var counts = [String: Int]()
        for cwd in cwds {
            if counts[cwd] == nil {
                order.append(cwd)
            }
            counts[cwd, default: 0] += 1
        }

        for cwd in order {
            let projectDir = projectDirForCwd(cwd, projectsDir: projectsDir)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: projectDir.path)) ?? []
            let files = names.filter { $0.hasSuffix(".jsonl") }
                .map { projectDir.path + "/" + $0 }
                .filter { !claimed.contains($0) }
                .compactMap { path in SourceFile.Stat(path).map { (path, $0.mtime) } }
                .sorted { $0.1 > $1.1 }
            let here = (unknown ?? []).filter { $0.cwd == cwd }.sorted { $0.pid < $1.pid }
            for (position, (path, _)) in files.prefix(counts[cwd] ?? 0).enumerated() {
                let (tokens, _) = try TokenMath.sumUsageSince(path, offset: 0)
                let process = position < here.count ? here[position] : nil
                sessions.append(Session(label: displayName(cwd), tokens: tokens, cwd: cwd, log: path,
                                        pid: process?.pid, stopped: process?.stopped ?? false))
            }
        }

        // Stable, as Python's sort: equal counts keep their order.
        return sessions.enumerated()
            .sorted { ($0.element.tokens ?? 0, $1.offset) > ($1.element.tokens ?? 0, $0.offset) }
            .map(\.element)
    }

    /// Subcommands that start a server instead of a session someone works in
    /// (Codex's app server and its daemon, opencode's server), by tool.
    public static let serverSubcommands: [String: Set<String>] = [
        "codex": ["app-server", "mcp-server"],
        "opencode": ["serve", "web", "acp"],
    ]

    /// Options that take the next word as their value, so that word is not
    /// the subcommand (`codex -c key=value app-server`).
    private static let optionsWithValue: [String: Set<String>] = [
        "codex": ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a",
                  "--ask-for-approval", "-C", "--cd", "-i", "--image", "--add-dir"],
    ]

    /// Whether a process of `tool` with command line `args` is a background
    /// server: the first word after the program that isn't an option is a
    /// server subcommand. Anything unclear counts as a session, so a real one
    /// is never hidden.
    public static func isBackgroundServer(_ tool: String, args: String) -> Bool {
        guard let servers = serverSubcommands[tool] else { return false }
        let program = nodeScripts[tool] ?? tool
        let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let at = words.firstIndex(where: { basename($0) == program }) else { return false }
        var skipNext = false
        for word in words[(at + 1)...] {
            if skipNext {
                skipNext = false
            } else if word.hasPrefix("-") {
                skipNext = optionsWithValue[tool]?.contains(word) == true
            } else {
                return servers.contains(word)
            }
        }
        return false
    }

    /// Running sessions of a tool that has no per-session token counts
    /// (Codex, opencode): one row per process, labeled by its folder.
    /// Background servers are not sessions and are left out (see
    /// `isBackgroundServer`), nor are processes in "/" (an editor extension's
    /// helpers). `cwds` stands in for the search, in tests.
    public static func runningToolSessions(_ name: String, home: String? = nil, cwds: [String]? = nil,
                                           run: Run = runCommand) throws -> [Session] {
        var folders = cwds ?? []
        if cwds == nil {
            for pid in try toolPids(name, run) {
                let args = (try? run(["ps", "-p", pid, "-o", "args="]))?.stdout ?? ""
                if isBackgroundServer(name, args: args) { continue }
                let result = try run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"])
                for line in pythonLines(result.stdout) where line.hasPrefix("n") {
                    folders.append(String(line.dropFirst()))
                }
            }
        }
        return folders.filter { $0 != "/" }.map { Session(label: displayName($0, home: home), tokens: nil) }
    }
}
