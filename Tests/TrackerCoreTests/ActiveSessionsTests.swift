// Ported from tests/test_active_sessions.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private typealias Session = ActiveSessions.Session

private func assistantEntry(_ inputTokens: Int, _ outputTokens: Int) -> JSONObject {
    ["type": "assistant", "message": ["usage": ["input_tokens": inputTokens, "output_tokens": outputTokens]]]
}

@Test func displayNameCollapsesHomeToTilde() {
    #expect(ActiveSessions.displayName("/Users/alice", home: "/Users/alice") == "~")
}

@Test func displayNameCollapsesHomePrefixedPath() {
    #expect(ActiveSessions.displayName("/Users/alice/work/thing", home: "/Users/alice") == "~/work/thing")
}

@Test func displayNameLeavesUnrelatedPathUntouched() {
    #expect(ActiveSessions.displayName("/opt/other", home: "/Users/alice") == "/opt/other")
}

@Test func projectDirForCwdEscapesSlashes() {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let result = ActiveSessions.projectDirForCwd("/Users/alice/work/thing", projectsDir: projectsDir)
    #expect(result == projectsDir.appendingPathComponent("-Users-alice-work-thing"))
}

@Test func activeSessionsSumsTokensPerMatchedProjectDir() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let project = tmp.mkdir("projects/-Users-alice-work-thing")
    writeJSONL(project.appendingPathComponent("session.jsonl"), [assistantEntry(10, 20)])

    let sessions = try ActiveSessions.activeSessions(projectsDir: projectsDir, cwds: ["/Users/alice/work/thing"])

    #expect(sessions == [Session(label: "/Users/alice/work/thing", tokens: 30, cwd: "/Users/alice/work/thing",
                                 log: project.appendingPathComponent("session.jsonl").path)])
}

@Test func activeSessionsIgnoresCwdsWithNoProjectDir() throws {
    let tmp = TempDir()
    let projectsDir = tmp.mkdir("projects")

    let sessions = try ActiveSessions.activeSessions(projectsDir: projectsDir, cwds: ["/Users/alice/nonexistent"])

    #expect(sessions == [])
}

@Test func activeSessionsPicksTopNMostRecentFilesForSharedCwd() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let project = tmp.mkdir("projects/-Users-alice")

    let oldFile = project.appendingPathComponent("old.jsonl")
    writeJSONL(oldFile, [assistantEntry(1, 1)])
    let midFile = project.appendingPathComponent("mid.jsonl")
    writeJSONL(midFile, [assistantEntry(2, 2)])
    let newFile = project.appendingPathComponent("new.jsonl")
    writeJSONL(newFile, [assistantEntry(3, 3)])

    // ensure ordering isn't a coincidence of filesystem write order
    let now = Date().timeIntervalSince1970
    setModificationTime(oldFile, now - 30)
    setModificationTime(midFile, now - 20)
    setModificationTime(newFile, now - 10)

    let sessions = try ActiveSessions.activeSessions(projectsDir: projectsDir, cwds: ["/Users/alice", "/Users/alice"])

    let tokensFound = sessions.compactMap(\.tokens).sorted()
    #expect(tokensFound == [4, 6])  // new.jsonl (6) and mid.jsonl (4), old.jsonl dropped
}

@Test func activeSessionsSortedByTokensDescending() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    writeJSONL(tmp.mkdir("projects/-Users-alice-small").appendingPathComponent("s.jsonl"), [assistantEntry(1, 1)])
    writeJSONL(tmp.mkdir("projects/-Users-alice-big").appendingPathComponent("s.jsonl"), [assistantEntry(100, 100)])

    let sessions = try ActiveSessions.activeSessions(projectsDir: projectsDir,
                                                     cwds: ["/Users/alice/small", "/Users/alice/big"])

    #expect(sessions.map(\.tokens) == [200, 2])
}

@Test func claudePidsMatchesFullExecutablePaths() {
    let psOutput = """
          PID COMM
          101 /Applications/Foo.app/Contents/MacOS/claude
          102 claude
          103 /usr/bin/claudette
          104 /bin/zsh

        """
    #expect(ActiveSessions.claudePids(psOutput) == ["101", "102"])
}

@Test func projectDirForCwdEscapesSpacesAndDots() {
    let tmp = TempDir()
    let result = ActiveSessions.projectDirForCwd("/Users/me/FPS Game 10.23", projectsDir: tmp.root)
    #expect(result == tmp.root.appendingPathComponent("-Users-me-FPS-Game-10-23"))
}

@Test func pidsNamedMatchesFullPaths() {
    let psOutput = """
          PID COMM
          201 /Users/me/.vscode/extensions/openai.chatgpt/bin/macos-aarch64/codex
          202 /opt/homebrew/Cellar/opencode/2.2.5/bin/opencode
          203 codex
          204 /usr/bin/codexx

        """
    #expect(ActiveSessions.pidsNamed(psOutput, "codex") == ["201", "203"])
    #expect(ActiveSessions.pidsNamed(psOutput, "opencode") == ["202"])
}

// Python monkeypatches running_cwds; here the folders are passed in.
@Test func runningToolSessionsLabelsFoldersWithoutTokens() throws {
    let rows = try ActiveSessions.runningToolSessions("codex", home: "/Users/me", cwds: ["/Users/me/game", "/opt/x"])

    #expect(rows == [Session(label: "~/game", tokens: nil), Session(label: "/opt/x", tokens: nil)])
}

@Test func runningToolSessionsSkipsBackgroundHelpersInRoot() throws {
    #expect(try ActiveSessions.runningToolSessions("codex", home: "/Users/me", cwds: ["/", "/Users/me/game"]) == [
        Session(label: "~/game", tokens: nil),
    ])
}

@Test func nodeScriptsAreMatchedByTheirCommand() {
    let psOutput = """
          PID ARGS
          101 node /opt/homebrew/bin/gemini
          102 /usr/local/bin/node /Users/me/.npm-global/bin/gemini --yolo
          103 node /opt/homebrew/bin/other-tool
          104 vim gemini

        """

    #expect(ActiveSessions.pidsRunningScript(psOutput, "gemini") == ["101", "102"])
}

// Not in the Python suite: the injected runner stands in for ps and lsof.
@Test func runningCwdsAsksLsofForEachMatchingProcess() throws {
    var calls = [[String]]()
    let run: ActiveSessions.Run = { arguments in
        calls.append(arguments)
        if arguments[0] == "ps" {
            return .init(status: 0, stdout: "  PID COMM\n  7 /usr/local/bin/codex\n  8 zsh\n")
        }
        return .init(status: 0, stdout: "p7\nfcwd\nn/Users/me/game\n")
    }

    #expect(try ActiveSessions.runningCwds("codex", run: run) == ["/Users/me/game"])
    #expect(calls == [["ps", "-eo", "pid,comm"], ["lsof", "-a", "-p", "7", "-d", "cwd", "-Fn"]])
}

// MARK: - Processes (for Stop and Quit)

@Test func processesNamedReadsPidAndWhetherItIsPaused() {
    let psOutput = """
          PID STAT COMM
          101 S+   /Applications/Foo.app/Contents/MacOS/claude
          102 T    claude
          103 Ss   /usr/bin/claudette
          104 TN   /Users/me/My Apps/claude
          105 R    /bin/zsh

        """
    let found = ActiveSessions.processesNamed(psOutput, "claude")

    #expect(found.map(\.pid) == [101, 102, 104])
    #expect(found.map(\.stopped) == [false, true, true])
}

@Test func runningProcessesGivesPidFolderAndPausedState() throws {
    let run: ActiveSessions.Run = { arguments in
        if arguments[0] == "ps" {
            #expect(arguments == ["ps", "-eo", "pid,stat,comm"])
            return .init(status: 0, stdout: "  PID STAT COMM\n  7 T /usr/local/bin/claude\n  8 S zsh\n  9 S+ claude\n")
        }
        return .init(status: 0, stdout: "p\(arguments[3])\nfcwd\nn/Users/me/app\(arguments[3])\n")
    }

    let found = try ActiveSessions.runningProcesses("claude", run: run)

    #expect(found == [ActiveSessions.Proc(pid: 7, cwd: "/Users/me/app7", stopped: true),
                      ActiveSessions.Proc(pid: 9, cwd: "/Users/me/app9", stopped: false)])
}

@Test func eachSessionGetsAProcessOfItsFolder() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let project = tmp.mkdir("projects/-Users-alice-work")
    let (a, b) = (project.appendingPathComponent("a.jsonl"), project.appendingPathComponent("b.jsonl"))
    writeJSONL(a, [assistantEntry(5, 5)])
    writeJSONL(b, [assistantEntry(1, 1)])
    let now = Date().timeIntervalSince1970
    setModificationTime(a, now - 20)
    setModificationTime(b, now - 10)
    writeJSONL(tmp.mkdir("projects/-Users-alice-solo").appendingPathComponent("s.jsonl"), [assistantEntry(50, 50)])

    let procs = [ActiveSessions.Proc(pid: 30, cwd: "/Users/alice/work", stopped: true),
                 ActiveSessions.Proc(pid: 20, cwd: "/Users/alice/work", stopped: false),
                 ActiveSessions.Proc(pid: 40, cwd: "/Users/alice/solo", stopped: false)]
    let sessions = try ActiveSessions.activeSessions(projectsDir: projectsDir, processes: procs)

    #expect(sessions.count == 3)
    #expect(Set(sessions.compactMap(\.pid)) == [20, 30, 40])  // each process on one row
    #expect(sessions.first { $0.pid == 40 }?.cwd == "/Users/alice/solo")
    #expect(sessions.first { $0.pid == 30 }?.stopped == true && sessions.first { $0.pid == 20 }?.stopped == false)
    #expect(sessions.filter { $0.cwd == "/Users/alice/work" }.count == 2)
}

@Test func sessionsFoundFromGivenFoldersHaveNoProcess() throws {
    let tmp = TempDir()
    writeJSONL(tmp.mkdir("projects/-Users-alice-w").appendingPathComponent("s.jsonl"), [assistantEntry(1, 1)])

    let sessions = try ActiveSessions.activeSessions(projectsDir: tmp.url("projects"), cwds: ["/Users/alice/w"])

    #expect(sessions.map(\.pid) == [nil] && sessions.map(\.stopped) == [false])
}

// MARK: - Claude Code's own record of each process (~/.claude/sessions/<pid>.json)

private let uuid = "32ac5138-6c44-448f-81b7-3d52e5250d48"

private func writeSessionFile(_ dir: URL, pid: Int32, sessionId: String = uuid, cwd: String = "/Users/alice/work",
                              status: String? = "idle", updatedAt: Double = 1_794_279_065_347,
                              extra: [String: Any] = [:]) {
    var body: [String: Any] = ["pid": Int(pid), "sessionId": sessionId, "cwd": cwd, "updatedAt": updatedAt,
                               "messagingSocketPath": "/tmp/secret.sock", "kind": "interactive"]
    if let status = status { body["status"] = status }
    body.merge(extra) { _, new in new }
    let data = try! JSONSerialization.data(withJSONObject: body)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! data.write(to: dir.appendingPathComponent("\(pid).json"))
}

@Test func sessionInfoReadsOnlyWhatItNeeds() {
    let dir = TempDir().url("sessions")
    writeSessionFile(dir, pid: 42, status: "busy")

    let info = ActiveSessions.sessionInfo(pid: 42, cwd: "/Users/alice/work", sessionsDir: dir)

    #expect(info == ActiveSessions.SessionInfo(sessionId: uuid, status: "busy", updatedAt: 1_794_279_065.347))
}

@Test func sessionInfoIsIgnoredWhenItIsNotThatProcess() {
    let dir = TempDir().url("sessions")
    writeSessionFile(dir, pid: 42)
    // A leftover file under a reused pid names another pid or folder.
    writeSessionFile(dir, pid: 43, extra: ["pid": 99])
    writeSessionFile(dir, pid: 44, cwd: "/Users/alice/elsewhere")

    #expect(ActiveSessions.sessionInfo(pid: 43, cwd: "/Users/alice/work", sessionsDir: dir) == nil)
    #expect(ActiveSessions.sessionInfo(pid: 44, cwd: "/Users/alice/work", sessionsDir: dir) == nil)
    #expect(ActiveSessions.sessionInfo(pid: 45, cwd: "/Users/alice/work", sessionsDir: dir) == nil)  // no file
}

@Test func sessionInfoRefusesAnIdThatCouldEscapeTheFolder() {
    let dir = TempDir().url("sessions")
    for (pid, bad) in [(Int32(50), "../../etc/passwd"), (51, "a/b"), (52, ""), (53, "x y")] {
        writeSessionFile(dir, pid: pid, sessionId: bad)
        #expect(ActiveSessions.sessionInfo(pid: pid, cwd: "/Users/alice/work", sessionsDir: dir) == nil)
    }
}

@Test func aProcessWithARecordGetsItsOwnLogAndStatus() throws {
    let tmp = TempDir()
    let project = tmp.mkdir("projects/-Users-alice-work")
    let mine = project.appendingPathComponent("\(uuid).jsonl")
    let newer = project.appendingPathComponent("other.jsonl")
    writeJSONL(mine, [assistantEntry(5, 5)])
    writeJSONL(newer, [assistantEntry(100, 100)])
    let now = Date().timeIntervalSince1970
    setModificationTime(mine, now - 500)
    setModificationTime(newer, now - 5)
    let sessionsDir = tmp.url("sessions")
    writeSessionFile(sessionsDir, pid: 42, status: "idle")

    let sessions = try ActiveSessions.activeSessions(
        projectsDir: tmp.url("projects"), processes: [.init(pid: 42, cwd: "/Users/alice/work", stopped: false)],
        sessionsDir: sessionsDir)

    #expect(sessions.count == 1)
    #expect(sessions[0].tokens == 10 && sessions[0].log == mine.path)  // not the newer log of another chat
    #expect(sessions[0].pid == 42 && sessions[0].status == "idle")
}

@Test func aProcessWithNoMessagesYetIsStillListedWithoutTokens() throws {
    let tmp = TempDir()
    let sessionsDir = tmp.url("sessions")
    writeSessionFile(sessionsDir, pid: 42, status: "idle")

    let sessions = try ActiveSessions.activeSessions(
        projectsDir: tmp.url("projects"), processes: [.init(pid: 42, cwd: "/Users/alice/work", stopped: false)],
        sessionsDir: sessionsDir)

    #expect(sessions.map(\.pid) == [42] && sessions[0].tokens == nil && sessions[0].log == nil)
}

@Test func processesWithoutARecordNeverTakeALogAnotherProcessOwns() throws {
    let tmp = TempDir()
    let project = tmp.mkdir("projects/-Users-alice-work")
    let owned = project.appendingPathComponent("\(uuid).jsonl")
    let free = project.appendingPathComponent("free.jsonl")
    writeJSONL(owned, [assistantEntry(5, 5)])
    writeJSONL(free, [assistantEntry(1, 1)])
    let now = Date().timeIntervalSince1970
    setModificationTime(owned, now - 5)  // the newest, which the old guess would give to both
    setModificationTime(free, now - 50)
    let sessionsDir = tmp.url("sessions")
    writeSessionFile(sessionsDir, pid: 42)

    let sessions = try ActiveSessions.activeSessions(
        projectsDir: tmp.url("projects"),
        processes: [.init(pid: 42, cwd: "/Users/alice/work", stopped: false),
                    .init(pid: 43, cwd: "/Users/alice/work", stopped: false)],
        sessionsDir: sessionsDir)

    #expect(Set(sessions.compactMap(\.log)) == [owned.path, free.path])  // no log twice
    #expect(sessions.first { $0.pid == 43 }?.log == free.path && sessions.first { $0.pid == 43 }?.status == nil)
}

// MARK: - Background servers are not sessions

@Test func serversAreToldFromSessionsByTheirSubcommand() {
    // What `ps` shows for the real processes found on a Mac with the Codex app and opencode installed.
    let servers = [
        ("codex", "/Users/me/.codex/packages/app-server-daemon/releases/0.167.0/bin/codex app-server --listen unix:// --managed-daemon"),
        ("codex", "/Users/me/.codex/packages/app-server-daemon/releases/0.167.0/bin/codex app-server daemon pid-update-loop"),
        ("codex", "/ext/openai.chatgpt-26/bin/codex -c features.code_mode_host=true -c features.x=true app-server --analytics-default-enabled"),
        ("opencode", "/opt/homebrew/Cellar/opencode/2.2.5/bin/opencode serve --service"),
        ("opencode", "/opt/homebrew/bin/opencode web --port 4000"),
    ]
    for (tool, args) in servers {
        #expect(ActiveSessions.isBackgroundServer(tool, args: args), "\(args)")
    }
    let sessions = [
        ("codex", "/Users/me/.local/bin/codex"),
        ("codex", "/Users/me/.local/bin/codex resume --last"),
        ("codex", "/Users/me/.local/bin/codex -c model=x \"fix the app-server tests\""),
        ("opencode", "/opt/homebrew/bin/opencode"),
        ("opencode", "/opt/homebrew/bin/opencode run \"how do I serve static files\""),
        ("gemini_cli", "node /usr/local/bin/gemini"),
    ]
    for (tool, args) in sessions {
        #expect(!ActiveSessions.isBackgroundServer(tool, args: args), "\(args)")
    }
}

@Test func runningToolSessionsLeavesOutTheServers() throws {
    let argsByPid = [
        "7": "/Users/me/.codex/bin/codex app-server --listen unix://",
        "8": "/Users/me/.local/bin/codex",
        "9": "/Users/me/.codex/bin/codex app-server daemon pid-update-loop",
    ]
    let run: ActiveSessions.Run = { arguments in
        switch arguments[0] {
        case "ps" where arguments[1] == "-eo":
            return .init(status: 0, stdout: "  PID COMM\n  7 /Users/me/.codex/bin/codex\n  8 /Users/me/.local/bin/codex\n  9 /Users/me/.codex/bin/codex\n")
        case "ps":
            return .init(status: 0, stdout: (argsByPid[arguments[2]] ?? "") + "\n")
        default:
            return .init(status: 0, stdout: "p\(arguments[3])\nfcwd\nn/Users/me/work\(arguments[3])\n")
        }
    }

    let rows = try ActiveSessions.runningToolSessions("codex", home: "/Users/me", run: run)

    #expect(rows.map(\.label) == ["~/work8"])  // only the one someone is working in
}

// MARK: - The chat's title, as the editor shows it, and what kind of session it is

private func titleLog(_ lines: [JSONObject]) -> URL {
    let url = TempDir().url("session.jsonl")
    writeJSONL(url, lines)
    return url
}

@Test func theLastTitleInTheLogIsTheChatsTitle() {
    let url = titleLog([
        ["type": "user", "message": "hi"],
        ["type": "ai-title", "aiTitle": "First idea"],
        ["type": "assistant", "message": ["usage": ["input_tokens": 1]]],
        ["type": "ai-title", "aiTitle": "Active plugins"],
    ])

    #expect(ActiveSessions.chatTitle(log: url.path) == "Active plugins")
}

@Test func aTitleTheUserTypedWinsOverTheGeneratedOne() {
    let url = titleLog([
        ["type": "custom-title", "customTitle": "My name for it"],
        ["type": "ai-title", "aiTitle": "Generated"],
    ])

    #expect(ActiveSessions.chatTitle(log: url.path) == "My name for it")
}

@Test func noTitleMeansNil() {
    #expect(ActiveSessions.chatTitle(log: titleLog([["type": "user"]]).path) == nil)
    #expect(ActiveSessions.chatTitle(log: "/nonexistent/file.jsonl") == nil)
    #expect(ActiveSessions.chatTitle(log: titleLog([["type": "ai-title", "aiTitle": "  \n "]]).path) == nil)
    #expect(ActiveSessions.chatTitle(log: titleLog([["type": "ai-title", "aiTitle": 5]]).path) == nil)
}

@Test func aTitleIsOneShortLine() {
    let messy = ActiveSessions.chatTitle(log: titleLog([["type": "ai-title", "aiTitle": "  Fix\nthe   chart \t now "]]).path)
    let long = ActiveSessions.chatTitle(log: titleLog([["type": "ai-title", "aiTitle": String(repeating: "word ", count: 30)]]).path)

    #expect(messy == "Fix the chart now")
    #expect(long?.count == 60 && long?.hasSuffix("…") == true)
}

@Test func onlyTheEndOfALongLogIsRead() throws {
    // Titles are written again and again, so the end of the log has one; a
    // log of megabytes isn't read from the top for it.
    let url = TempDir().url("big.jsonl")
    let filler = jsonLine(["type": "user", "message": String(repeating: "x", count: 900)])
    var text = jsonLine(["type": "ai-title", "aiTitle": "Only at the very start"])
    text += String(repeating: filler, count: 1200)  // over 1 MB
    text += jsonLine(["type": "ai-title", "aiTitle": "Near the end"])
    text += jsonLine(["type": "user", "message": "last"])
    writeText(url, text)

    #expect(ActiveSessions.chatTitle(log: url.path) == "Near the end")

    var startOnly = jsonLine(["type": "ai-title", "aiTitle": "Only at the very start"])
    startOnly += String(repeating: filler, count: 1200)
    writeText(url, startOnly)
    #expect(ActiveSessions.chatTitle(log: url.path) == nil)  // out of reach, and that is fine
}

@Test func theKindOfSessionIsNamedForWhereItRuns() {
    #expect(ActiveSessions.kindLabel(entrypoint: "claude-vscode") == "VS Code")
    #expect(ActiveSessions.kindLabel(entrypoint: "cli") == "Terminal")
    #expect(ActiveSessions.kindLabel(entrypoint: "something-new") == nil)
    #expect(ActiveSessions.kindLabel(entrypoint: nil) == nil)
}

@Test func aSessionCarriesItsTitleAndKind() throws {
    let tmp = TempDir()
    let project = tmp.mkdir("projects/-Users-alice-work")
    writeJSONL(project.appendingPathComponent("\(uuid).jsonl"),
               [assistantEntry(5, 5), ["type": "ai-title", "aiTitle": "Prompt-vault skill"]])
    let sessionsDir = tmp.url("sessions")
    writeSessionFile(sessionsDir, pid: 42, extra: ["entrypoint": "claude-vscode"])

    let sessions = try ActiveSessions.activeSessions(
        projectsDir: tmp.url("projects"), processes: [.init(pid: 42, cwd: "/Users/alice/work", stopped: false)],
        sessionsDir: sessionsDir)

    #expect(sessions[0].title == "Prompt-vault skill" && sessions[0].kind == "VS Code")
}
