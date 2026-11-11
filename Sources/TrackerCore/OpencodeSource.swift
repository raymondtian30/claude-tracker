import Foundation
import SQLite3

/// opencode usage, read from opencode's own database on this Mac.
///
/// The database is opened read-only, and only the token counts, model, time and
/// cost of each message (`session_message`) plus each session's folder
/// (`session_v2.directory`) are read. Message text and the database's account
/// and credential tables are never queried.
///
/// Each scan is merged into the saved per-day buckets keeping the larger
/// numbers, so conversations deleted in opencode don't shrink history.
public enum OpencodeSource {
    public static let opencodeDB = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".local/share/opencode/opencode.db")

    static let query = """
        select m.data, s.directory, m.session_id
        from session_message m left join session_v2 s on s.id = m.session_id
        where json_extract(m.data, '$.tokens') is not null
    """

    // Per-session totals. They also include calls opencode makes that aren't
    // saved as messages (e.g. generating the session title).
    static let sessionQuery = """
        select id, directory, model, time_created, cost, tokens_input, tokens_output,
               tokens_reasoning, tokens_cache_read, tokens_cache_write
        from session_v2
    """

    /// The database couldn't be read as expected (Python's sqlite3.Error or
    /// a message whose data isn't JSON).
    public struct ReadError: Error, CustomStringConvertible {
        public let description: String
    }

    static func parts(_ tokens: JSONObject) -> [String: Int] {
        let cache = tokens.object("cache") ?? [:]
        return [
            "input": tokens.int("input") ?? 0,
            "output": (tokens.int("output") ?? 0) + (tokens.int("reasoning") ?? 0),
            "cache_write_5m": cache.int("write") ?? 0,
            "cache_write_1h": 0,
            "cache_read": cache.int("read") ?? 0,
        ]
    }

    /// Tokens and cost of one session already counted from its messages.
    struct Counted {
        var parts = [String: Int]()
        var cost = 0.0
    }

    /// Per-day buckets for every message opencode recorded tokens for.
    /// Throws `ReadError` if the database can't be read as expected.
    public static func readOpencode(_ dbPath: URL) throws -> JSONObject {
        let rows: [[Any]]
        let sessions: [[Any]]
        do {
            let db = try Database(readOnly: dbPath)
            defer { db.close() }
            rows = try db.rows(query)
            do {
                sessions = try db.rows(sessionQuery)
            } catch {
                sessions = []  // older opencode without per-session totals
            }
        }

        var daily = JSONObject()
        var counted = [AnyHashable: Counted]()  // session id -> already counted from messages
        for row in rows {
            let data = try decodeObject(row[0])
            let parts = self.parts(data.object("tokens") ?? [:])
            guard let created = data.object("time")?.double("created"), created != 0,
                  parts.values.reduce(0, +) != 0
            else { continue }
            let modelObject = data.object("model")
            let model = CodexSource.nonEmpty(modelObject?.string("id")) ?? "unknown"
            let effort = UsageStats.normalizeEffort(modelObject?["variant"])
                ?? UsageStats.normalizeEffort(modelObject?["effort"])
            let cost = data.double("cost")
            UsageStats.addUsage(&daily, day: Day(timestamp: created / 1000), model: model,
                                project: UsageStats.projectLabel(row[1] as? String), parts: parts, cost: cost,
                                effort: effort)
            var seen = counted[hashable(row[2])] ?? Counted()
            for (category, count) in parts {
                seen.parts[category, default: 0] += count
            }
            seen.cost += cost ?? 0.0
            counted[hashable(row[2])] = seen
        }

        for row in sessions {
            addSessionLeftover(&daily, row, counted[hashable(row[0])] ?? Counted())
        }
        return daily
    }

    /// Count what a session's own totals have beyond its messages.
    static func addSessionLeftover(_ daily: inout JSONObject, _ row: [Any], _ already: Counted) {
        let (directory, modelJSON, created, cost) = (row[1], row[2], row[3], row[4])
        let sessionParts = parts([
            "input": row[5], "output": row[6], "reasoning": row[7],
            "cache": ["read": row[8], "write": row[9]] as JSONObject,
        ])
        var leftover = [String: Int]()
        for (category, count) in sessionParts {
            leftover[category] = max(count - (already.parts[category] ?? 0), 0)
        }
        guard let createdMs = JSON.double(created), createdMs != 0,
              leftover.values.reduce(0, +) != 0
        else { return }
        let modelObject = (modelJSON as? String).flatMap { JSON.parseObject(Data($0.utf8)) }
        let model = CodexSource.nonEmpty(modelObject?.string("id")) ?? "unknown"
        let effort = UsageStats.normalizeEffort(modelObject?["variant"])
            ?? UsageStats.normalizeEffort(modelObject?["effort"])
        let extraCost = max((JSON.double(cost) ?? 0.0) - already.cost, 0.0)
        UsageStats.addUsage(&daily, day: Day(timestamp: createdMs / 1000), model: model,
                            project: UsageStats.projectLabel(directory as? String), parts: leftover,
                            cost: extraCost != 0 ? extraCost : nil, effort: effort)
    }

    /// Update `sourceState` from opencode's database. Sets
    /// sourceState["error"] to a message if it couldn't be read, else null.
    public static func scanOpencode(_ sourceState: inout JSONObject, dbPath: URL = opencodeDB) {
        let saved = sourceState.object("daily") ?? [:]
        sourceState["daily"] = saved
        sourceState["error"] = NSNull()
        if !FileManager.default.fileExists(atPath: dbPath.path) {
            return
        }
        do {
            let current = try readOpencode(dbPath)
            let merged = UsageStats.mergeMaxDaily(saved, current)
            sourceState["daily"] = merged
            scanBYOK(&sourceState, dbPath: dbPath, daily: merged)
        } catch {
            sourceState["error"] = "opencode's database couldn't be read (\(error))"
        }
    }

    // MARK: - BYOK credentials, catalog models and limits

    static let credentialQuery = """
        select integration_id, label, value, active
        from credential
    """

    static let catalogQuery = """
        select value from kv where key = 'models-dev:v2:catalog'
    """

    /// Active BYOK API keys configured in opencode (`credential` table in
    /// `opencode.db` and `auth.json` beside it), keyed by canonical provider id.
    /// Never written to `state.json`.
    public static func loadCredentialKeys(dbPath: URL = opencodeDB, authPath: URL? = nil) -> [String: String] {
        var keys = [String: String]()
        let authFile = authPath ?? dbPath.deletingLastPathComponent().appendingPathComponent("auth.json")
        if let data = try? Data(contentsOf: authFile), let obj = JSON.parseObject(data) {
            for (rawProvider, entry) in obj {
                guard let provider = Providers.normalizeProvider(rawProvider),
                      let key = extractKey(from: entry), Accounts.validKey(key)
                else { continue }
                keys[provider] = key
            }
        }
        if FileManager.default.fileExists(atPath: dbPath.path),
           let db = try? Database(readOnly: dbPath) {
            defer { db.close() }
            if let rows = try? db.rows(credentialQuery) {
                for row in rows where row.count >= 4 {
                    if let active = JSON.int(row[3]), active == 0 {
                        continue
                    }
                    let rawProvider = (row[0] as? String) ?? (row[1] as? String)
                    guard let provider = Providers.normalizeProvider(rawProvider),
                          let key = extractKey(from: row[2]), Accounts.validKey(key)
                    else { continue }
                    keys[provider] = key
                }
            }
        }
        return keys
    }

    private static func extractKey(from raw: Any?) -> String? {
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"), let obj = JSON.parseObject(Data(trimmed.utf8)) {
                return extractKeyFromObject(obj)
            }
            return trimmed.isEmpty ? nil : trimmed
        }
        if let obj = JSON.object(raw) {
            return extractKeyFromObject(obj)
        }
        return nil
    }

    private static func extractKeyFromObject(_ obj: JSONObject) -> String? {
        for field in ["key", "apiKey", "api_key", "token"] {
            if let val = obj.string(field)?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty {
                return val
            }
        }
        return nil
    }

    /// Reads BYOK provider keys (names only, never secret values) and model
    /// metadata (display names, context/output limits, prices) from `dbPath`
    /// into `sourceState["byok"]`.
    public static func scanBYOK(_ sourceState: inout JSONObject, dbPath: URL = opencodeDB, daily: JSONObject = [:]) {
        let credKeys = loadCredentialKeys(dbPath: dbPath)
        let providers = Providers.providers.map(\.key).filter { credKeys[$0] != nil }
        let usedModels = Set(UsageStats.modelsAllTime(daily).keys)
        var byok = sourceState.object("byok") ?? [:]
        var models = byok.object("models") ?? [:]

        if FileManager.default.fileExists(atPath: dbPath.path),
           let db = try? Database(readOnly: dbPath) {
            defer { db.close() }
            if let rows = try? db.rows(catalogQuery), let raw = rows.first?.first as? String,
               let wrapper = JSON.parseObject(Data(raw.utf8)) {
                let body: JSONObject?
                if let bodyStr = wrapper.string("body") {
                    body = JSON.parseObject(Data(bodyStr.utf8))
                } else {
                    body = wrapper.object("body")
                }
                if let catalog = body {
                    let wantedProviders = Set(providers)
                    for (vendorKey, vendorVal) in catalog {
                        let provider = Providers.normalizeProvider(vendorKey)
                        guard let vendorObj = JSON.object(vendorVal),
                              let vendorModels = vendorObj.object("models")
                        else { continue }
                        for (modelId, modelVal) in vendorModels {
                            let inferred = provider ?? Providers.providerOf(modelId)
                            let isWantedProvider = inferred.map(wantedProviders.contains) ?? false
                            guard isWantedProvider || usedModels.contains(modelId),
                                  let mObj = JSON.object(modelVal)
                            else { continue }
                            var entry = models.object(modelId) ?? [:]
                            if let name = CodexSource.nonEmpty(mObj.string("name")) {
                                entry["name"] = name
                            }
                            if let inferred = inferred {
                                entry["provider"] = inferred
                            }
                            if let limit = mObj.object("limit") {
                                let ctx = limit.int("context") ?? limit.int("input") ?? 0
                                let out = limit.int("output") ?? 0
                                if ctx > 0 { entry["context"] = ctx }
                                if out > 0 { entry["output"] = out }
                            }
                            if let textCost = mObj.object("cost")?.object("text") {
                                if let inPrice = textCost.object("input")?.double("price") {
                                    entry["input_price"] = inPrice
                                }
                                if let outPrice = textCost.object("output")?.double("price") {
                                    entry["output_price"] = outPrice
                                }
                                if let cacheRead = textCost.object("input")?.object("cache")?.double("read") {
                                    entry["cache_read_price"] = cacheRead
                                }
                            }
                            if !entry.isEmpty {
                                models[modelId] = entry
                            }
                        }
                    }
                }
            }
        }

        if providers.isEmpty && models.isEmpty && byok.isEmpty {
            return
        }
        byok["providers"] = providers
        byok["models"] = models
        sourceState["byok"] = byok
    }

    public static func byokState(_ state: JSONObject) -> JSONObject {
        state.object("sources")?.object("opencode")?.object("byok") ?? [:]
    }

    /// Canonical provider keys that have an active BYOK API key in opencode.
    public static func byokProviders(_ state: JSONObject) -> [String] {
        (byokState(state).array("providers") ?? []).compactMap(JSON.string)
    }

    /// Model metadata discovered from opencode's catalog or BYOK API keys:
    /// `{modelId: {"name", "provider", "context", "output", "input_price", "output_price", "cache_read_price"}}`.
    public static func byokModels(_ state: JSONObject) -> [String: JSONObject] {
        guard let raw = byokState(state).object("models") else { return [:] }
        var result = [String: JSONObject]()
        for (id, value) in raw {
            if let obj = JSON.object(value) {
                result[id] = obj
            }
        }
        return result
    }

    /// Prices per 1M tokens for models discovered via BYOK/opencode.
    public static func byokPrices(_ state: JSONObject) -> [String: Pricing.Price] {
        var prices = [String: Pricing.Price]()
        for (modelId, info) in byokModels(state) {
            guard let input = info.double("input_price"),
                  let output = info.double("output_price")
            else { continue }
            let cacheRead = info.double("cache_read_price") ?? (input * 0.1)
            prices[modelId] = Pricing.Price(input, output, cacheRead)
        }
        return prices
    }

    /// Merge live models/limits fetched with a BYOK API key into `state`.
    public static func storeBYOKFetch(_ state: inout JSONObject, provider: String, result: JSONObject) {
        var sources = state.object("sources") ?? [:]
        var opencode = sources.object("opencode") ?? [:]
        var byok = opencode.object("byok") ?? [:]
        var models = byok.object("models") ?? [:]
        if let fetchedModels = result.object("models") {
            for (modelId, value) in fetchedModels {
                guard let mObj = JSON.object(value) else { continue }
                var entry = models.object(modelId) ?? [:]
                for (k, v) in mObj {
                    entry[k] = v
                }
                entry["provider"] = provider
                models[modelId] = entry
            }
        }
        byok["models"] = models
        var fetched = byok.object("fetched") ?? [:]
        var providerInfo = fetched.object(provider) ?? [:]
        if JSON.truthy(result["error"]) {
            providerInfo["error"] = result["error"]
            providerInfo["attempted_at"] = result["fetched_at"]
        } else {
            providerInfo = result
            providerInfo["models"] = nil  // stored in byok["models"] above
            providerInfo["attempted_at"] = result["fetched_at"]
        }
        fetched[provider] = providerInfo
        byok["fetched"] = fetched
        opencode["byok"] = byok
        sources["opencode"] = opencode
        state["sources"] = sources
    }

    public static func opencodeDaily(_ sourceState: JSONObject) -> JSONObject {
        sourceState.object("daily") ?? [:]
    }

    public static func opencodeTotal(_ sourceState: JSONObject) -> Int {
        SourceFile.total(sourceState.object("daily") ?? [:])
    }

    static let liveQuery = """
        select id, directory, title,
               tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write,
               time_updated, time_idle, time_busy, parent_id, agent
        from session_v2
        where time_archived is null
        order by time_updated desc, id desc
    """

    /// Live session details for counted `opencode` entries, read from `session_v2`.
    /// Each `opencode` process in a folder is paired with the most recently
    /// updated non-archived top-level session in that folder (in pid order when
    /// multiple processes share one folder). A failed read returns what it can
    /// and never drops a session.
    public static func liveDetails(for entries: [SessionRules.Entry],
                                   dbPath: URL = opencodeDB) -> [Int32: SessionDetails] {
        let sessions = entries.filter { $0.counted && $0.tool == "opencode" }
        guard !sessions.isEmpty, FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? Database(readOnly: dbPath)
        else { return [:] }
        defer { db.close() }
        guard let rows = try? db.rows(liveQuery) else { return [:] }

        struct Row {
            var id: String
            var directory: String
            var title: String?
            var tokens: Int
            var updatedMs: Double
            var idleMs: Double
            var busyMs: Double
            var parentId: String?
            var agent: String?
        }

        func cleanPath(_ path: String) -> String {
            var trimmed = path
            while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
            return trimmed
        }

        var byFolder = [String: [Row]]()
        var childrenByParent = [String: [Row]]()
        for raw in rows where raw.count >= 9 {
            guard let id = raw[0] as? String, !id.isEmpty,
                  let dir = raw[1] as? String, !dir.isEmpty
            else { continue }
            let row = Row(id: id, directory: cleanPath(dir), title: ActiveSessions.oneLine(raw[2] as? String),
                          tokens: JSON.int(raw[3]) ?? 0, updatedMs: JSON.double(raw[4]) ?? 0,
                          idleMs: JSON.double(raw[5]) ?? 0, busyMs: JSON.double(raw[6]) ?? 0,
                          parentId: CodexSource.nonEmpty(raw[7] as? String),
                          agent: CodexSource.nonEmpty(raw[8] as? String))
            if let parent = row.parentId {
                childrenByParent[parent, default: []].append(row)
            } else {
                byFolder[row.directory, default: []].append(row)
            }
        }

        func runningSubagents(of sessionId: String, depth: Int = 1, seen: Set<String> = []) -> [Subagent] {
            guard depth <= 8, !seen.contains(sessionId) else { return [] }
            let nextSeen = seen.union([sessionId])
            var found = [Subagent]()
            for child in (childrenByParent[sessionId] ?? []).reversed() {
                if child.busyMs > 0 && child.busyMs > child.idleMs {
                    found.append(Subagent(id: child.id, type: child.agent ?? "subagent",
                                          description: child.title, depth: depth))
                    found += runningSubagents(of: child.id, depth: depth + 1, seen: nextSeen)
                }
            }
            return found
        }

        var details = [Int32: SessionDetails]()
        let folders = Set(sessions.compactMap { $0.folder.map(cleanPath) }).sorted()
        for folder in folders {
            let here = sessions.filter { $0.folder.map(cleanPath) == folder }.sorted { $0.pid < $1.pid }
            let available = byFolder[folder] ?? []
            for (position, entry) in here.enumerated() {
                guard position < available.count else {
                    details[entry.pid] = SessionDetails(state: .idle)
                    continue
                }
                let matched = available[position]
                var detail = SessionDetails(title: matched.title,
                                            subagents: runningSubagents(of: matched.id))
                if matched.tokens > 0 {
                    detail.tokens = matched.tokens
                    detail.log = dbPath.path
                }
                if matched.busyMs > 0 && matched.busyMs > matched.idleMs {
                    detail.state = .active
                    detail.since = matched.busyMs / 1000.0
                } else if matched.idleMs > 0 {
                    detail.state = .idle
                    detail.since = matched.idleMs / 1000.0
                } else if matched.updatedMs > 0 {
                    detail.state = .idle
                    detail.since = matched.updatedMs / 1000.0
                }
                details[entry.pid] = detail
            }
        }
        return details
    }

    /// A message's `data` column as a JSON object.
    static func decodeObject(_ value: Any) throws -> JSONObject {
        let data: Data?
        if let text = value as? String {
            data = Data(text.utf8)
        } else {
            data = value as? Data
        }
        guard let data = data, let object = JSON.parseObject(data) else {
            throw ReadError(description: "a message's data isn't a JSON object")
        }
        return object
    }

    /// A column value as a dictionary key (NULL included, as Python's None).
    static func hashable(_ value: Any) -> AnyHashable {
        (value as? AnyHashable) ?? AnyHashable(NSNull())
    }

    /// A read-only connection, opened as Python's
    /// `sqlite3.connect("file:...?mode=ro", uri=True)` opens it.
    final class Database {
        private var handle: OpaquePointer?

        init(readOnly path: URL) throws {
            let uri = URL(fileURLWithPath: path.path).absoluteString + "?mode=ro"
            let status = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            guard status == SQLITE_OK else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database file"
                close()
                throw ReadError(description: message)
            }
            // Python's sqlite3 waits up to 5 seconds for a lock by default.
            sqlite3_busy_timeout(handle, 5000)
        }

        func close() {
            if let handle = handle {
                sqlite3_close(handle)
            }
            handle = nil
        }

        private func error() -> ReadError {
            ReadError(description: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed")
        }

        /// Every row of `sql`, each column as Int, Double, String, Data or NSNull.
        func rows(_ sql: String) throws -> [[Any]] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error()
            }
            defer { sqlite3_finalize(statement) }
            var rows = [[Any]]()
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return rows
                }
                guard status == SQLITE_ROW else { throw error() }
                rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
            }
        }

        private func column(_ statement: OpaquePointer?, _ index: Int32) -> Any {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                return Int(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                return sqlite3_column_double(statement, index)
            case SQLITE_TEXT:
                guard let text = sqlite3_column_text(statement, index) else { return "" }
                let count = Int(sqlite3_column_bytes(statement, index))
                return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
            case SQLITE_BLOB:
                guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
            default:
                return NSNull()
            }
        }
    }
}
