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

    /// SQL for the value at `path` in the JSON `column` when its JSON type is
    /// one of `types` (`number` or `text`), else NULL: what the typed getters
    /// (`int`, `double`, `string`) would read from the parsed object. SQLite
    /// picks the fields out, so a message's text (most of its `data`, many
    /// megabytes in all) is never copied into the app.
    static func typed(_ column: String, _ path: String, _ types: String) -> String {
        "case when json_type(\(column), '\(path)') in (\(types)) then json_extract(\(column), '\(path)') end"
    }

    static let number = "'integer', 'real'"
    static let text = "'text'"

    /// One row per message with tokens: created (ms); input, output,
    /// reasoning, cache read, cache write; model id, variant, effort; cost;
    /// folder; session id.
    static let query = """
        select \(typed("m.data", "$.time.created", number)),
               \(typed("m.data", "$.tokens.input", number)),
               \(typed("m.data", "$.tokens.output", number)),
               \(typed("m.data", "$.tokens.reasoning", number)),
               \(typed("m.data", "$.tokens.cache.read", number)),
               \(typed("m.data", "$.tokens.cache.write", number)),
               \(typed("m.data", "$.model.id", text)),
               \(typed("m.data", "$.model.variant", text)),
               \(typed("m.data", "$.model.effort", text)),
               \(typed("m.data", "$.cost", number)),
               s.directory, m.session_id
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
            let parts = self.parts([
                "input": row[1], "output": row[2], "reasoning": row[3],
                "cache": ["read": row[4], "write": row[5]] as JSONObject,
            ])
            guard let created = JSON.double(row[0]), created != 0,
                  parts.values.reduce(0, +) != 0
            else { continue }
            let model = CodexSource.nonEmpty(row[6] as? String) ?? "unknown"
            let effort = UsageStats.normalizeEffort(row[7]) ?? UsageStats.normalizeEffort(row[8])
            let cost = JSON.double(row[9])
            UsageStats.addUsage(&daily, day: Day(timestamp: created / 1000), model: model,
                                project: UsageStats.projectLabel(row[10] as? String), parts: parts, cost: cost,
                                effort: effort, at: created / 1000)
            var seen = counted[hashable(row[11])] ?? Counted()
            for (category, count) in parts {
                seen.parts[category, default: 0] += count
            }
            seen.cost += cost ?? 0.0
            counted[hashable(row[11])] = seen
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

    /// When opencode last wrote its model catalog (fails on older databases
    /// whose `kv` has no `time_updated`).
    static let catalogUpdatedQuery = """
        select time_updated from kv where key = 'models-dev:v2:catalog'
    """

    /// The catalog row, to read its value a piece at a time (see
    /// `OpencodeCatalog`).
    static let catalogRowQuery = """
        select rowid from kv where key = 'models-dev:v2:catalog'
    """

    /// What the catalog step last ran on, by database path, so it runs again
    /// only when the catalog or what it is read for changed: reading the
    /// catalog takes far more memory and time than the rest of a scan.
    private static var catalogRuns = [String: String]()
    private static let catalogRunsLock = NSLock()

    private static func lastCatalogRun(_ path: String) -> String? {
        catalogRunsLock.lock()
        defer { catalogRunsLock.unlock() }
        return catalogRuns[path]
    }

    private static func noteCatalogRun(_ path: String, _ key: String?) {
        catalogRunsLock.lock()
        defer { catalogRunsLock.unlock() }
        catalogRuns[path] = key
    }

    /// What the catalog step's result depends on; nil (always run) when the
    /// catalog's update time can't be read.
    static func catalogRunKey(updated: Int?, providers: [String], usedModels: Set<String>,
                              knownModels: Int) -> String? {
        guard let updated = updated else { return nil }
        return "\(updated)|\(providers.sorted())|\(usedModels.sorted())|\(knownModels)"
    }

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
            let updated = (try? db.rows(catalogUpdatedQuery))?.first?.first.flatMap(JSON.int)
            let before = catalogRunKey(updated: updated, providers: providers, usedModels: usedModels,
                                       knownModels: models.count)
            let lastRun = lastCatalogRun(dbPath.path)
            if before == nil || before != lastRun, let catalog = db.catalogModels() {
                let wantedProviders = Set(providers)
                // Model IDs can collide across integrations. Resolve ownership
                // across the entire catalog before filtering to tracked entries.
                var owners = [String: Set<String>]()
                for model in catalog {
                    // An integration that can't place the ID casts no vote.
                    if let owner = Providers.catalogProvider(model: model.id, integration: model.vendor) {
                        owners[model.id, default: []].insert(owner)
                    }
                }
                for model in catalog where model.isObject {
                    let modelId = model.id
                    let candidates = owners[modelId] ?? []
                    let inferred = candidates.count == 1 ? candidates.first : nil
                    let isWantedProvider = inferred.map(wantedProviders.contains) ?? false
                    guard isWantedProvider || usedModels.contains(modelId) else { continue }
                    var entry = models.object(modelId) ?? [:]
                    if let name = CodexSource.nonEmpty(model.name) {
                        entry["name"] = name
                    }
                    entry["provider"] = inferred
                    entry["provider_ambiguous"] = candidates.count > 1
                    let ctx = JSON.int(model.context) ?? JSON.int(model.input) ?? 0
                    let out = JSON.int(model.output) ?? 0
                    if ctx > 0 { entry["context"] = ctx }
                    if out > 0 { entry["output"] = out }
                    if let inPrice = model.inputPrice {
                        entry["input_price"] = inPrice
                    }
                    if let outPrice = model.outputPrice {
                        entry["output_price"] = outPrice
                    }
                    if let cacheRead = model.cacheReadPrice {
                        entry["cache_read_price"] = cacheRead
                    }
                    if !entry.isEmpty {
                        models[modelId] = entry
                    }
                }
                let after = catalogRunKey(updated: updated, providers: providers, usedModels: usedModels,
                                          knownModels: models.count)
                noteCatalogRun(dbPath.path, after)
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
            // Each scan reads the whole database once: a small page cache
            // does as well as the default 2 MB-and-growing one, in less memory.
            sqlite3_exec(handle, "pragma cache_size = -512", nil, nil, nil)
        }

        func close() {
            if let handle = handle {
                sqlite3_close(handle)
            }
            handle = nil
        }

        /// opencode's model catalog, read a piece at a time (see
        /// `OpencodeCatalog`): [] when there is none, nil when it can't be
        /// read or isn't valid JSON.
        func catalogModels() -> [OpencodeCatalog.Model]? {
            guard let rows = try? self.rows(catalogRowQuery) else { return nil }
            guard let rowid = rows.first?.first.flatMap(JSON.int) else { return [] }
            var blob: OpaquePointer?
            guard sqlite3_blob_open(handle, "main", "kv", "value", Int64(rowid), 0, &blob) == SQLITE_OK,
                  let opened = blob
            else {
                sqlite3_blob_close(blob)
                return nil
            }
            return OpencodeCatalog.models(BlobSource(opened))
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

    /// A database value read 64 KB at a time; closed when released.
    final class BlobSource: ByteSource {
        private let blob: OpaquePointer
        private let size: Int32
        private var offset: Int32 = 0
        private var buffer = [UInt8](repeating: 0, count: 1 << 16)
        private var count = 0
        private var index = 0

        init(_ blob: OpaquePointer) {
            self.blob = blob
            size = sqlite3_blob_bytes(blob)
        }

        deinit {
            sqlite3_blob_close(blob)
        }

        func next() throws -> UInt8? {
            if index == count {
                guard offset < size else { return nil }
                let want = min(Int32(buffer.count), size - offset)
                let status = buffer.withUnsafeMutableBytes { sqlite3_blob_read(blob, $0.baseAddress, want, offset) }
                guard status == SQLITE_OK else { throw ReadError(description: "the model catalog couldn't be read") }
                offset += want
                count = Int(want)
                index = 0
            }
            defer { index += 1 }
            return buffer[index]
        }
    }
}
