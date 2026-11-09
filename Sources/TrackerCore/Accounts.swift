import Foundation

/// Optional account numbers from each provider's own API, using an API key
/// the user adds in Settings.
///
/// Privacy:
/// - Keys are kept only in the macOS Keychain. They are written through
///   `security -i` on stdin, so they never appear in a process list, and are
///   never stored in state.json or logged.
/// - A key is sent only over HTTPS, only to its own provider's API hosts
///   (allowedHosts), and redirects are not followed.
/// - Only usage numbers and balances are requested.
///
/// What a key gives:
/// - OpenAI admin key (sk-admin-...): daily tokens per model and billed cost.
/// - Kimi admin key (sk-admin-...): daily tokens per model, balance, total spent.
/// - Kimi API key: balance. DeepSeek API key: balance (DeepSeek has no usage
///   history API).
public enum Accounts {
    public static let keychainService = "com.raymondtian.claudetracker.apikey"
    public static let allowedHosts: [String: Set<String>] = [
        "openai": ["api.openai.com"],
        "deepseek": ["api.deepseek.com"],
        "kimi": ["api.moonshot.ai", "api.moonshot.cn"],
    ]
    public static let names = ["openai": "OpenAI", "deepseek": "DeepSeek", "kimi": "Kimi"]
    public static let refreshSeconds = 15.0 * 60
    public static let windowDays = 30
    public static let maxPages = 10
    public static let accountProject = "Account"  // account APIs don't say which folder a call came from
    public static let milliCentsPerDollar = 100_000.0

    public static let keyHelp = [
        "openai": "Needs an admin key (sk-admin-…) for usage and cost",
        "deepseek": "An API key shows your balance",
        "kimi": "An API key shows your balance; an admin key also shows usage",
    ]

    /// Fetches a provider API's JSON for a URL, sending `key`.
    public typealias Get = (_ url: String, _ key: String) throws -> Any

    /// A key that doesn't look like an API key (Python's ValueError).
    public struct InvalidKey: Error, LocalizedError, CustomStringConvertible {
        public let description = "That doesn't look like an API key."
        public var errorDescription: String? { description }
    }

    /// The Keychain didn't keep a key (Python's OSError).
    public struct KeychainError: Error, LocalizedError, CustomStringConvertible {
        public let description = "The key couldn't be saved to the Keychain."
        public var errorDescription: String? { description }
    }

    // MARK: - Keychain

    /// 8 to 512 of A-Z, a-z, 0-9, ".", "_" and "-". Nothing else can reach
    /// the `security -i` command line, so a key can't add commands to it.
    /// (Python's `$` also let one trailing newline through; save_key strips
    /// it first, so being strict here changes nothing.)
    public static func validKey(_ key: String?) -> Bool {
        guard let key = key, (8...512).contains(key.utf8.count) else { return false }
        return key.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    public static func loadKey(_ provider: String, run: Subprocess.Runner = Subprocess.run) -> String? {
        let result = run(["security", "find-generic-password", "-s", keychainService, "-a", provider, "-w"],
                         nil)
        if result.status != 0 {
            return nil
        }
        let key = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Store `key` in the Keychain. Throws InvalidKey for a malformed key and
    /// KeychainError if the Keychain didn't keep it.
    public static func saveKey(_ provider: String, _ key: String?,
                               run: Subprocess.Runner = Subprocess.run) throws {
        let key = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !validKey(key) {
            throw InvalidKey()
        }
        _ = run(["security", "-i"],
                "add-generic-password -U -s \(keychainService) -a \(provider) -w \(key)\n")
        if loadKey(provider, run: run) != key {
            throw KeychainError()
        }
    }

    public static func deleteKey(_ provider: String, run: Subprocess.Runner = Subprocess.run) {
        _ = run(["security", "delete-generic-password", "-s", keychainService, "-a", provider], nil)
    }

    // MARK: - HTTP

    /// GETs `url` with `key`. Refuses (before sending anything) unless it's
    /// HTTPS to one of `provider`'s own hosts.
    public static func httpGetJSON(_ url: String, key: String, provider: String,
                                   send: HTTP.Send = HTTP.send) throws -> Any {
        let parsed = URL(string: url)
        let host = parsed.flatMap { HTTP.host(of: $0) }
        let scheme = parsed?.scheme?.lowercased() ?? ""
        guard let parsed = parsed, scheme == "https", let allowed = host,
              allowedHosts[provider]?.contains(allowed) == true
        else {
            throw HTTP.RefusedURL(description:
                "refusing to send a \(provider) key to \(scheme)://\(host ?? "None")")
        }
        var request = URLRequest(url: parsed, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeTracker/\(Version.version)", forHTTPHeaderField: "User-Agent")
        // A redirect becomes an HTTP error; the key never follows it.
        return try HTTP.json(send(request, false))
    }

    // MARK: - Helpers

    /// Local midnight at the start of the 30-day window ending `today`.
    static func windowStart(_ today: Day) -> Double {
        let start = today.adding(days: -(windowDays - 1))
        return LocalTime.timestamp(start.year, start.month, start.day)
    }

    /// Python's `f"{symbol}{float(amount):,.2f}"`.
    static func money(_ amount: Any?, _ symbol: String) throws -> String {
        let value = try number(amount)
        var text = String(format: "%.2f", value)
        var sign = ""
        if text.hasPrefix("-") {
            sign = "-"
            text.removeFirst()
        }
        let parts = text.split(separator: ".", maxSplits: 1)
        var whole = String(parts[0])
        var grouped = ""
        while whole.count > 3 {
            grouped = "," + whole.suffix(3) + grouped
            whole = String(whole.dropLast(3))
        }
        return "\(symbol)\(sign)\(whole)\(grouped).\(parts[1])"
    }

    /// Python's `float(value)` of a JSON number or numeric string.
    static func number(_ value: Any?) throws -> Double {
        if let number = JSON.double(value) {
            return number
        }
        if let text = value as? String,
           let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return number
        }
        throw HTTP.UnexpectedAnswer(description: "not a number: \(String(describing: value))")
    }

    /// A token count: missing or null is 0, as `value or 0` reads it.
    private static func count(_ value: Any?) throws -> Int {
        if JSON.isNull(value) {
            return 0
        }
        guard let count = JSON.int(value) else {
            throw HTTP.UnexpectedAnswer(description: "not a count: \(String(describing: value))")
        }
        return count
    }

    /// Account APIs count cached tokens inside the prompt; split them out so
    /// totals match the provider's own.
    static func parts(_ prompt: Any?, _ cached: Any?, _ completion: Any?) throws -> [String: Int] {
        let cached = try count(cached)
        return [
            "input": max(try count(prompt) - cached, 0),
            "output": try count(completion),
            "cache_write_5m": 0,
            "cache_write_1h": 0,
            "cache_read": cached,
        ]
    }

    static func describe(_ error: Error, _ name: String) -> String {
        if let error = error as? HTTP.StatusError {
            if error.code == 401 || error.code == 403 {
                return "the API key was rejected (HTTP \(error.code))"
            }
            if error.code == 429 {
                return "\(name) is rate limiting requests; will retry"
            }
            return "\(name) answered HTTP \(error.code)"
        }
        if let error = error as? HTTP.ConnectionError {  // e.g. a timeout while reading the answer
            return "couldn't reach \(name) (\(error.reason))"
        }
        return "\(name) sent an unexpected response"
    }

    /// Python's `urlencode(query, doseq=True)`: `quote_plus` on each part.
    static func urlencode(_ query: [(String, String)]) -> String {
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~ ")
        func quotePlus(_ text: String) -> String {
            (text.addingPercentEncoding(withAllowedCharacters: safe) ?? text)
                .replacingOccurrences(of: " ", with: "+")
        }
        return query.map { "\(quotePlus($0.0))=\(quotePlus($0.1))" }.joined(separator: "&")
    }

    /// Calls `body` with each page's JSON, following the API's cursor.
    static func pages(_ get: Get, _ key: String, _ base: String, _ params: [(String, String)],
                      cursorParam: String, nextField: String,
                      _ body: (JSONObject) throws -> Void) throws {
        var cursor: Any?
        for _ in 0..<maxPages {
            var query = params
            if JSON.truthy(cursor) {
                query.append((cursorParam, cursor.map { "\($0)" } ?? ""))
            }
            guard let page = JSON.object(try get("\(base)?\(urlencode(query))", key)) else {
                throw HTTP.UnexpectedAnswer(description: "a page isn't an object")
            }
            try body(page)
            cursor = page[nextField]
            if !JSON.truthy(page["has_more"]) || !JSON.truthy(cursor) {
                return
            }
        }
    }

    /// `value[key]` that must be there (Python's KeyError otherwise).
    private static func field(_ value: Any?, _ key: String) throws -> Any {
        guard let object = JSON.object(value), let found = object[key] else {
            throw HTTP.UnexpectedAnswer(description: "missing \(key)")
        }
        return found
    }

    private static func list(_ value: Any?) throws -> [Any] {
        guard let list = JSON.array(value) else {
            throw HTTP.UnexpectedAnswer(description: "not a list")
        }
        return list
    }

    /// `row.get(key) or "unknown"`.
    private static func modelName(_ value: Any?) -> String {
        JSON.truthy(value) ? (value as? String ?? "\(value!)") : "unknown"
    }

    static func emptyResult() -> JSONObject {
        // has_usage: whether this key's API reports token usage (not just a balance)
        ["daily": JSONObject(), "cost": JSONObject(), "rows": [Any](), "notes": [Any](),
         "error": NSNull(), "has_usage": false]
    }

    // MARK: - Providers

    private static func fetchOpenAI(_ key: String, _ today: Day, _ now: Double, _ get: Get) throws -> JSONObject {
        var result = emptyResult()
        if !key.hasPrefix("sk-admin-") {
            result["error"] = "usage needs an admin key (sk-admin-…), from "
                + "platform.openai.com → Settings → Admin keys"
            return result
        }
        result["has_usage"] = true
        let start = String(Int(windowStart(today)))
        var daily = JSONObject()
        try pages(get, key, "https://api.openai.com/v1/organization/usage/completions",
                  [("start_time", start), ("bucket_width", "1d"), ("limit", "31"), ("group_by", "model")],
                  cursorParam: "page", nextField: "next_page") { page in
            for bucket in try list(field(page, "data")) {
                let day = Day(timestamp: try number(field(bucket, "start_time")))
                for row in try list(field(bucket, "results")) {
                    let row = JSON.object(row)
                    let parts = try parts(row?["input_tokens"], row?["input_cached_tokens"],
                                          row?["output_tokens"])
                    if parts.values.reduce(0, +) != 0 {
                        UsageStats.addUsage(&daily, day: day, model: modelName(row?["model"]),
                                            project: accountProject, parts: parts)
                    }
                }
            }
        }
        result["daily"] = daily
        var cost = JSONObject()
        var notes: [Any] = []
        do {
            try pages(get, key, "https://api.openai.com/v1/organization/costs",
                      [("start_time", start), ("bucket_width", "1d"), ("limit", "31")],
                      cursorParam: "page", nextField: "next_page") { page in
                for bucket in try list(field(page, "data")) {
                    let iso = Day(timestamp: try number(field(bucket, "start_time"))).iso
                    for row in try list(field(bucket, "results")) {
                        let amount = try number(field(field(row, "amount"), "value"))
                        cost[iso] = (cost.double(iso) ?? 0.0) + amount
                    }
                }
            }
        } catch {
            cost = [:]
            notes.append("Billed cost unavailable: \(describe(error, "OpenAI"))")
        }
        result["cost"] = cost
        result["notes"] = notes
        return result
    }

    private static func fetchDeepSeek(_ key: String, _ today: Day, _ now: Double, _ get: Get) throws -> JSONObject {
        var result = emptyResult()
        let data = try get("https://api.deepseek.com/user/balance", key)
        var rows: [Any] = []
        for info in try list(field(data, "balance_infos")) {
            let currency = try field(info, "currency")
            let symbol = ["CNY": "¥", "USD": "$"][currency as? String ?? ""] ?? "\(currency) "
            rows += [
                ["Balance", try money(field(info, "total_balance"), symbol)],
                ["Granted", try money(field(info, "granted_balance"), symbol)],
                ["Topped up", try money(field(info, "topped_up_balance"), symbol)],
            ]
        }
        result["rows"] = rows
        var notes: [Any] = []
        if !JSON.truthy(try field(data, "is_available")) {
            notes.append("Balance too low for API calls")
        }
        notes.append("DeepSeek's API reports balance only, not usage history")
        result["notes"] = notes
        return result
    }

    private static func fetchKimi(_ key: String, _ today: Day, _ now: Double, _ get: Get) throws -> JSONObject {
        var result = emptyResult()
        if key.hasPrefix("sk-admin-") {
            result["has_usage"] = true
            let base = "https://api.moonshot.ai/v1/admin/organizations"
            let params = [("start", String(Int(windowStart(today) * 1000))),
                          ("end", String(Int(now * 1000))), ("granularity", "1d"), ("limit", "1000")]
            var daily = JSONObject()
            try pages(get, key, "\(base)/usage/completions", params,
                      cursorParam: "cursor", nextField: "next") { page in
                for row in try list(field(page, "data")) {
                    let object = JSON.object(row)
                    let parts = try parts(object?["prompt_tokens"], object?["cached_tokens"],
                                          object?["completion_tokens"])
                    if parts.values.reduce(0, +) != 0 {
                        guard let bucketTime = try field(row, "bucket_time") as? String,
                              let day = Day(iso: String(bucketTime.prefix(10)))
                        else { throw HTTP.UnexpectedAnswer(description: "bad bucket_time") }
                        UsageStats.addUsage(&daily, day: day, model: modelName(object?["model_id"]),
                                            project: accountProject, parts: parts)
                    }
                }
            }
            result["daily"] = daily
            let account = try get("\(base)/account", key)
            result["rows"] = [
                ["Balance", try money(number(field(account, "available_balance")) / milliCentsPerDollar, "$")],
                ["Total spent", try money(number(field(account, "total_consume")) / milliCentsPerDollar, "$")],
            ]
            return result
        }

        // Ordinary API key: balance. Keys from Kimi's China platform only work on
        // the .cn host.
        let data: Any
        let symbol: String
        do {
            data = try field(get("https://api.moonshot.ai/v1/users/me/balance", key), "data")
            symbol = "$"
        } catch let error as HTTP.StatusError where error.code == 401 {
            data = try field(get("https://api.moonshot.cn/v1/users/me/balance", key), "data")
            symbol = "¥"
        }
        result["rows"] = [
            ["Balance", try money(field(data, "available_balance"), symbol)],
            ["Vouchers", try money(field(data, "voucher_balance"), symbol)],
            ["Cash", try money(field(data, "cash_balance"), symbol)],
        ]
        result["notes"] = ["An admin key (sk-admin-…) also shows usage history"]
        return result
    }

    private static let fetchers: [String: (String, Day, Double, Get) throws -> JSONObject] = [
        "openai": fetchOpenAI, "deepseek": fetchDeepSeek, "kimi": fetchKimi,
    ]

    /// {"daily", "cost": {iso: usd}, "rows": [[label, value]], "notes",
    /// "error", "has_usage", "fetched_at"} for `provider`'s account. Never throws.
    public static func fetchAccount(_ provider: String, _ key: String, today: Day? = nil,
                                    get: Get? = nil,
                                    now: Double = Date().timeIntervalSince1970) -> JSONObject {
        let get = get ?? { url, key in try httpGetJSON(url, key: key, provider: provider) }
        let name = names[provider] ?? provider
        var result: JSONObject
        do {
            guard let fetcher = fetchers[provider] else {
                throw HTTP.UnexpectedAnswer(description: "unknown provider \(provider)")
            }
            result = try fetcher(key, today ?? Day.today(now: now), now, get)
        } catch {
            result = emptyResult()
            result["error"] = describe(error, name)
        }
        result["fetched_at"] = isoSeconds(now)
        return result
    }

    /// Python's `datetime.now().isoformat(timespec="seconds")`: local, no zone.
    static func isoSeconds(_ timestamp: Double) -> String {
        let parts = LocalTime.parts(of: timestamp)
        return "\(parts.day.iso)T" + String(format: "%02d:%02d:%02d", parts.hour, parts.minute, parts.second)
    }

    /// Save a fetch into state["accounts"]. A failed fetch keeps the last good
    /// numbers and records the error.
    public static func storeResult(_ state: inout JSONObject, _ provider: String, _ result: JSONObject) {
        var accounts = state.object("accounts") ?? [:]
        var saved = accounts.object(provider) ?? [:]
        if JSON.truthy(result["error"]) {
            saved["error"] = result["error"]
            saved["attempted_at"] = result["fetched_at"]
        } else {
            saved = result
            saved["attempted_at"] = result["fetched_at"]
        }
        accounts[provider] = saved
        state["accounts"] = accounts
    }

    public static func accountDue(_ saved: JSONObject?, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let saved = saved, !saved.isEmpty, JSON.truthy(saved["attempted_at"]),
              let attempted = saved.string("attempted_at"), let last = LocalTime.parseISO(attempted)
        else { return true }
        return now - last >= refreshSeconds
    }
}
