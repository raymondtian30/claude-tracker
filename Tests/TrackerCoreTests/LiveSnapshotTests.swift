// What the Live tab shows: the registry's snapshot cut for the current view.

import Foundation
import Testing
@testable import TrackerCore

private let start = "Tue Nov 10 18:00:00 2026"

private func proc(_ pid: Int32, _ program: String, tty: String? = nil, args: String? = nil,
                  folder: String = "/w/app") -> ProcInfo {
    ProcInfo(pid: pid, ppid: 1, tty: tty, state: "S", start: start, program: program, args: args ?? program,
             folder: folder)
}

private func record(_ pid: Int32, _ session: String, kind: ClaudeRecords.RecordKind = .interactive,
                    status: ClaudeRecords.RecordStatus = .busy) -> ClaudeRecords.Record {
    ClaudeRecords.Record(pid: pid, sessionId: session, cwd: "/w/app", procStart: start, startedAt: nil, kind: kind,
                         entrypoint: "claude-vscode", status: status, statusUpdatedAt: 1_000, waitingFor: nil)
}

/// Claude Code (2), Codex in a terminal, the opencode server, a Codex server.
private func snapshot() -> SessionRegistry.Snapshot {
    var background = record(30, "bg", kind: .background)
    background.status = .idle
    var made = SessionRegistry.reduce(
        previous: nil,
        processes: [proc(10, "claude"), proc(20, "claude"), proc(30, "claude"),
                    proc(40, "codex", tty: "ttys001"),
                    proc(50, "opencode", args: "/o/opencode serve --service", folder: "/Users/alice"),
                    proc(60, "codex", args: "/c/codex app-server", folder: "/")],
        records: [10: record(10, "a"), 20: record(20, "b", status: .idle), 30: background], now: 0)
    made.details[10] = SessionDetails(tokens: 1234, title: "Fix the bug", log: "/l/a.jsonl",
                                      subagents: [Subagent(id: "agent-1", type: "Explore")])
    return made
}

@Test func nothingIsScannedBeforeTheFirstScan() {
    let live = LiveSnapshot(SessionRegistry.Snapshot.initial, tools: ["claude_code"])
    #expect(!live.scanned)
    #expect(live.sessions.isEmpty)
}

@Test func aViewShowsOnlyItsToolsAndNeverNeedsANewScan() {
    let all = LiveSnapshot(snapshot(), tools: Tools.tools.map(\.key))
    #expect(all.sessions.map(\.tool) == ["claude_code", "claude_code", "codex"])
    let codex = LiveSnapshot(snapshot(), tools: ["codex"])
    #expect(codex.scanned)  // switching view is not a missing scan
    #expect(codex.sessions.map(\.pid) == [40])
    let opencode = LiveSnapshot(snapshot(), tools: ["opencode"])
    #expect(opencode.scanned)
    #expect(opencode.sessions.isEmpty)
}

@Test func theCountTheRowsAndTheBulkTargetsComeFromOneArray() {
    let live = LiveSnapshot(snapshot(), tools: Tools.tools.map(\.key))
    #expect(live.sessions.count == 3)
    #expect(live.controllablePids == [10, 20])  // Codex has a pid but is not controllable
    #expect(Set(live.controllablePids).isSubset(of: Set(live.sessions.compactMap(\.pid))))
    #expect(live.starts == [10: start, 20: start])
}

@Test func aSessionCarriesWhatTheRegistryKnew() {
    let live = LiveSnapshot(snapshot(), tools: ["claude_code"])
    let first = live.sessions[0]
    #expect(first.tool == "claude_code")
    #expect(first.state == .active)
    #expect(first.status == "busy")
    #expect(first.title == "Fix the bug")
    #expect(first.tokens == 1234)
    #expect(first.log == "/l/a.jsonl")
    #expect(first.kind == "VS Code")
    #expect(first.since == 1_000)
    #expect(first.subagents.map(\.id) == ["agent-1"])
    #expect(live.sessions[1].status == "idle")
}

@Test func backgroundAgentsAreListedAndNotCounted() {
    let live = LiveSnapshot(snapshot(), tools: ["claude_code"])
    #expect(live.sessions.map(\.pid) == [10, 20])
    #expect(live.background.map(\.pid) == [30])
    #expect(!live.sessions.contains { $0.pid == 30 })
}

@Test func theNotCountedTallyIsPerViewAndLeavesOutBackgroundAgents() {
    #expect(LiveSnapshot(snapshot(), tools: Tools.tools.map(\.key)).notCounted == 2)  // opencode and codex servers
    #expect(LiveSnapshot(snapshot(), tools: ["claude_code"]).notCounted == 0)
    #expect(LiveSnapshot(snapshot(), tools: ["opencode"]).notCounted == 1)
}

@Test func theHomeFolderShowsAsATilde() {
    var made = SessionRegistry.reduce(previous: nil, processes: [proc(40, "codex", tty: "ttys001", folder: "/Users/alice")],
                                      records: [:], now: 0)
    made.details = [:]
    let live = LiveSnapshot(made, tools: ["codex"], home: "/Users/alice")
    #expect(live.sessions[0].label == "~")
}

@Test func theErrorAndPluginsPassThroughAndSnapshotsCompareByWhatIsDrawn() {
    var made = snapshot()
    made.error = "Couldn't list sessions: ps exited with 1"
    made.pluginRows = [Plugins.Row(label: "caveman", sessions: 1, latest: nil, today: [:])]
    let live = LiveSnapshot(made, tools: ["claude_code"])
    #expect(live.error == made.error)
    #expect(live.plugins?.count == 1)
    #expect(LiveSnapshot(snapshot(), tools: ["claude_code"]) == LiveSnapshot(snapshot(), tools: ["claude_code"]))
    #expect(live != LiveSnapshot(snapshot(), tools: ["claude_code"]))
}
