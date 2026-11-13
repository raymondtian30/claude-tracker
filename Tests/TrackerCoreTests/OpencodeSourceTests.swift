// Ported from tests/test_opencode_source.py, test for test.

import Foundation
import SQLite3
import Testing
@testable import TrackerCore

private let NOON = Int(LocalTime.timestamp(2026, 7, 29, 12, 0) * 1000)  // local noon, in ms

/// A writable test database (the fixture side, like Python's sqlite3.connect).
private final class TestDB {
    var handle: OpaquePointer?

    init(_ url: URL) {
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
    }

    /// Runs `sql`; false if SQLite refused it.
    @discardableResult
    func exec(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    func close() {
        sqlite3_close(handle)
    }
}

/// A SQL literal: NULL, a number, or a quoted string.
private func literal(_ value: Any?) -> String {
    switch value {
    case nil, is NSNull: return "NULL"
    case let text as String: return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    default: return "\(value!)"
    }
}

private func jsonText(_ value: Any) -> String {
    String(decoding: try! JSON.encode(value), as: UTF8.self)
}

@discardableResult
private func makeDB(_ url: URL, _ messages: [JSONObject],
                    sessions: [(String, String)] = [("s1", "/x/proj")]) -> URL {
    let db = TestDB(url)
    db.exec("create table session_v2 (id text primary key, directory text not null)")
    db.exec("create table session_message (id text primary key, session_id text, type text, seq int,"
            + " time_created int, time_updated int, data text)")
    for (id, directory) in sessions {
        db.exec("insert into session_v2 values (\(literal(id)), \(literal(directory)))")
    }
    for (i, message) in messages.enumerated() {
        var data = message
        let session = data.removeValue(forKey: "_session") as? String ?? "s1"
        db.exec("insert into session_message values ('m\(i)', \(literal(session)), 'message', \(i), 0, 0,"
                + " \(literal(jsonText(data))))")
    }
    db.close()
    return url
}

private func message(input: Int = 0, output: Int = 0, reasoning: Int = 0, read: Int = 0, write: Int = 0,
                     cost: Double? = nil, model: String = "gemini-4-argon", when: Int = NOON,
                     extra: JSONObject = [:]) -> JSONObject {
    var data: JSONObject = [
        "time": ["created": when], "model": ["id": model, "providerID": "google"],
        "tokens": ["input": input, "output": output, "reasoning": reasoning,
                   "cache": ["read": read, "write": write]] as JSONObject,
    ]
    if let cost = cost {
        data["cost"] = cost
    }
    data.merge(extra) { _, new in new }
    return data
}

@Test func tokensNormalizedAndCostRecorded() throws {
    let tmp = TempDir()
    let db = makeDB(tmp.url("o.db"), [message(input: 2261, output: 63, reasoning: 7, read: 6555, write: 3, cost: 0.5),
                                      ["time": ["created": NOON], "text": "user message, no tokens"]])

    let daily = try OpencodeSource.readOpencode(db)
    let day = daily.object("2026-07-29") ?? [:]

    #expect(jsonEqual(dig(day, "models", "gemini-4-argon"), [
        "input": 2261, "output": 70, "cache_write_5m": 3, "cache_write_1h": 0, "cache_read": 6555,
    ]))
    #expect(jsonEqual(day["recorded_cost"], ["gemini-4-argon": 0.5]))
    let hour = LocalTime.parts(of: Double(NOON) / 1000).hour
    #expect(UsageStats.hourlySeries(daily, day: Day(2026, 7, 29))[hour] == 8_889)
}

@Test func projectFromSessionDirectory() throws {
    let tmp = TempDir()
    let db = makeDB(tmp.url("o.db"), [message(input: 5, extra: ["_session": "s2"])], sessions: [("s2", "/x/game")])

    #expect(jsonEqual(dig(try OpencodeSource.readOpencode(db), "2026-07-29", "projects"), ["/x/game": 5]))
}

@Test func scanNeverShrinksAfterDeletion() throws {
    let tmp = TempDir()
    let path = tmp.url("o.db")
    makeDB(path, [message(input: 10), message(input: 5)])
    var state = JSONObject()
    OpencodeSource.scanOpencode(&state, dbPath: path)
    #expect(OpencodeSource.opencodeTotal(state) == 15)

    try FileManager.default.removeItem(at: path)
    makeDB(path, [message(input: 10)])  // one conversation deleted in opencode
    OpencodeSource.scanOpencode(&state, dbPath: path)

    #expect(OpencodeSource.opencodeTotal(state) == 15)
}

@Test func missingTableSetsErrorKeepsHistory() throws {
    let tmp = TempDir()
    let path = tmp.url("o.db")
    makeDB(path, [message(input: 10)])
    var state = JSONObject()
    OpencodeSource.scanOpencode(&state, dbPath: path)

    try FileManager.default.removeItem(at: path)
    let db = TestDB(path)
    db.exec("create table other (x int)")
    db.close()
    OpencodeSource.scanOpencode(&state, dbPath: path)

    #expect(JSON.truthy(state["error"]))
    #expect(OpencodeSource.opencodeTotal(state) == 10)
    #expect(JSON.int(dig(OpencodeSource.opencodeDaily(state), "2026-07-29", "models", "gemini-4-argon", "input")) == 10)
}

@Test func missingDatabaseIsEmptyNotError() {
    let tmp = TempDir()
    var state = JSONObject()
    OpencodeSource.scanOpencode(&state, dbPath: tmp.url("none.db"))
    #expect(OpencodeSource.opencodeTotal(state) == 0)
    #expect(JSON.isNull(state["error"]))
}

@Test func openedReadOnly() throws {
    let tmp = TempDir()
    let path = makeDB(tmp.url("o.db"), [message(input: 1)])
    let before = SourceFile.Stat(path.path)!

    var state = JSONObject()
    OpencodeSource.scanOpencode(&state, dbPath: path)

    let after = SourceFile.Stat(path.path)!
    #expect(after.mtime == before.mtime && after.size == before.size)
    #expect(!FileManager.default.fileExists(atPath: tmp.url("o.db-journal").path))
}

private func addSessionTotals(_ path: URL, _ sessionId: String, model: String, createdMs: Int, cost: Double,
                              input: Int = 0, output: Int = 0, reasoning: Int = 0, read: Int = 0, write: Int = 0) {
    let db = TestDB(path)
    for name in ["model", "time_created", "cost", "tokens_input", "tokens_output", "tokens_reasoning",
                 "tokens_cache_read", "tokens_cache_write"] {
        db.exec("alter table session_v2 add column \(name)")  // fails harmlessly if it's there
    }
    let values: [Any] = [jsonText(["id": model]), createdMs, cost, input, output, reasoning, read, write]
    let columns = ["model", "time_created", "cost", "tokens_input", "tokens_output", "tokens_reasoning",
                   "tokens_cache_read", "tokens_cache_write"]
    let sets = zip(columns, values).map { "\($0)=\(literal($1))" }.joined(separator: ", ")
    #expect(db.exec("update session_v2 set \(sets) where id=\(literal(sessionId))"))
    db.close()
}

@Test func sessionLeftoverTokensCounted() throws {
    let tmp = TempDir()
    let path = makeDB(tmp.url("o.db"), [message(input: 100, output: 10, cost: 0.25)])
    // The session's own totals include 50 input + 5 output the messages don't
    // (e.g. title generation), and 0.05 more cost.
    addSessionTotals(path, "s1", model: "gemini-4-argon", createdMs: NOON, cost: 0.30, input: 150, output: 15)

    let day = try OpencodeSource.readOpencode(path).object("2026-07-29") ?? [:]

    #expect(JSON.int(dig(day, "models", "gemini-4-argon", "input")) == 150)
    #expect(JSON.int(dig(day, "models", "gemini-4-argon", "output")) == 15)
    #expect(abs((JSON.double(dig(day, "recorded_cost", "gemini-4-argon")) ?? 0) - 0.30) < 1e-9)
}

@Test func sessionTotalsLowerThanMessagesAddNothing() throws {
    let tmp = TempDir()
    let path = makeDB(tmp.url("o.db"), [message(input: 100)])
    addSessionTotals(path, "s1", model: "gemini-4-argon", createdMs: NOON, cost: 0.0, input: 40)

    #expect(JSON.int(dig(try OpencodeSource.readOpencode(path), "2026-07-29", "models", "gemini-4-argon", "input")) == 100)
}

@Test func opencodeScansBYOKCredentialsCatalogModelsLimitsAndEffortAcrossTabs() throws {
    let tmp = TempDir()
    let path = makeDB(tmp.url("o.db"), [
        message(input: 1000, output: 500, model: "gemini-4-argon",
                extra: ["model": ["id": "gemini-4-argon", "providerID": "google", "variant": "medium"] as JSONObject]),
    ])
    let db = TestDB(path)
    db.exec("create table credential (id text primary key, integration_id text, label text, value text, active int)")
    db.exec("insert into credential values ('c1', 'google', 'Google', '{\"type\":\"key\",\"key\":\"AIzaSyTestKey123456\"}', 1)")
    db.exec("create table kv (key text primary key, value text)")
    let catalogBody: JSONObject = [
        "google": [
            "models": [
                "gemini-4-argon": [
                    "id": "gemini-4-argon",
                    "name": "Gemini 4 Argon",
                    "limit": ["context": 1_048_576, "output": 32_768],
                    "cost": ["text": ["input": ["price": 2.0, "cache": ["read": 0.1]], "output": ["price": 10.0]]],
                ] as JSONObject,
            ] as JSONObject,
        ] as JSONObject,
    ]
    let catalogWrapper: JSONObject = ["body": jsonText(catalogBody)]
    db.exec("insert into kv values ('models-dev:v2:catalog', \(literal(jsonText(catalogWrapper))))")
    db.close()

    var sourceState = JSONObject()
    OpencodeSource.scanOpencode(&sourceState, dbPath: path)
    let state: JSONObject = ["enabled_tools": ["opencode"], "sources": ["opencode": sourceState]]

    // Secret key is loaded on demand and never stored in state.json.
    #expect(!jsonText(state).contains("AIzaSyTestKey123456"))
    #expect(OpencodeSource.loadCredentialKeys(dbPath: path)["google"] == "AIzaSyTestKey123456")
    #expect(OpencodeSource.byokProviders(state) == ["google"])
    #expect(OpencodeSource.byokModels(state)["gemini-4-argon"]?.string("name") == "Gemini 4 Argon")
    #expect(OpencodeSource.byokModels(state)["gemini-4-argon"]?.int("context") == 1_048_576)
    #expect(OpencodeSource.byokModels(state)["gemini-4-argon"]?.int("output") == 32_768)

    // Check that all applicable tabs (Home, Models, Cost, Limits) use the BYOK key, models, and limits.
    let view = Tools.toolView(state, "opencode")
    let tabs = Dictionary(uniqueKeysWithValues: PanelModel.buildPanel(
        view, state: state, sessions: [], friends: [], showLeaderboard: false, today: Day(2026, 7, 29)
    ).map { ($0.key, $0) })

    // Home tab shows BYOK API key card
    let overviewItems = tabs["overview"]!.cards.flatMap(\.items)
    #expect(overviewItems.contains(.row(label: "Google (BYOK)", value: "1 model")))

    // Models tab uses display name + effort and lists available BYOK models with limits
    let modelsItems = tabs["models"]!.cards.flatMap(\.items)
    #expect(modelsItems.contains(.bar(label: "Gemini 4 Argon (Medium)", value: "1.5K · 100%", fraction: 1.0)))
    #expect(modelsItems.contains(.row(label: "Gemini 4 Argon", value: "1.0M · 32.8K out")))

    // Cost tab prices tokens using the BYOK catalog prices ($2/M input * 1000 + $10/M output * 500 = $0.007 -> $0.01)
    let costItems = tabs["cost"]!.cards.flatMap(\.items)
    #expect(!costItems.contains { if case let .note(t) = $0 { return t.contains("unknown models") } else { return false } })

    // Limits tab: the BYOK API key and model context/output limits sit in its one "Limits" card
    #expect(tabs["limits"]!.cards.first?.title == "Limits")
    #expect(!tabs["limits"]!.cards.contains { $0.title == "BYOK limits" })
    let limitsItems = tabs["limits"]!.cards.flatMap(\.items)
    #expect(limitsItems.contains(.row(label: "Google API key", value: "Active (opencode)")))
    #expect(limitsItems.contains(.row(label: "Gemini 4 Argon", value: "1.0M ctx · 32.8K out")))
}

@Test func conflictingCatalogAuthorsAndStaleHostAttributionAreCleared() {
    let tmp = TempDir()
    let path = makeDB(tmp.url("catalog.db"), [])
    let db = TestDB(path)
    db.exec("create table kv (key text primary key, value text)")
    let body: JSONObject = [
        "writer": ["models": ["shared-model": ["name": "Writer model"]]],
        "cohere": ["models": ["shared-model": ["name": "Cohere model"]]],
        "nvidia": ["models": ["unknown-hosted": ["name": "Unknown"]]],
        "NousResearch": ["models": ["DeepSeek-R1-Distill-Qwen-32B": ["name": "Derivative"]]],
    ]
    db.exec("insert into kv values ('models-dev:v2:catalog', \(literal(jsonText(["body": body]))))")
    db.close()
    var daily = JSONObject()
    for model in ["shared-model", "unknown-hosted", "DeepSeek-R1-Distill-Qwen-32B"] {
        UsageStats.addUsage(&daily, day: Day(2026, 11, 12), model: model, project: "~/fixture", parts: ["input": 10])
    }
    var source: JSONObject = ["byok": ["models": ["unknown-hosted": ["provider": "nvidia"]]]]
    OpencodeSource.scanBYOK(&source, dbPath: path, daily: daily)
    #expect(dig(source, "byok", "models", "shared-model", "provider") == nil)
    #expect(dig(source, "byok", "models", "unknown-hosted", "provider") == nil)
    #expect(JSON.string(dig(source, "byok", "models", "DeepSeek-R1-Distill-Qwen-32B", "provider")) == "nous")
}

@Test func catalogVotesOnlyCountWhenAnIntegrationCanPlaceTheModel() {
    let tmp = TempDir()
    let path = makeDB(tmp.url("catalog.db"), [])
    let db = TestDB(path)
    db.exec("create table kv (key text primary key, value text)")
    let body: JSONObject = [
        // One integration knows it, a host can't place it: not a conflict.
        "google": ["models": ["learnlm-2.0-flash": ["name": "LearnLM"]]],
        "nvidia": ["models": ["learnlm-2.0-flash": ["name": "LearnLM"]]],
        // Two authors claim it, but the name says Kimi.
        "writer": ["models": ["kimi-k2": ["name": "K2"]]],
        "cohere": ["models": ["kimi-k2": ["name": "K2"]]],
        // Alibaba hosts others' models too.
        "alibaba": ["models": ["deepseek-v3": ["name": "DeepSeek V3"]]],
    ]
    db.exec("insert into kv values ('models-dev:v2:catalog', \(literal(jsonText(["body": body]))))")
    db.close()
    var daily = JSONObject()
    for model in ["learnlm-2.0-flash", "kimi-k2", "deepseek-v3"] {
        UsageStats.addUsage(&daily, day: Day(2026, 11, 12), model: model, project: "~/fixture", parts: ["input": 10])
    }
    var source: JSONObject = [:]
    OpencodeSource.scanBYOK(&source, dbPath: path, daily: daily)
    #expect(JSON.string(dig(source, "byok", "models", "learnlm-2.0-flash", "provider")) == "google")
    #expect(JSON.truthy(dig(source, "byok", "models", "kimi-k2", "provider_ambiguous")))
    #expect(JSON.string(dig(source, "byok", "models", "deepseek-v3", "provider")) == "deepseek")

    var state: JSONObject = ["enabled_tools": ["opencode"], "onboarding_done": true,
                             "sources": ["opencode": ["daily": daily, "byok": source["byok"] as Any]]]
    for key in ["google", "kimi", "deepseek"] { AppState.setProviderEnabled(&state, key, true) }
    #expect(Providers.providerView(state, "google").grandTotal == 10)
    #expect(Providers.providerView(state, "kimi").grandTotal == 10)  // the name decides
    #expect(Providers.providerView(state, "deepseek").grandTotal == 10)
    #expect(Providers.providerView(state, "qwen").grandTotal == 0)
}
