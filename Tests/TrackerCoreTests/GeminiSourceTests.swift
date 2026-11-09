// Ported from tests/test_gemini_source.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private let TS = "2026-07-29T12:00:00.000Z"

private func meta() -> JSONObject {
    ["sessionId": "s1", "projectHash": "abc", "startTime": TS, "lastUpdated": TS]
}

private func reply(id: String = "m2", model: String = "gemini-2.5-pro", input: Int = 100, output: Int = 20,
                   cached: Int = 60, thoughts: Int = 5, tool: Int = 3, total: Int = 128) -> JSONObject {
    ["id": id, "timestamp": TS, "type": "gemini", "content": "...", "model": model,
     "tokens": ["input": input, "output": output, "cached": cached, "thoughts": thoughts,
                "tool": tool, "total": total]]
}

@discardableResult
private func writeRecords(_ url: URL, _ records: [JSONObject], trailing: String = "") -> URL {
    writeText(url, records.map(jsonLine).joined() + trailing)
    return url
}

@discardableResult
private func project(_ tmp: TempDir, slug: String = "myproj", root: String = "/Users/me/myproj") -> URL {
    let folder = tmp.mkdir("tmp/\(slug)")
    writeText(folder.appendingPathComponent(".project_root"), root)
    return folder
}

private func firstBucket(_ daily: JSONObject) -> JSONObject {
    JSON.object(daily.values.first) ?? [:]
}

private func sum(_ parts: Any?) -> Int {
    (JSON.object(parts) ?? [:]).values.reduce(0) { $0 + (JSON.int($1) ?? 0) }
}

@Test func replyTokensSplitIntoTheAppsCategories() throws {
    let tmp = TempDir()
    let folder = project(tmp)
    let path = writeRecords(folder.appendingPathComponent("chats/session-2026-07-29T12-00-s1.jsonl"), [
        meta(),
        ["id": "m1", "timestamp": TS, "type": "user", "content": "hi"],
        reply(),
    ])

    let daily = try GeminiSource.readGeminiFile(path, project: "/Users/me/myproj")

    let bucket = firstBucket(daily)
    let parts = bucket.object("models")?.object("gemini-2.5-pro") ?? [:]
    // input counts cached tokens, so they're split out; tool-use prompt
    // tokens are input; thinking tokens are output. All of it adds to total.
    #expect(parts.int("input") == 100 - 60 + 3)
    #expect(parts.int("cache_read") == 60)
    #expect(parts.int("output") == 20 + 5)
    #expect(sum(parts) == 128)
    #expect(Array((bucket.object("projects") ?? [:]).keys) == ["/Users/me/myproj"])
}

@Test func aReplyUpdatedLaterCountsOnceWithItsLatestTokens() throws {
    let tmp = TempDir()
    let path = writeRecords(tmp.url("s.jsonl"), [
        meta(),
        reply(input: 10, output: 1, cached: 0, thoughts: 0, tool: 0, total: 11),
        ["$set": ["lastUpdated": TS]],
        reply(input: 10, output: 7, cached: 0, thoughts: 0, tool: 0, total: 17),
    ])

    let daily = try GeminiSource.readGeminiFile(path, project: "p")

    #expect(sum(firstBucket(daily).object("models")?["gemini-2.5-pro"]) == 17)
}

@Test func halfWrittenLastLineWaits() throws {
    let tmp = TempDir()
    let path = writeRecords(tmp.url("s.jsonl"), [meta(), reply()], trailing: #"{"id": "m3", "type": "gem"#)

    let daily = try GeminiSource.readGeminiFile(path, project: "p")

    #expect(sum(firstBucket(daily).object("models")?["gemini-2.5-pro"]) == 128)
}

@Test func legacyJsonSession() throws {
    let tmp = TempDir()
    let path = tmp.url("session-old.json")
    var session = meta()
    session["messages"] = [reply(id: "a"), reply(id: "b")]
    writeText(path, String(decoding: try JSON.encode(session), as: UTF8.self))

    let daily = try GeminiSource.readGeminiFile(path, project: "p")

    #expect(sum(firstBucket(daily).object("models")?["gemini-2.5-pro"]) == 256)
}

@Test func notAGeminiSessionIsAnError() {
    let tmp = TempDir()
    let path = writeRecords(tmp.url("s.jsonl"), [["hello": "world"]])

    do {
        _ = try GeminiSource.readGeminiFile(path, project: "p")
        Issue.record("expected an error")
    } catch {
        #expect("\(error)".contains("doesn't look like a Gemini CLI session"))
    }
}

@Test func scanFindsSessionsAndSubagentsAndLabelsProjects() {
    let tmp = TempDir()
    let folder = project(tmp)
    writeRecords(folder.appendingPathComponent("chats/session-a.jsonl"), [meta(), reply()])
    writeRecords(folder.appendingPathComponent("chats/s1/sub.jsonl"), [meta(), reply(id: "x")])
    // A folder without .project_root falls back to projects.json.
    writeRecords(tmp.url("tmp/other/chats/session-b.jsonl"), [meta(), reply(id: "y")])
    writeText(tmp.url("projects.json"), #"{"projects": {"/Users/me/other": "other"}}"#)

    var state = JSONObject()
    GeminiSource.scanGemini(&state, geminiDir: tmp.root)

    #expect(JSON.isNull(state["error"]))
    #expect(GeminiSource.geminiTotal(state) == 3 * 128)
    var projects = Set<String>()
    for bucket in GeminiSource.geminiDaily(state).values {
        projects.formUnion((JSON.object(bucket)?.object("projects") ?? [:]).keys)
    }
    #expect(projects == ["/Users/me/myproj", "/Users/me/other"])
}

@Test func scanRereadsOnlyChangedFilesAndKeepsDeletedOnes() throws {
    let tmp = TempDir()
    let folder = project(tmp)
    let path = writeRecords(folder.appendingPathComponent("chats/session-a.jsonl"), [meta(), reply()])
    var state = JSONObject()
    GeminiSource.scanGemini(&state, geminiDir: tmp.root)

    try FileManager.default.removeItem(at: path)
    GeminiSource.scanGemini(&state, geminiDir: tmp.root)

    #expect(GeminiSource.geminiTotal(state) == 128)
}

@Test func scanWithNothingThere() {
    let tmp = TempDir()
    var state = JSONObject()
    GeminiSource.scanGemini(&state, geminiDir: tmp.url("missing"))

    #expect(GeminiSource.geminiTotal(state) == 0)
    #expect(JSON.isNull(state["error"]))
}
