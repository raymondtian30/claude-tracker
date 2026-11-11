// The counting rules (R1 to R9, R13, R14): which processes are sessions. The
// shapes come from what ps and Claude Code's records showed on the owner's
// Mac on 2026-11-10: Codex and opencode in terminal tabs, the opencode
// server, four Codex app servers inside VS Code, Claude Code in VS Code.

import Foundation
import Testing
@testable import TrackerCore

private typealias Rules = SessionRules

private let t0 = "Tue Nov 10 18:00:00 2026"

private func proc(_ pid: Int32, _ ppid: Int32 = 1, _ program: String, tty: String? = nil,
                  start: String = t0, args: String? = nil, folder: String? = nil,
                  state: String = "S") -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, tty: tty, state: state, start: start, program: program,
             args: args ?? program, folder: folder)
}

private func claude(_ pid: Int32, _ ppid: Int32 = 1, folder: String = "/w/app", start: String = t0,
                    state: String = "S") -> ProcInfo {
    proc(pid, ppid, "claude", start: start, args: "/ext/native-binary/claude --output-format stream-json",
         folder: folder, state: state)
}

private func record(_ pid: Int32, session: String = "s1", kind: ClaudeRecords.RecordKind = .interactive,
                    status: ClaudeRecords.RecordStatus = .idle, procStart: String? = t0,
                    cwd: String = "/w/app", startedAt: Double? = nil, statusAt: Double? = nil,
                    waitingFor: String? = nil) -> ClaudeRecords.Record {
    ClaudeRecords.Record(pid: pid, sessionId: session, cwd: cwd, procStart: procStart, startedAt: startedAt,
                         kind: kind, entrypoint: "claude-vscode", status: status, statusUpdatedAt: statusAt,
                         waitingFor: waitingFor)
}

private func scan(_ processes: [ProcInfo], _ records: [ClaudeRecords.Record] = []) -> Rules.Scan {
    Rules.scan(processes: processes, records: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }),
               now: 1_794_336_000)
}

private func counted(_ scan: Rules.Scan) -> [Rules.Entry] { scan.entries.filter(\.counted) }

// MARK: C1, C2, C3: Claude Code

@Test func oneSessionWithSubprocessesIsOneSession() {
    // claude -> zsh -> node, plus a claude child with no record of its own.
    let result = scan([
        proc(90, 1, "zsh", tty: "ttys001"),
        claude(100, 90), proc(101, 100, "zsh"), proc(102, 101, "node", args: "node /x/server.js"),
        claude(103, 102),
    ], [record(100)])
    #expect(counted(result).count == 1)
    #expect(counted(result)[0].pid == 100)
    #expect(counted(result)[0].children.map(\.pid) == [103])
}

@Test func aChildWithTheSameSessionIdJoinsAndOneWithAnotherIdIsItsOwnSession() {
    let processes = [claude(100), proc(101, 100, "zsh"), claude(103, 101), claude(104, 101)]
    let result = scan(processes, [record(100, session: "s1"), record(103, session: "s1"),
                                  record(104, session: "s2")])
    #expect(counted(result).map(\.pid) == [100, 104])
    #expect(counted(result)[0].children.map(\.pid) == [103])
}

@Test func aNestedBackgroundAgentUnderASessionIsNotCountedAndNotMerged() {
    // `claude -p` style: its own record, kind bg.
    let result = scan([claude(100), claude(104, 100)],
                      [record(100, session: "s1"), record(104, session: "s2", kind: .background)])
    #expect(counted(result).map(\.pid) == [100])
    #expect(result.entries.first { $0.pid == 104 }?.role == .background)
}

@Test func twoSessionsInTwoTerminalsAreTwo() {
    let result = scan([proc(90, 1, "zsh", tty: "ttys001"), proc(91, 1, "zsh", tty: "ttys002"),
                       claude(100, 90), claude(200, 91, start: "Tue Nov 10 18:05:00 2026")],
                      [record(100, session: "a"), record(200, session: "b", procStart: "Tue Nov 10 18:05:00 2026")])
    #expect(counted(result).map(\.pid) == [100, 200])
}

@Test func severalSessionsInOneFolderAreOneEachAndAProcessWithNoRecordIsStillCounted() {
    let processes = [claude(100), claude(200), claude(300), claude(400)]
    let result = scan(processes, [record(100, session: "a"), record(200, session: "b"), record(300, session: "c")])
    #expect(counted(result).count == 4)
    let none = result.entries.first { $0.pid == 400 }
    #expect(none?.state == .unknown)
    #expect(none?.reasons.contains(.noRecord) == true)
    #expect(none?.sessionId == nil)
}

@Test func aRecordWithNoLogYetStillCounts() {
    // The scan never looks at logs: a new idle chat has a record and no log.
    let result = scan([claude(100)], [record(100)])
    #expect(counted(result).count == 1)
}

// MARK: C4, C5: other tools

@Test func codexInATerminalCountsAndItsDaemonChildrenJoinIt() {
    let result = scan([
        proc(17216, 1, "zsh", tty: "ttys011"),
        proc(22367, 17216, "codex", tty: "ttys011", args: "codex", folder: "/w/app"),
        proc(22377, 22367, "codex", tty: nil, args: "/c/codex app-server --listen --managed-daemon", folder: "/w/app"),
        proc(22393, 22367, "codex", tty: nil, args: "/c/codex app-server daemon pid-update-loop", folder: "/w/app"),
    ])
    #expect(counted(result).map(\.pid) == [22367])
    #expect(counted(result)[0].children.map(\.pid) == [22377, 22393])
    #expect(counted(result)[0].reasons.contains(.hasTerminal))
}

@Test func theFourExtensionAppServersAreNotCounted() {
    let flags = "/ext/codex -c features.code_mode_host=true app-server --analytics-default-enabled"
    let result = scan((0..<4).map { proc(Int32(17450 + $0), Int32(16970 + $0), "codex", args: flags, folder: "/") })
    #expect(counted(result).isEmpty)
    #expect(result.entries.count == 4)
    #expect(result.entries.allSatisfy { $0.role == .unclassified && $0.reasons.contains(.noTerminal) })
}

@Test func twoTerminalCodexSessionsInOneFolderAreTwo() {
    let result = scan([proc(10, 1, "zsh", tty: "ttys001"), proc(11, 1, "zsh", tty: "ttys002"),
                       proc(20, 10, "codex", tty: "ttys001", folder: "/w/app"),
                       proc(21, 11, "codex", tty: "ttys002", folder: "/w/app")])
    #expect(counted(result).map(\.pid) == [20, 21])
}

@Test func opencodeTuiCountsAndItsServerDoesNot() {
    let result = scan([
        proc(22311, 22237, "opencode", tty: "ttys017", args: "opencode", folder: "/w/app"),
        proc(15075, 1, "opencode", tty: nil, args: "/opt/homebrew/Cellar/opencode/2.2.5/bin/opencode serve --service",
             folder: "/Users/alice", state: "Ss"),
    ])
    #expect(counted(result).map(\.pid) == [22311])
    let server = result.entries.first { $0.pid == 15075 }
    #expect(server?.counted == false)
    #expect(server?.reasons.contains(.noTerminal) == true)
}

@Test func aServerStartedFromATerminalIsStillAServer() {
    let result = scan([proc(30, 1, "opencode", tty: "ttys003", args: "/o/opencode serve --port 4096", folder: "/w")])
    #expect(counted(result).isEmpty)
    #expect(result.entries[0].reasons.contains(.server))
}

@Test func geminiRunsAsANodeScriptAndCountsWithATerminal() {
    let result = scan([proc(40, 1, "node", tty: "ttys004", args: "node /usr/local/bin/gemini", folder: "/w"),
                       proc(41, 1, "node", tty: "ttys004", args: "node /usr/local/bin/other", folder: "/w")])
    #expect(counted(result).map(\.pid) == [40])
    #expect(counted(result)[0].tool == "gemini_cli")
}

@Test func toolsStayApartInOneFolderAndAreOrderedByTool() {
    let result = scan([
        proc(50, 1, "opencode", tty: "ttys005", folder: "/w/app"),
        proc(51, 1, "codex", tty: "ttys006", folder: "/w/app"),
        claude(52, folder: "/w/app"),
        proc(53, 1, "node", tty: "ttys007", args: "node /x/gemini", folder: "/w/app"),
    ], [record(52)])
    #expect(counted(result).map(\.tool) == ["claude_code", "codex", "opencode", "gemini_cli"])
}

@Test func aProcessUnderAnotherToolsSessionIsItsOwnUncountedEntry() {
    let result = scan([
        claude(100), proc(101, 100, "zsh"),
        proc(102, 101, "codex", tty: "ttys009", folder: "/w/app"),
    ], [record(100)])
    #expect(counted(result).map(\.pid) == [100])
    let child = result.entries.first { $0.pid == 102 }
    #expect(child?.tool == "codex")
    #expect(child?.role == .crossToolChild)
    #expect(child?.reasons.contains(.otherToolChild(of: 100)) == true)
}

// MARK: C6: roles

@Test func everyBackgroundKindIsListedAndNotCounted() {
    let result = scan([claude(1), claude(2), claude(3)],
                      [record(1, session: "a", kind: .background), record(2, session: "b", kind: .daemon),
                       record(3, session: "c", kind: .daemonWorker)])
    #expect(counted(result).isEmpty)
    #expect(result.entries.map(\.role) == [.background, .background, .background])
}

@Test func anUnknownOrMissingKindCountsAsUnknownAndIsFlagged() {
    let result = scan([claude(1), claude(2)],
                      [record(1, session: "a", kind: .unrecognized("remote")), record(2, session: "b", kind: .missing)])
    #expect(counted(result).map(\.state) == [.unknown, .unknown])
    #expect(result.entries[0].reasons.contains(.recordKindUnrecognized("remote")))
    #expect(result.entries[1].reasons.contains(.recordKindMissing))
}

// MARK: C8, C9: stale records and process id reuse

@Test func aRecordWithNoProcessIsStaleAndNeverCounted() {
    let result = scan([], [record(77)])
    #expect(result.entries.isEmpty)
    #expect(result.staleRecords == [Rules.StaleRecord(pid: 77, reason: .noProcess)])
}

@Test func aRecordWhosePidIsNowAnotherProgramIsStale() {
    let result = scan([proc(77, 1, "zsh", tty: "ttys001")], [record(77)])
    #expect(result.entries.isEmpty)
    #expect(result.staleRecords == [Rules.StaleRecord(pid: 77, reason: .differentProgram)])
}

@Test func aRecordFromAnEarlierProcessWithTheSamePidIsStaleAndTheProcessHasNoRecord() {
    let reused = "Tue Nov 10 19:30:00 2026"
    let result = scan([claude(42, start: reused)], [record(42, procStart: t0)])
    #expect(result.staleRecords == [Rules.StaleRecord(pid: 42, reason: .startTimeDiffers)])
    let entry = result.entries[0]
    #expect(entry.sessionId == nil)
    #expect(entry.reasons.contains(.noRecord))
    #expect(entry.state == .unknown)
}

@Test func aMatchingStartTimeIsAcceptedEvenWithOnlyPaddingDifferences() {
    let result = scan([claude(42, start: "Mon Nov 9 07:19:59 2026")],
                      [record(42, status: .busy, procStart: "Mon Nov  9 07:19:59 2026")])
    #expect(result.staleRecords.isEmpty)
    #expect(counted(result)[0].state == .active)
}

@Test func aRecordWithoutProcStartIsAcceptedButUnverifiedAndUnknown() {
    let result = scan([claude(42)], [record(42, status: .busy, procStart: nil)])
    #expect(counted(result)[0].state == .unknown)
    #expect(counted(result)[0].reasons.contains(.unverifiedRecord))
    #expect(counted(result)[0].sessionId == "s1")
}

// MARK: States

@Test func claudeStatusMapsToTheStates() {
    func state(_ status: ClaudeRecords.RecordStatus) -> Rules.State {
        counted(scan([claude(1)], [record(1, status: status)]))[0].state
    }
    #expect(state(.busy) == .active)
    #expect(state(.waiting) == .waiting)
    #expect(state(.idle) == .idle)
    #expect(state(.shell) == .unknown)
    #expect(state(.unrecognized("thinking")) == .unknown)
    #expect(state(.missing) == .unknown)
}

@Test func theStatusTimeAndWhatItWaitsForComeFromTheRecord() {
    let entry = counted(scan([claude(1)], [record(1, status: .waiting, statusAt: 1_794_336_914,
                                                  waitingFor: "input needed")]))[0]
    #expect(entry.since == 1_794_336_914)
    #expect(entry.waitingFor == "input needed")
}

@Test func aPausedProcessIsFlaggedWhateverItsRecordSays() {
    let entry = counted(scan([claude(1, state: "T")], [record(1, status: .busy)]))[0]
    #expect(entry.paused)
    #expect(entry.state == .active)
}

@Test func nonClaudeToolsAreAlwaysUnknown() {
    let entry = counted(scan([proc(20, 1, "codex", tty: "ttys001", folder: "/w")]))[0]
    #expect(entry.state == .unknown)
    #expect(entry.since == nil)
}

// MARK: Two live processes with one session id

@Test func twoLiveProcessesWithOneSessionIdAreTwoSessionsAndOnlyTheNewestClaimsTheLog() {
    let later = "Tue Nov 10 18:30:00 2026"
    let result = scan([claude(100), claude(200, start: later)],
                      [record(100, session: "same", startedAt: 1000),
                       record(200, session: "same", procStart: later, startedAt: 2000)])
    #expect(counted(result).count == 2)
    let older = result.entries.first { $0.pid == 100 }
    let newer = result.entries.first { $0.pid == 200 }
    #expect(older?.claimsLog == false)
    #expect(older?.reasons.contains(.duplicateSessionId(withPid: 200)) == true)
    #expect(newer?.claimsLog == true)
}

// MARK: R13, R14

@Test func rowsSortByToolThenFolderThenStartTime() {
    let result = scan([
        claude(3, folder: "/b", start: "Tue Nov 10 18:00:00 2026"),
        claude(2, folder: "/a", start: "Tue Nov 10 18:10:00 2026"),
        claude(1, folder: "/a", start: "Tue Nov 10 18:05:00 2026"),
    ], [record(1, session: "x", procStart: "Tue Nov 10 18:05:00 2026"),
        record(2, session: "y", procStart: "Tue Nov 10 18:10:00 2026"), record(3, session: "z")])
    #expect(result.entries.map(\.pid) == [1, 2, 3])
}

@Test func theSameInputsGiveEqualScansInAnyProcessOrder() {
    let processes = [
        proc(90, 1, "zsh", tty: "ttys001"), claude(100, 90), proc(101, 100, "zsh"), claude(103, 101),
        proc(22367, 17216, "codex", tty: "ttys011", folder: "/w"),
        proc(22377, 22367, "codex", args: "/c/codex app-server", folder: "/w"),
        proc(15075, 1, "opencode", args: "/o/opencode serve --service", folder: "/h"),
    ]
    let records = [record(100), record(103, session: "s2")]
    let first = scan(processes, records)
    #expect(scan(processes.reversed(), records) == first)
    #expect(scan(processes.shuffled(), records.reversed()) == first)
    #expect(scan(processes, records) == first)
}

@Test func startTimeParsesFromThePsTextAsUtc() {
    #expect(ProcessTable.startTime("Tue Nov 10 18:46:36 2026") == 1_794_336_396)
    #expect(ProcessTable.startTime("Mon Nov  9 07:19:59 2026") == ProcessTable.startTime("Mon Nov 9 07:19:59 2026"))
    #expect(ProcessTable.startTime("nonsense") == nil)
}

@Test func aRecordWhoseStartTimeIsInAFormatWeDontKnowIsUnverifiedNotStale() {
    // procStart in some other format must not make a background agent look like a chat.
    let result = scan([claude(1), claude(2)],
                      [record(1, session: "a", procStart: "2026-11-10T18:00:00Z"),
                       record(2, session: "b", kind: .background, procStart: "2026-11-10T18:00:00Z")])
    #expect(result.staleRecords.isEmpty)
    #expect(counted(result).map(\.pid) == [1])
    #expect(counted(result)[0].reasons.contains(.unverifiedRecord))
    #expect(result.entries.first { $0.pid == 2 }?.role == .background)
}

@Test func aToolProcessWhoseCommandLineCouldNotBeReadIsNotCounted() {
    // Without it a server in a terminal would look like a chat.
    let unread = ProcInfo(pid: 9, ppid: 1, tty: "ttys001", state: "S", start: t0, program: "opencode",
                          args: nil, folder: "/w")
    let result = scan([unread])
    #expect(counted(result).isEmpty)
    #expect(result.entries[0].reasons == [.commandUnreadable])
}
