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
        /// Which tool it is (a key of `Tools.tools`); nil where it isn't
        /// known, which `Plugins.livePlugins` reads as Claude Code.
        public var tool: String?
        /// What the registry decided it is doing; nil where it didn't say.
        public var state: SessionRules.State?
        /// What it waits for ("input needed"), when it is waiting.
        public var waitingFor: String?
        /// When its process started (`ps` text under `TZ=UTC`); with the pid,
        /// what Stop and Quit check before signalling.
        public var start: String?
        /// Subagents running in it (Claude Code only).
        public var subagents: [Subagent]

        public init(label: String, tokens: Int?, cwd: String? = nil, log: String? = nil,
                    plugins: [Plugins.Tag]? = nil, pid: Int32? = nil, stopped: Bool = false,
                    status: String? = nil, since: Double? = nil, title: String? = nil, kind: String? = nil,
                    tool: String? = nil, state: SessionRules.State? = nil, waitingFor: String? = nil,
                    start: String? = nil, subagents: [Subagent] = []) {
            self.tool = tool
            self.state = state
            self.waitingFor = waitingFor
            self.start = start
            self.subagents = subagents
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

        /// Whether the Live tab offers Stop, Resume and Quit for it: any
        /// session with a known process id.
        public var isControllable: Bool { pid != nil }
    }

    /// A command that must succeed didn't (Python's CalledProcessError).
    public struct CommandFailed: Error, CustomStringConvertible {
        public let description: String
    }

    // Tools that run as a Node script, so their process is "node": matched by
    // the script in the command line instead (tool key -> script name).
    public static let nodeScripts = ["gemini_cli": "gemini"]

    /// Where Claude Code records each running process (`<pid>.json`).
    public static let claudeSessionsDir = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".claude/sessions", isDirectory: true)

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
    static func oneLine(_ text: String?) -> String? {
        let words = (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.isEmpty { return nil }
        return words.count > 60 ? String(words.prefix(59)) + "…" : words
    }

    /// Python's `str.splitlines()`: no empty last line for a trailing newline.
    static func pythonLines(_ text: String) -> [String] {
        var lines = [String]()
        text.enumerateLines { line, _ in lines.append(line) }
        return lines
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

}
