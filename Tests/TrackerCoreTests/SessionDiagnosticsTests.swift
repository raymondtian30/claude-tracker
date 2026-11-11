// The diagnostics report: why each process was counted or not. It is pasted
// into bug reports, so it must not carry command lines, prompts, chat titles
// or paths outside the home folder shorthand.

import Foundation
import Testing
@testable import TrackerCore

private let t0 = "Tue Nov 10 18:00:00 2026"
private let now = 1_794_340_000.0  // 2026-11-10 19:46:40 UTC

private func proc(_ pid: Int32, _ ppid: Int32, _ program: String, tty: String? = nil, args: String? = nil,
                  folder: String? = nil) -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, tty: tty, state: "S", start: t0, program: program, args: args ?? program,
             folder: folder)
}

private func record(_ pid: Int32, _ session: String, kind: ClaudeRecords.RecordKind = .interactive,
                    status: ClaudeRecords.RecordStatus = .idle) -> ClaudeRecords.Record {
    ClaudeRecords.Record(pid: pid, sessionId: session, cwd: "/Users/alice/app", procStart: t0, startedAt: nil,
                         kind: kind, entrypoint: "claude-vscode", status: status, statusUpdatedAt: nil,
                         waitingFor: nil)
}

private func report(_ processes: [ProcInfo], _ records: [ClaudeRecords.Record] = [],
                    previous: SessionRegistry.Snapshot? = nil) -> String {
    let table = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
    return SessionDiagnostics.report(processes: processes, records: table, previous: previous, now: now,
                                     timings: [("read processes", 240), ("rules", 1)], home: "/Users/alice",
                                     version: "3.7.0")
}

@Test func theReportMatchesItsGoldenText() {
    let text = report([
        proc(90, 1, "zsh", tty: "ttys001"),
        proc(100, 90, "claude", args: "/Users/alice/.vscode/claude --output-format stream-json --max-thinking-tokens=31999",
             folder: "/Users/alice/app"),
        proc(101, 100, "claude", folder: "/Users/alice/app"),
        proc(200, 1, "opencode", args: "/opt/homebrew/bin/opencode serve --service", folder: "/Users/alice"),
        proc(300, 1, "claude", folder: "/Users/alice/bg"),
    ], [record(100, "s1"), record(300, "s2", kind: .background)])

    #expect(text == """
    Claude Tracker session diagnostics
    Format 1 · Claude Tracker 3.7.0 · 2026-11-10 19:46:40 UTC
    Scan: 5 processes, 4 of them tool processes · read processes 240 ms · rules 1 ms

    Counted sessions (1)
    - Claude Code, pid 100, started Tue Nov 10 18:00:00 2026 UTC
      command: claude --output-format --max-thinking-tokens
      in path ~/app · terminal: none · state: idle
      why: interactive record
      helpers: pid 101

    Background agents (1)
    - Claude Code, pid 300, started Tue Nov 10 18:00:00 2026 UTC
      in path ~/bg · terminal: none · state: idle
      why: background agent (bg)

    Not counted (1)
    - opencode, pid 200, started Tue Nov 10 18:00:00 2026 UTC
      command: opencode serve --service
      in path ~ · terminal: none
      why: no terminal, server command

    Records ignored (0)

    Ended since the last scan (0)

    """)
}

@Test func noCommandLineArgumentsPromptsOrFullPathsAreEverPrinted() {
    let text = report([
        proc(40, 1, "codex", tty: "ttys001",
             args: "/Users/alice/.codex/bin/codex -c api_key=sk-secret-123 --model gpt-5 fix the secret bug --token=abc123",
             folder: "/Users/alice/private/project"),
    ])

    #expect(text.contains("command: codex -c --model --token"))
    for leak in ["sk-secret", "abc123", "fix the secret bug", "gpt-5", "/Users/alice", ".codex/bin"] {
        #expect(!text.contains(leak), "leaked \(leak)")
    }
    #expect(text.contains("in path ~/private/project"))
}

@Test func titlesAndSubagentTextAreNotInTheReport() {
    // The report is built from the scan alone; titles and descriptions live in the enrichment only.
    let text = report([proc(100, 1, "claude", folder: "/Users/alice/app")], [record(100, "s1")])
    #expect(!text.contains("title"))
    #expect(!text.contains("description"))
}

@Test func everyDecisionHasItsReason() {
    let text = report([
        proc(1, 0, "claude", folder: "/w"), proc(2, 0, "claude", folder: "/w"), proc(3, 0, "claude", folder: "/w"),
        proc(4, 0, "claude", folder: "/w"),
        proc(5, 3, "codex", tty: "ttys001", folder: "/w"),
    ], [record(1, "a", kind: .unrecognized("remote")), record(2, "b", kind: .missing),
        record(4, "dup"), record(3, "dup")])

    #expect(text.contains("record kind \"remote\" not recognized, counted as Unknown"))
    #expect(text.contains("record has no kind, counted as Unknown"))
    #expect(text.contains("started by the session with pid 3 (another tool)"))
    #expect(text.contains("same session id as pid"))
}

@Test func staleRecordsAndEndedSessionsAreListed() {
    let previous = SessionRegistry.reduce(previous: nil, processes: [proc(100, 1, "claude", folder: "/w")],
                                          records: [100: record(100, "s1")], now: 0)
    let text = report([proc(77, 1, "zsh", tty: "ttys001")], [record(77, "x")], previous: previous)

    #expect(text.contains("Records ignored (1)"))
    #expect(text.contains("- pid 77: the process is now another program"))
    #expect(text.contains("Ended since the last scan (1)"))
    #expect(text.contains("- Claude Code, pid 100, started Tue Nov 10 18:00:00 2026 UTC"))
}

@Test func theCommandLineKeepsOnlyKnownSubcommandWordsAndFlagNames() {
    func command(_ program: String, _ args: String) -> String {
        SessionDiagnostics.command(program: program, args: args)
    }
    #expect(command("codex", "codex") == "codex")
    #expect(command("codex", "/c/codex app-server --listen  --managed-daemon") == "codex app-server --listen --managed-daemon")
    #expect(command("codex", "/c/codex app-server daemon pid-update-loop") == "codex app-server daemon pid-update-loop")
    #expect(command("opencode", "/o/opencode serve --port 4096") == "opencode serve --port")
    #expect(command("node", "node /usr/local/bin/gemini --yolo") == "node gemini --yolo")
    #expect(command("claude", "") == "claude")
}
