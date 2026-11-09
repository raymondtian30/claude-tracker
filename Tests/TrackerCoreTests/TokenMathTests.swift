// Ported from tests/test_token_math.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private func assistantEntry(_ inputTokens: Int, _ outputTokens: Int, cacheCreation: Int = 0,
                            cacheRead: Int = 0, timestamp: String? = nil) -> JSONObject {
    var entry: JSONObject = [
        "type": "assistant",
        "message": [
            "usage": [
                "input_tokens": inputTokens,
                "output_tokens": outputTokens,
                "cache_creation_input_tokens": cacheCreation,
                "cache_read_input_tokens": cacheRead,
            ],
        ],
    ]
    if let timestamp = timestamp {
        entry["timestamp"] = timestamp
    }
    return entry
}

private func newState() -> JSONObject {
    ["grand_total": 0, "file_offsets": JSONObject()]
}

@Test func sumUsageSinceSumsAllFields() throws {
    let tmp = TempDir()
    let path = tmp.url("session.jsonl")
    writeJSONL(path, [assistantEntry(10, 20, cacheCreation: 30, cacheRead: 40)])

    let (tokens, newOffset) = try TokenMath.sumUsageSince(path.path, offset: 0)

    #expect(tokens == 100)
    #expect(newOffset == fileSize(path))
}

@Test func sumUsageSinceIgnoresNonAssistantEntries() throws {
    let tmp = TempDir()
    let path = tmp.url("session.jsonl")
    writeJSONL(path, [["type": "user", "message": JSONObject()], assistantEntry(5, 5)])

    let (tokens, _) = try TokenMath.sumUsageSince(path.path, offset: 0)

    #expect(tokens == 10)
}

@Test func sumUsageSinceOnlyCountsNewBytes() throws {
    let tmp = TempDir()
    let path = tmp.url("session.jsonl")
    writeJSONL(path, [assistantEntry(10, 10)])
    let offsetAfterFirst = fileSize(path)

    appendJSONL(path, [assistantEntry(1, 1)])

    let (tokens, newOffset) = try TokenMath.sumUsageSince(path.path, offset: offsetAfterFirst)

    #expect(tokens == 2)
    #expect(newOffset == fileSize(path))
}

@Test func sumUsageSinceSkipsIncompleteTrailingLine() throws {
    let tmp = TempDir()
    let path = tmp.url("session.jsonl")
    writeJSONL(path, [assistantEntry(10, 10)])
    appendText(path, #"{"type": "assistant", "message": {"usage":"#)  // no trailing newline

    let (tokens, newOffset) = try TokenMath.sumUsageSince(path.path, offset: 0)

    #expect(tokens == 20)
    #expect(newOffset == jsonLine(assistantEntry(10, 10)).utf8.count)
}

@Test func refreshGrandTotalInitialScanSumsEverything() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let project = tmp.mkdir("projects/some-project")
    writeJSONL(project.appendingPathComponent("a.jsonl"), [assistantEntry(10, 10)])
    writeJSONL(project.appendingPathComponent("b.jsonl"), [assistantEntry(5, 5)])

    var state = newState()
    try TokenMath.refreshGrandTotal(&state, projectsDir: projectsDir)

    #expect(state.int("grand_total") == 30)
    #expect(state.object("file_offsets")?.count == 2)
}

@Test func refreshGrandTotalOnlyAddsNewTokensOnSecondCall() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let sessionFile = tmp.mkdir("projects/some-project").appendingPathComponent("a.jsonl")
    writeJSONL(sessionFile, [assistantEntry(10, 10)])

    var state = newState()
    try TokenMath.refreshGrandTotal(&state, projectsDir: projectsDir)
    #expect(state.int("grand_total") == 20)

    appendJSONL(sessionFile, [assistantEntry(1, 1)])

    try TokenMath.refreshGrandTotal(&state, projectsDir: projectsDir)

    #expect(state.int("grand_total") == 22)
}

@Test func refreshGrandTotalDropsDeletedFilesWithoutLosingTotal() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let sessionFile = tmp.mkdir("projects/some-project").appendingPathComponent("a.jsonl")
    writeJSONL(sessionFile, [assistantEntry(10, 10)])

    var state = newState()
    try TokenMath.refreshGrandTotal(&state, projectsDir: projectsDir)
    #expect(state.int("grand_total") == 20)

    try FileManager.default.removeItem(at: sessionFile)
    try TokenMath.refreshGrandTotal(&state, projectsDir: projectsDir)

    #expect(state.int("grand_total") == 20)
    #expect(jsonEqual(state["file_offsets"], JSONObject()))
}

@Test(arguments: [
    (0, "0"),
    (999, "999"),
    (1_000, "1.0K"),
    (12_345, "12.3K"),
    (1_000_000, "1.0M"),
    (2_500_000, "2.5M"),
    (1_000_000_000, "1.0B"),
    (2_451_790_780, "2.5B"),
])
func formatCount(n: Int, expected: String) {
    #expect(TokenMath.formatCount(n) == expected)
}

@Test func sumUsageForTodayOnlyCountsMatchingDate() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let path = tmp.mkdir("projects/some-project").appendingPathComponent("session.jsonl")
    writeJSONL(path, [
        assistantEntry(10, 10, timestamp: "2026-07-29T12:00:00.000Z"),
        assistantEntry(5, 5, timestamp: "2026-07-28T12:00:00.000Z"),
    ])
    setModificationTime(path, Date().timeIntervalSince1970)

    let total = try TokenMath.sumUsageForToday(projectsDir: projectsDir, today: Day(2026, 7, 29))

    #expect(total == 20)
}

@Test func sumUsageForTodaySkipsFilesNotModifiedToday() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let path = tmp.mkdir("projects/some-project").appendingPathComponent("session.jsonl")
    writeJSONL(path, [assistantEntry(10, 10, timestamp: "2026-07-29T12:00:00.000Z")])
    let twoDaysBefore = LocalTime.timestamp(2026, 7, 27, 12, 0)
    setModificationTime(path, twoDaysBefore)

    let total = try TokenMath.sumUsageForToday(projectsDir: projectsDir, today: Day(2026, 7, 29))

    #expect(total == 0)
}

@Test func sumUsageForTodayIgnoresEntriesMissingUsageOrTimestamp() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    let path = tmp.mkdir("projects/some-project").appendingPathComponent("session.jsonl")
    writeJSONL(path, [
        ["type": "assistant", "message": JSONObject()],
        assistantEntry(3, 3, timestamp: "2026-07-29T12:00:00.000Z"),
    ])
    setModificationTime(path, Date().timeIntervalSince1970)

    let total = try TokenMath.sumUsageForToday(projectsDir: projectsDir, today: Day(2026, 7, 29))

    #expect(total == 6)
}

@Test func refreshRecordsDailyBuckets() throws {
    let tmp = TempDir()
    let projectsDir = tmp.url("projects")
    writeJSONL(tmp.mkdir("projects/p").appendingPathComponent("s.jsonl"), [
        assistantEntry(1, 2, cacheCreation: 3, cacheRead: 4, timestamp: "2026-07-29T12:00:00.000Z"),
    ])
    var state = newState()

    try TokenMath.refreshGrandTotal(&state, projectsDir: projectsDir)

    #expect(state.int("grand_total") == 10)
    #expect(state.object("daily")?.count == 1)
}

/// Python's `sum(day["models"]["unknown"].values())` for the only day.
private func unknownModelTokens(_ state: JSONObject) -> Int? {
    guard let daily = state.object("daily"), daily.count == 1,
          let parts = dig(daily.values.first, "models", "unknown") as? JSONObject
    else { return nil }
    return parts.values.reduce(0) { $0 + (JSON.int($1) ?? 0) }
}

@Test func backfillReadsOnlyUpToSavedOffsetsAndKeepsGrandTotal() throws {
    let tmp = TempDir()
    let path = tmp.url("s.jsonl")
    writeJSONL(path, [
        assistantEntry(5, 5, timestamp: "2026-07-29T12:00:00.000Z"),
        assistantEntry(100, 100, timestamp: "2026-07-29T13:00:00.000Z"),
    ])
    let firstLineEnd = try Data(contentsOf: path).firstIndex(of: 0x0A)! + 1
    var state: JSONObject = ["grand_total": 999, "file_offsets": [path.path: firstLineEnd]]

    try TokenMath.backfillDaily(&state)

    #expect(unknownModelTokens(state) == 10)
    #expect(state.int("grand_total") == 999)
    #expect(state.bool("daily_backfilled") == true)
}

@Test func backfillRunsOnlyOnce() throws {
    let tmp = TempDir()
    let path = tmp.url("s.jsonl")
    writeJSONL(path, [assistantEntry(5, 5, timestamp: "2026-07-29T12:00:00.000Z")])
    var state: JSONObject = ["grand_total": 0, "file_offsets": [path.path: fileSize(path)]]

    try TokenMath.backfillDaily(&state)
    try TokenMath.backfillDaily(&state)

    #expect(unknownModelTokens(state) == 10)
}

@Test func backfillSkipsMissingFiles() throws {
    let tmp = TempDir()
    var state: JSONObject = ["grand_total": 0, "file_offsets": [tmp.url("gone.jsonl").path: 50]]

    try TokenMath.backfillDaily(&state)

    #expect(jsonEqual(state["daily"], JSONObject()))
}

private func limitHit(_ kind: String = "five_hour", resetsAt: Int = 1_794_123_000,
                      status: String = "rejected") -> JSONObject {
    ["type": "assistant", "timestamp": "2026-11-08T07:29:11.278Z",
     "apiErrorParams": ["rate_limit_info": ["status": status, "resetsAt": resetsAt,
                                            "rateLimitType": kind]]]
}

@Test func refreshRemembersWhenClaudeLimitsWereReached() throws {
    let tmp = TempDir()
    writeJSONL(tmp.mkdir("proj").appendingPathComponent("s.jsonl"), [
        limitHit(resetsAt: 100), limitHit(resetsAt: 300), limitHit("seven_day", resetsAt: 500),
        limitHit(resetsAt: 999, status: "allowed"),
    ])
    var state = newState()

    try TokenMath.refreshGrandTotal(&state, projectsDir: tmp.root)

    #expect(jsonEqual(state["claude_limit_hits"], ["five_hour": 300, "seven_day": 500]))
}

@Test func refreshDropsTheOld5HourBudgetReplies() throws {
    let tmp = TempDir()
    var state: JSONObject = ["grand_total": 0, "file_offsets": JSONObject(), "claude_recent": [[1, 1]]]

    try TokenMath.refreshGrandTotal(&state, projectsDir: tmp.root)

    #expect(state["claude_recent"] == nil)
}
