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

@Test func projectDirForCwdEscapesSpacesAndDots() {
    let tmp = TempDir()
    let result = ActiveSessions.projectDirForCwd("/Users/me/FPS Game 10.23", projectsDir: tmp.root)
    #expect(result == tmp.root.appendingPathComponent("-Users-me-FPS-Game-10-23"))
}

// MARK: - Processes (for Stop and Quit)

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

@Test func kindLabelNamesWhereASessionRuns() {
    #expect(ActiveSessions.kindLabel(entrypoint: "claude-vscode") == "VS Code")
    #expect(ActiveSessions.kindLabel(entrypoint: "cli") == "Terminal")
    #expect(ActiveSessions.kindLabel(entrypoint: nil) == nil)
}
