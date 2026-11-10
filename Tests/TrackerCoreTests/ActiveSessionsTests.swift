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
