// Ported from tests/test_codex_source.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private let TS = "2026-07-29T12:00:00.000Z"

private func meta(cwd: String = "/x/proj") -> JSONObject {
    ["timestamp": TS, "type": "session_meta", "payload": ["id": "s1", "cwd": cwd]]
}

private func turn(model: String = "gpt-5.6-luna", cwd: String = "/x/proj") -> JSONObject {
    ["timestamp": TS, "type": "turn_context", "payload": ["cwd": cwd, "model": model]]
}

private func usage(inputTokens: Int = 0, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0) -> JSONObject {
    [
        "input_tokens": inputTokens,
        "cached_input_tokens": cached,
        "cache_write_input_tokens": cacheWrite,
        "output_tokens": output,
        "total_tokens": inputTokens + output,
    ]
}

private func record(_ responseId: String, inputTokens: Int = 0, cached: Int = 0, output: Int = 0) -> JSONObject {
    ["timestamp": TS, "type": "token_usage_record",
     "payload": ["response_id": responseId, "usage": usage(inputTokens: inputTokens, cached: cached, output: output)]]
}

private func runningTotal(inputTokens: Int = 0) -> JSONObject {
    ["timestamp": TS, "type": "event_msg",
     "payload": ["type": "token_count", "info": ["total_token_usage": usage(inputTokens: inputTokens)]]]
}

@discardableResult
private func write(_ url: URL, _ entries: [JSONObject], partialTail: String? = nil) -> URL {
    writeText(url, entries.map(jsonLine).joined() + (partialTail ?? ""))
    return url
}

private func dayModels(_ daily: JSONObject) -> JSONObject {
    dig(daily, "2026-07-29", "models") as? JSONObject ?? [:]
}

private func sum(_ parts: Any?) -> Int {
    (JSON.object(parts) ?? [:]).values.reduce(0) { $0 + (JSON.int($1) ?? 0) }
}

@Test func recordsAreNormalized() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [meta(), turn(), record("r1", inputTokens: 12651, cached: 8960, output: 191)])

    let daily = try CodexSource.readCodexFile(path.path)
    let parts = dayModels(daily).object("gpt-5.6-luna") ?? [:]

    #expect(parts.int("input") == 3691)
    #expect(parts.int("cache_read") == 8960)
    #expect(parts.int("output") == 191)
    #expect(parts.int("cache_write_5m") == 0)
    let hour = LocalTime.parts(of: LocalTime.parseISO(TS)!).hour
    #expect(UsageStats.hourlySeries(daily, day: Day(2026, 7, 29))[hour] == 12_842)
}

@Test func projectComesFromSessionCwd() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [meta(cwd: "/x/game"), turn(cwd: "/x/game"), record("r1", inputTokens: 5)])

    #expect(jsonEqual(dig(try CodexSource.readCodexFile(path.path), "2026-07-29", "projects"), ["/x/game": 5]))
}

@Test func duplicateResponseIdsCountOnce() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"),
                     [meta(), turn(), record("r1", inputTokens: 10), record("r1", inputTokens: 10)])

    #expect(JSON.int(dig(dayModels(try CodexSource.readCodexFile(path.path)), "gpt-5.6-luna", "input")) == 10)
}

@Test func runningTotalFallbackSkipsRepeats() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [
        meta(), turn(),
        runningTotal(inputTokens: 100),
        runningTotal(inputTokens: 100),
        ["timestamp": TS, "type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]],
        runningTotal(inputTokens: 250),
    ])

    #expect(sum(dayModels(try CodexSource.readCodexFile(path.path))["gpt-5.6-luna"]) == 250)
}

@Test func recordsWinOverRunningTotals() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"),
                     [meta(), turn(), record("r1", inputTokens: 40), runningTotal(inputTokens: 40)])

    #expect(sum(dayModels(try CodexSource.readCodexFile(path.path))["gpt-5.6-luna"]) == 40)
}

@Test func codexPartialLastLineIgnored() throws {
    let tmp = TempDir()
    let tail = String(jsonLine(record("r2", inputTokens: 99)).prefix(40))
    let path = write(tmp.url("r.jsonl"), [meta(), turn(), record("r1", inputTokens: 10)], partialTail: tail)

    #expect(JSON.int(dig(dayModels(try CodexSource.readCodexFile(path.path)), "gpt-5.6-luna", "input")) == 10)
}

@Test func newSessionWithoutUsageIsNotAnError() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [meta(), turn()])

    #expect(try CodexSource.readCodexFile(path.path).isEmpty)
}

private func sessions(_ tmp: TempDir) -> (sessions: URL, root: URL) {
    let root = tmp.mkdir("sessions/2026/07/29")
    return (tmp.url("sessions"), root)
}

@Test func rescanReplacesFileContribution() {
    let tmp = TempDir()
    let (sessionsDir, root) = sessions(tmp)
    let path = write(root.appendingPathComponent("rollout-a.jsonl"), [meta(), turn(), record("r1", inputTokens: 10)])
    var state = JSONObject()
    CodexSource.scanCodex(&state, sessionsDir: sessionsDir)
    #expect(CodexSource.codexTotal(state) == 10)

    write(path, [meta(), turn(), record("r1", inputTokens: 10), record("r2", inputTokens: 5)])
    setModificationTime(path, 1)  // force a different mtime
    CodexSource.scanCodex(&state, sessionsDir: sessionsDir)

    #expect(CodexSource.codexTotal(state) == 15)
}

@Test func deletedFileKeepsHistory() throws {
    let tmp = TempDir()
    let (sessionsDir, root) = sessions(tmp)
    let path = write(root.appendingPathComponent("rollout-a.jsonl"), [meta(), turn(), record("r1", inputTokens: 10)])
    var state = JSONObject()
    CodexSource.scanCodex(&state, sessionsDir: sessionsDir)

    try FileManager.default.removeItem(at: path)
    CodexSource.scanCodex(&state, sessionsDir: sessionsDir)

    #expect(CodexSource.codexTotal(state) == 10)
    #expect(JSON.int(dig(CodexSource.codexDaily(state), "2026-07-29", "models", "gpt-5.6-luna", "input")) == 10)
}

@Test func unrecognizedFileSetsErrorAndKeepsOthers() {
    let tmp = TempDir()
    let (sessionsDir, root) = sessions(tmp)
    write(root.appendingPathComponent("rollout-a.jsonl"), [meta(), turn(), record("r1", inputTokens: 10)])
    write(root.appendingPathComponent("rollout-b.jsonl"), [["something": "else"]])
    var state = JSONObject()

    CodexSource.scanCodex(&state, sessionsDir: sessionsDir)

    #expect(CodexSource.codexTotal(state) == 10)
    #expect(JSON.truthy(state["error"]))
}

@Test func missingSessionsDirIsEmptyNotError() {
    let tmp = TempDir()
    var state = JSONObject()
    CodexSource.scanCodex(&state, sessionsDir: tmp.url("nope"))
    #expect(CodexSource.codexTotal(state) == 0)
    #expect(JSON.isNull(state["error"]))
}

private func limitsEvent(_ used: Double, at: String = TS) -> JSONObject {
    ["timestamp": at, "type": "event_msg",
     "payload": ["type": "token_count", "info": NSNull(),
                 "rate_limits": ["primary": ["used_percent": used, "window_minutes": 300,
                                             "resets_at": 1795229213] as JSONObject,
                                 "secondary": NSNull()] as JSONObject] as JSONObject]
}

@Test func scanKeepsTheNewestRateLimits() {
    let tmp = TempDir()
    write(tmp.url("a.jsonl"), [meta(), limitsEvent(10.0, at: "2026-07-29T10:00:00.000Z"),
                               limitsEvent(20.0, at: "2026-07-29T11:00:00.000Z")])
    write(tmp.url("b.jsonl"), [meta(), limitsEvent(83.0, at: "2026-07-29T12:00:00.000Z")])

    var state = JSONObject()
    CodexSource.scanCodex(&state, sessionsDir: tmp.root)

    #expect(JSON.double(dig(CodexSource.codexRateLimits(state), "primary", "used_percent")) == 83.0)
}

@Test func noRateLimitsRecorded() {
    #expect(CodexSource.codexRateLimits([:]) == nil)
}

@Test func filesSavedBeforeLimitsWereTrackedAreReadAgain() {
    let tmp = TempDir()
    let path = tmp.url("a.jsonl")
    write(path, [meta(), limitsEvent(50.0)])
    let stat = SourceFile.Stat(path.path)!
    var state: JSONObject = ["files": [path.path: ["size": stat.size, "mtime": stat.mtime, "daily": JSONObject()]]]

    CodexSource.scanCodex(&state, sessionsDir: tmp.root)

    #expect(JSON.double(dig(CodexSource.codexRateLimits(state), "primary", "used_percent")) == 50.0)
}

// Effort: the model's effort level, from each turn_context.

private func effortTurn(_ effort: String?, collaboration: String? = nil) -> JSONObject {
    var payload: JSONObject = ["cwd": "/x/proj", "model": "gpt-5.6-luna"]
    if let effort = effort {
        payload["effort"] = effort
    }
    if let collaboration = collaboration {
        payload["collaboration_mode"] = ["settings": ["reasoning_effort": collaboration] as JSONObject] as JSONObject
    }
    return ["timestamp": TS, "type": "turn_context", "payload": payload]
}

private func efforts(_ daily: JSONObject) -> Any? {
    dig(daily, "2026-07-29", "efforts")
}

@Test func codexEffortSplitsPerTurn() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [meta(), effortTurn("medium"), record("r1", inputTokens: 10),
                                          effortTurn("high"), record("r2", inputTokens: 20)])

    let daily = try CodexSource.readCodexFile(path.path)

    #expect(jsonEqual(efforts(daily), ["gpt-5.6-luna": ["medium": 10, "high": 20]]))
    #expect(sum(dayModels(daily)["gpt-5.6-luna"]) == 30)
}

@Test func codexAbsentEffortLeavesNoEffortsKey() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [meta(), turn(), record("r1", inputTokens: 10)])

    #expect(efforts(try CodexSource.readCodexFile(path.path)) == nil)
}

@Test func codexFallsBackToCollaborationEffort() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [meta(), effortTurn(nil, collaboration: "high"), record("r1", inputTokens: 10)])

    #expect(jsonEqual(efforts(try CodexSource.readCodexFile(path.path)), ["gpt-5.6-luna": ["high": 10]]))
}

@Test func codexKeepsTheEffortWhenATurnHasNone() throws {
    let tmp = TempDir()
    let path = write(tmp.url("r.jsonl"), [meta(), effortTurn("low"), record("r1", inputTokens: 10),
                                          effortTurn(nil), record("r2", inputTokens: 5)])

    #expect(jsonEqual(efforts(try CodexSource.readCodexFile(path.path)), ["gpt-5.6-luna": ["low": 15]]))
}

@Test func normalisesEffort() {
    #expect(UsageStats.normalizeEffort(" HIGH ") == "high")
    #expect(UsageStats.normalizeEffort("x-high_2") == "x-high_2")
    #expect(UsageStats.normalizeEffort("x y") == nil)
    #expect(UsageStats.normalizeEffort("abcdefghijklm") == nil)  // 13 characters
    #expect(UsageStats.normalizeEffort("abcdefghijkl") == "abcdefghijkl")  // 12
    #expect(UsageStats.normalizeEffort("") == nil)
    #expect(UsageStats.normalizeEffort(5) == nil)
    #expect(UsageStats.normalizeEffort(NSNull()) == nil)
}

@Test func modelKeyAndTotalsAreUnchangedByEffort() throws {
    let tmp = TempDir()
    let plain = write(tmp.url("a.jsonl"), [meta(), turn(), record("r1", inputTokens: 10)])
    let withEffort = write(tmp.url("b.jsonl"), [meta(), effortTurn("high"), record("r1", inputTokens: 10)])

    let a = try CodexSource.readCodexFile(plain.path)
    let b = try CodexSource.readCodexFile(withEffort.path)

    #expect(jsonEqual(dayModels(a), dayModels(b)))
    #expect(jsonEqual(dig(a, "2026-07-29", "projects"), dig(b, "2026-07-29", "projects")))
}

@Test func filesSavedBeforeEffortAreReadOnceMore() {
    let tmp = TempDir()
    let (sessionsDir, root) = sessions(tmp)
    write(root.appendingPathComponent("rollout-a.jsonl"), [meta(), effortTurn("high"), record("r1", inputTokens: 10)])
    var state = JSONObject()
    CodexSource.scanCodex(&state, sessionsDir: sessionsDir)
    var files = state.object("files") ?? [:]
    let path = files.keys.first!
    var saved = files.object(path)!
    #expect(saved.int("v") == CodexSource.fileVersion)
    // As an older version saved it: no version, no efforts.
    saved["v"] = nil
    saved["daily"] = ["2026-07-29": ["models": JSONObject(), "projects": JSONObject()] as JSONObject] as JSONObject
    files[path] = saved
    state["files"] = files

    CodexSource.scanCodex(&state, sessionsDir: sessionsDir)

    #expect(CodexSource.codexTotal(state) == 10)
    let again = (state.object("files") ?? [:]).object(path) ?? [:]
    #expect(again.int("v") == CodexSource.fileVersion)
    #expect(jsonEqual(dig(again, "daily", "2026-07-29", "efforts"), ["gpt-5.6-luna": ["high": 10]]))
    #expect(UsageStats.hourlySeries(again.object("daily") ?? [:], day: Day(2026, 7, 29))
        .reduce(0, +) == 10)
}
