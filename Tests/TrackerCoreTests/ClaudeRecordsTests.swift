// Claude Code's own record of a running process, ~/.claude/sessions/<pid>.json.
// The first fixture is a record captured on the owner's Mac on 2026-11-10
// (Claude Code 2.1.322, VS Code); names are shortened.

import Foundation
import Testing
@testable import TrackerCore

private let idleRecord = """
{"pid":18426,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"/Users/alice/Desktop/app",\
"startedAt":1794336401277,"procStart":"Tue Nov 10 18:46:36 2026","version":"2.1.322","peerProtocol":1,\
"kind":"interactive","entrypoint":"claude-vscode","pidDomain":"darwin","name":"app-e9","nameSource":"derived",\
"status":"idle","updatedAt":1794336404117,"statusUpdatedAt":1794336404117}
"""

private func decode(_ text: String, file: String = "18426.json") -> ClaudeRecords.Record? {
    ClaudeRecords.decode(Data(text.utf8), fileName: file)
}

@Test func capturedIdleRecordDecodes() {
    let record = decode(idleRecord)
    #expect(record?.pid == 18426)
    #expect(record?.sessionId == "11111111-2222-3333-4444-555555555555")
    #expect(record?.cwd == "/Users/alice/Desktop/app")
    #expect(record?.procStart == "Tue Nov 10 18:46:36 2026")
    #expect(record?.kind == .interactive)
    #expect(record?.entrypoint == "claude-vscode")
    #expect(record?.status == .idle)
    #expect(record?.statusUpdatedAt == 1794336404.117)
    #expect(record?.waitingFor == nil)
}

@Test func busyAndWaitingStatusesDecode() {
    let busy = idleRecord.replacingOccurrences(of: "\"status\":\"idle\"", with: "\"status\":\"busy\"")
    #expect(decode(busy)?.status == .busy)
    let waiting = idleRecord.replacingOccurrences(
        of: "\"status\":\"idle\"", with: "\"status\":\"waiting\",\"waitingFor\":\"input needed\"")
    #expect(decode(waiting)?.status == .waiting)
    #expect(decode(waiting)?.waitingFor == "input needed")
    let shell = idleRecord.replacingOccurrences(of: "\"status\":\"idle\"", with: "\"status\":\"shell\"")
    #expect(decode(shell)?.status == .shell)
}

@Test func everyKnownKindDecodes() {
    func kind(_ raw: String) -> ClaudeRecords.RecordKind? {
        decode(idleRecord.replacingOccurrences(of: "\"kind\":\"interactive\"", with: "\"kind\":\"\(raw)\""))?.kind
    }
    #expect(kind("interactive") == .interactive)
    #expect(kind("bg") == .background)
    #expect(kind("daemon") == .daemon)
    #expect(kind("daemon-worker") == .daemonWorker)
}

@Test func anUnexpectedKindOrStatusIsKeptAsItsRawText() {
    let kind = idleRecord.replacingOccurrences(of: "\"kind\":\"interactive\"", with: "\"kind\":\"remote\"")
    #expect(decode(kind)?.kind == .unrecognized("remote"))
    let status = idleRecord.replacingOccurrences(of: "\"status\":\"idle\"", with: "\"status\":\"thinking\"")
    #expect(decode(status)?.status == .unrecognized("thinking"))
}

@Test func missingKindAndStatusAreMissingNotGuessed() {
    let bare = #"{"pid":18426,"sessionId":"abc-1","cwd":"/w"}"#
    let record = decode(bare)
    #expect(record?.kind == .missing)
    #expect(record?.status == .missing)
    #expect(record?.procStart == nil)
    #expect(record?.statusUpdatedAt == nil)
}

@Test func statusTimeFallsBackToUpdatedAt() {
    let text = #"{"pid":18426,"sessionId":"abc-1","cwd":"/w","updatedAt":2000}"#
    #expect(decode(text)?.statusUpdatedAt == 2)
}

@Test func aRecordForAnotherPidOrWithABadIdOrNoFolderIsRejected() {
    #expect(decode(idleRecord, file: "999.json") == nil)
    #expect(decode(#"{"pid":1,"sessionId":"../../etc","cwd":"/w"}"#, file: "1.json") == nil)
    #expect(decode(#"{"pid":1,"sessionId":"","cwd":"/w"}"#, file: "1.json") == nil)
    #expect(decode(#"{"pid":1,"sessionId":"abc","cwd":""}"#, file: "1.json") == nil)
    #expect(decode(#"{"pid":1,"sessionId":"abc"}"#, file: "1.json") == nil)
}

@Test func truncatedOrInvalidJsonGivesNoRecord() {
    #expect(decode(String(idleRecord.prefix(120))) == nil)
    #expect(decode("") == nil)
    #expect(decode("[1,2,3]") == nil)
}

@Test func waitingTextIsOneShortLine() {
    let text = idleRecord.replacingOccurrences(
        of: "\"status\":\"idle\"",
        with: "\"status\":\"waiting\",\"waitingFor\":\"line one\\nline two  \(String(repeating: "x", count: 80))\"")
    let waiting = decode(text)?.waitingFor
    #expect(waiting?.hasPrefix("line one line two") == true)
    #expect((waiting?.count ?? 0) <= 60)
}

@Test func readTakesOnlyPidDotJsonFilesAndNeverTheKeyFiles() throws {
    let tmp = TempDir()
    let dir = tmp.mkdir("sessions")
    try idleRecord.write(to: dir.appendingPathComponent("18426.json"), atomically: true, encoding: .utf8)
    // Same JSON under the names Claude Code uses for its secret files and
    // other leftovers: none may be read.
    let hashName = "18426.a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90.key"
    try idleRecord.write(to: dir.appendingPathComponent(hashName), atomically: true, encoding: .utf8)
    try idleRecord.replacingOccurrences(of: "18426", with: "77")
        .write(to: dir.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
    try "{broken".write(to: dir.appendingPathComponent("55.json"), atomically: true, encoding: .utf8)

    let records = ClaudeRecords.read(dir: dir)
    #expect(Set(records.keys) == [18426])
    #expect(records[18426]?.status == .idle)
}

@Test func readOfAMissingFolderIsEmpty() {
    let tmp = TempDir()
    #expect(ClaudeRecords.read(dir: tmp.url("nowhere")).isEmpty)
}
