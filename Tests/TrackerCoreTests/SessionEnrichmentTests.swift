// Tokens, titles, logs, plugin tags and subagents for the sessions the rules
// found. None of it can add or remove a session.

import Foundation
import Testing
@testable import TrackerCore

private typealias Rules = SessionRules

private func entry(_ pid: Int32, session: String?, folder: String = "/w/app", counted: Bool = true,
                   role: Rules.Role = .session, claimsLog: Bool = true) -> Rules.Entry {
    Rules.Entry(tool: "claude_code", pid: pid, start: "Tue Nov 10 18:00:00 2026", parentPid: 1, folder: folder,
                recordFolder: session == nil ? nil : folder, terminal: nil, sessionId: session, entrypoint: nil,
                role: role, counted: counted, state: .idle, paused: false, since: nil, waitingFor: nil,
                children: [], claimsLog: claimsLog, reasons: [])
}

private func scan(_ entries: [Rules.Entry]) -> Rules.Scan { Rules.Scan(entries: entries, staleRecords: []) }

private func assistant(_ input: Int, _ output: Int) -> JSONObject {
    ["type": "assistant", "message": ["usage": ["input_tokens": input, "output_tokens": output]]]
}

private func enrich(_ entries: [Rules.Entry], _ cache: inout EnrichmentCache, projects: URL,
                    withPlugins: Bool = false) -> EnrichmentResult {
    SessionEnrichment.enrich(scan(entries), cache: &cache, withPlugins: withPlugins, projectsDir: projects,
                             claudeDir: projects.deletingLastPathComponent().appendingPathComponent("claude"))
}

@Test func aRecordedSessionGetsItsOwnLogTokensAndTitle() {
    let tmp = TempDir()
    let projects = tmp.url("projects")
    let folder = tmp.mkdir("projects/-w-app")
    writeJSONL(folder.appendingPathComponent("s1.jsonl"),
               [assistant(10, 20), ["type": "ai-title", "aiTitle": "Fix the  bug\nnow"]])
    var cache = EnrichmentCache()
    let result = enrich([entry(100, session: "s1")], &cache, projects: projects)
    let details = result.details[100]
    #expect(details?.tokens == 30)
    #expect(details?.title == "Fix the bug now")
    #expect(details?.log == folder.appendingPathComponent("s1.jsonl").path)
}

@Test func aSessionWithNoLogYetStillHasDetails() {
    let tmp = TempDir()
    tmp.mkdir("projects/-w-app")
    var cache = EnrichmentCache()
    let result = enrich([entry(100, session: "new")], &cache, projects: tmp.url("projects"))
    #expect(result.details[100] == SessionDetails())
}

@Test func laterScansReadOnlyWhatWasAppendedAndEqualAFullRead() throws {
    let tmp = TempDir()
    let log = tmp.mkdir("projects/-w-app").appendingPathComponent("s1.jsonl")
    writeJSONL(log, [assistant(1, 1), assistant(2, 2)])
    var cache = EnrichmentCache()
    let first = enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects"))
    #expect(first.details[100]?.tokens == 6)
    let offset = cache.logs[log.path]?.offset
    #expect(offset != nil && offset! > 0)

    appendJSONL(log, [assistant(10, 10)])
    let second = enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects"))
    #expect(second.details[100]?.tokens == 26)
    #expect(cache.logs[log.path]!.offset > offset!)
    let full = try TokenMath.sumUsageSince(log.path, offset: 0).tokens
    #expect(second.details[100]?.tokens == full)
}

@Test func aHalfWrittenLastLineIsNotCountedUntilItIsFinished() throws {
    let tmp = TempDir()
    let log = tmp.mkdir("projects/-w-app").appendingPathComponent("s1.jsonl")
    writeJSONL(log, [assistant(1, 1)])
    appendText(log, #"{"type":"assistant","message":{"usage":{"input_tokens":5,"#)  // cut off mid-line
    var cache = EnrichmentCache()
    #expect(enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects")).details[100]?.tokens == 2)
    appendText(log, "\"output_tokens\":5}}}\n")
    let after = enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects"))
    #expect(after.details[100]?.tokens == 12)
    #expect(after.details[100]?.tokens == (try TokenMath.sumUsageSince(log.path, offset: 0).tokens))
}

@Test func aLogThatShrankIsReadAgainFromTheStart() {
    let tmp = TempDir()
    let log = tmp.mkdir("projects/-w-app").appendingPathComponent("s1.jsonl")
    writeJSONL(log, [assistant(100, 100), assistant(100, 100)])
    var cache = EnrichmentCache()
    _ = enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects"))
    writeJSONL(log, [assistant(1, 1)])  // replaced by a shorter file
    let result = enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects"))
    #expect(result.details[100]?.tokens == 2)
}

@Test func anUnreadableLogLeavesItsFieldsEmptyAndTheOtherSessionsAlone() throws {
    let tmp = TempDir()
    let folder = tmp.mkdir("projects/-w-app")
    writeJSONL(folder.appendingPathComponent("good.jsonl"), [assistant(3, 4)])
    let bad = folder.appendingPathComponent("bad.jsonl")
    writeJSONL(bad, [assistant(9, 9)])
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: bad.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad.path) }
    var cache = EnrichmentCache()
    let result = enrich([entry(1, session: "bad"), entry(2, session: "good")], &cache,
                        projects: tmp.url("projects"))
    #expect(result.details[1]?.tokens == nil)
    #expect(result.details[2]?.tokens == 7)
    #expect(result.details.keys.sorted() == [1, 2])
}

@Test func processesWithNoRecordTakeTheNewestLogsNoRecordedSessionOwns() {
    let tmp = TempDir()
    let folder = tmp.mkdir("projects/-w-app")
    func log(_ name: String, _ age: Double, tokens: Int) {
        let url = folder.appendingPathComponent(name)
        writeJSONL(url, [assistant(tokens, 0)])
        setModificationTime(url, Date().timeIntervalSince1970 - age)
    }
    log("owned.jsonl", 10, tokens: 1)
    log("new.jsonl", 20, tokens: 2)
    log("newer.jsonl", 5, tokens: 3)
    log("old.jsonl", 900, tokens: 4)
    var cache = EnrichmentCache()
    let result = enrich([entry(10, session: "owned"), entry(30, session: nil), entry(20, session: nil)], &cache,
                        projects: tmp.url("projects"))
    // Two unrecorded processes, in pid order, take the two newest free logs.
    #expect(result.details[20]?.tokens == 3)
    #expect(result.details[30]?.tokens == 2)
    #expect(result.details[10]?.tokens == 1)
}

@Test func theOlderOfTwoProcessesSharingASessionIdTakesNoLog() {
    let tmp = TempDir()
    writeJSONL(tmp.mkdir("projects/-w-app").appendingPathComponent("s1.jsonl"), [assistant(5, 5)])
    var cache = EnrichmentCache()
    let result = enrich([entry(1, session: "s1", claimsLog: false), entry(2, session: "s1")], &cache,
                        projects: tmp.url("projects"))
    #expect(result.details[1]?.tokens == nil)
    #expect(result.details[2]?.tokens == 10)
}

@Test func backgroundAgentsAndUncountedProcessesGetNoDetails() {
    let tmp = TempDir()
    writeJSONL(tmp.mkdir("projects/-w-app").appendingPathComponent("b.jsonl"), [assistant(5, 5)])
    var cache = EnrichmentCache()
    let result = enrich([entry(1, session: "b", counted: false, role: .background)], &cache,
                        projects: tmp.url("projects"))
    #expect(result.details.isEmpty)
}

@Test func theCacheForgetsLogsOfSessionsThatAreGone() {
    let tmp = TempDir()
    writeJSONL(tmp.mkdir("projects/-w-app").appendingPathComponent("s1.jsonl"), [assistant(1, 1)])
    var cache = EnrichmentCache()
    _ = enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects"))
    #expect(cache.logs.count == 1)
    _ = enrich([], &cache, projects: tmp.url("projects"))
    #expect(cache.logs.isEmpty)
}

@Test func pluginRowsAreOnlyBuiltWhenAsked() {
    let tmp = TempDir()
    writeJSONL(tmp.mkdir("projects/-w-app").appendingPathComponent("s1.jsonl"), [assistant(1, 1)])
    var cache = EnrichmentCache()
    #expect(enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects")).pluginRows == nil)
    let asked = enrich([entry(100, session: "s1")], &cache, projects: tmp.url("projects"), withPlugins: true)
    #expect(asked.pluginRows != nil)
    #expect(asked.details[100]?.plugins != nil)
}

// MARK: Subagents

private func subagentFiles(_ tmp: TempDir, session: String = "s1", _ metas: [String: JSONObject]) {
    let dir = tmp.mkdir("projects/-w-app/\(session)/subagents")
    for (id, meta) in metas {
        writeText(dir.appendingPathComponent("agent-\(id).meta.json"), String(decoding: try! JSON.encode(meta), as: UTF8.self))
        writeText(dir.appendingPathComponent("agent-\(id).jsonl"), "{}\n")
    }
}

@Test func onlySubagentsThatHaveNotFinishedAreListedWithTheirTypeAndDepth() {
    let tmp = TempDir()
    subagentFiles(tmp, [
        "a1": ["agentType": "Explore", "description": "Find the\nparser", "finished": false, "spawnDepth": 1],
        "a2": ["agentType": "general-purpose", "finished": true, "spawnDepth": 1],
        "a3": ["agentType": "Explore", "description": "Nested", "spawnDepth": 2, "parentAgentId": "a1"],
    ])
    var cache = EnrichmentCache()
    let running = Subagents.running(projectDir: tmp.url("projects/-w-app"), sessionId: "s1", cache: &cache)
    #expect(running.map(\.id) == ["agent-a1", "agent-a3"])
    #expect(running[0] == Subagent(id: "agent-a1", type: "Explore", description: "Find the parser", depth: 1))
    #expect(running[1].depth == 2)
    #expect(cache.finishedSubagents.count == 1)
}

@Test func aFinishedSubagentIsNotReadAgain() throws {
    let tmp = TempDir()
    subagentFiles(tmp, ["a2": ["agentType": "Explore", "finished": true]])
    var cache = EnrichmentCache()
    _ = Subagents.running(projectDir: tmp.url("projects/-w-app"), sessionId: "s1", cache: &cache)
    // Even if the file now says otherwise, finished does not go back.
    let meta = tmp.url("projects/-w-app/s1/subagents/agent-a2.meta.json")
    writeText(meta, #"{"agentType":"Explore","finished":false}"#)
    #expect(Subagents.running(projectDir: tmp.url("projects/-w-app"), sessionId: "s1", cache: &cache).isEmpty)
}

@Test func noSubagentFolderOrAnUnreadableOneGivesAnEmptyList() throws {
    let tmp = TempDir()
    var cache = EnrichmentCache()
    #expect(Subagents.running(projectDir: tmp.url("projects/-w-app"), sessionId: "s1", cache: &cache).isEmpty)
    subagentFiles(tmp, ["a1": ["agentType": "Explore"]])
    writeText(tmp.url("projects/-w-app/s1/subagents/agent-bad.meta.json"), "{broken")
    let running = Subagents.running(projectDir: tmp.url("projects/-w-app"), sessionId: "s1", cache: &cache)
    #expect(running.map(\.id) == ["agent-a1"])
}

@Test func subagentsAreListedUnderTheirOwnSessionOnly() {
    let tmp = TempDir()
    writeJSONL(tmp.mkdir("projects/-w-app").appendingPathComponent("s1.jsonl"), [assistant(1, 1)])
    subagentFiles(tmp, session: "s1", ["a1": ["agentType": "Explore", "finished": false]])
    subagentFiles(tmp, session: "s2", ["b1": ["agentType": "Explore", "finished": false]])
    var cache = EnrichmentCache()
    let result = enrich([entry(1, session: "s1"), entry(2, session: "s2", claimsLog: true)], &cache,
                        projects: tmp.url("projects"))
    #expect(result.details[1]?.subagents.map(\.id) == ["agent-a1"])
    #expect(result.details[2]?.subagents.map(\.id) == ["agent-b1"])
}

@Test func anOlderDuplicateSessionListsNoSubagents() {
    let tmp = TempDir()
    subagentFiles(tmp, ["a1": ["agentType": "Explore", "finished": false]])
    var cache = EnrichmentCache()
    let result = enrich([entry(1, session: "s1", claimsLog: false), entry(2, session: "s1")], &cache,
                        projects: tmp.url("projects"))
    #expect(result.details[1]?.subagents.isEmpty == true)
    #expect(result.details[2]?.subagents.count == 1)
}
