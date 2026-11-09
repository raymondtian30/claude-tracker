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

        public init(label: String, tokens: Int?, cwd: String? = nil, log: String? = nil,
                    plugins: [Plugins.Tag]? = nil) {
            self.label = label
            self.tokens = tokens
            self.cwd = cwd
            self.log = log
            self.plugins = plugins
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

    /// Working directory of each running process whose executable is `name`
    /// (or, for a Node-based tool in `nodeScripts`, that runs its script).
    public static func runningCwds(_ name: String, run: Run = runCommand) throws -> [String] {
        let pids: [String]
        if let script = nodeScripts[name] {
            pids = pidsRunningScript(try checkedOutput(["ps", "-eo", "pid,args"], run), script)
        } else {
            pids = pidsNamed(try checkedOutput(["ps", "-eo", "pid,comm"], run), name)
        }

        var cwds = [String]()
        for pid in pids {
            let result = try run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"])
            for line in pythonLines(result.stdout) where line.hasPrefix("n") {
                cwds.append(String(line.dropFirst()))
            }
        }
        return cwds
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

    /// Best-effort list of currently running Claude Code terminals.
    ///
    /// Each running `claude` process is matched to the most-recently-modified
    /// session file in its project directory (the CLI doesn't expose which exact
    /// file belongs to which pid). When several processes share a directory, the
    /// top-N most recently modified files there are used, N being how many
    /// processes share it.
    ///
    /// Returns sessions with label, tokens, cwd and log (the session file's
    /// path), most tokens first.
    public static func activeSessions(projectsDir: URL = TokenMath.claudeProjectsDir, cwds: [String]? = nil,
                                      run: Run = runCommand) throws -> [Session] {
        let cwds = try cwds ?? runningClaudeCwds(run: run)
        // Python's Counter: each folder once, in first-seen order, with a count.
        var order = [String]()
        var counts = [String: Int]()
        for cwd in cwds {
            if counts[cwd] == nil {
                order.append(cwd)
            }
            counts[cwd, default: 0] += 1
        }

        var sessions = [Session]()
        for cwd in order {
            let projectDir = projectDirForCwd(cwd, projectsDir: projectsDir)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: projectDir.path)) ?? []
            let files = names.filter { $0.hasSuffix(".jsonl") }
                .map { projectDir.path + "/" + $0 }
                .compactMap { path in SourceFile.Stat(path).map { (path, $0.mtime) } }
                .sorted { $0.1 > $1.1 }
            for (path, _) in files.prefix(counts[cwd] ?? 0) {
                let (tokens, _) = try TokenMath.sumUsageSince(path, offset: 0)
                sessions.append(Session(label: displayName(cwd), tokens: tokens, cwd: cwd, log: path))
            }
        }

        // Stable, as Python's sort: equal counts keep their order.
        return sessions.enumerated()
            .sorted { ($0.element.tokens ?? 0, $1.offset) > ($1.element.tokens ?? 0, $0.offset) }
            .map(\.element)
    }

    /// Running sessions of a tool that has no per-session token counts
    /// (Codex, opencode): one row per process, labeled by its folder.
    public static func runningToolSessions(_ name: String, home: String? = nil, cwds: [String]? = nil,
                                           run: Run = runCommand) throws -> [Session] {
        // Processes sitting in "/" are background helpers (e.g. an editor
        // extension's server), not sessions someone started in a project.
        try (cwds ?? runningCwds(name, run: run))
            .filter { $0 != "/" }
            .map { Session(label: displayName($0, home: home), tokens: nil) }
    }
}
