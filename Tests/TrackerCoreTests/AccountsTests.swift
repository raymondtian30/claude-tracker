// Ported from tests/test_accounts.py, test for test.
//
// Python's urllib HTTPError is `HTTP.StatusError` here and TimeoutError is
// `HTTP.ConnectionError`; ValueError and OSError from save_key are
// `Accounts.InvalidKey` and `Accounts.KeychainError`.

import Foundation
import Testing
@testable import TrackerCore

private let TODAY = Day(2026, 11, 8)

/// What a fake API route answers: a JSON value, an error, or a JSON value
/// worked out from the query.
private enum Route {
    case json(Any)
    case error(Error)
    case query(([String: [String]]) -> Any)
}

/// Answers GETs by path; records every (host, path, query, key).
private final class FakeApi {
    struct Call {
        let host: String
        let path: String
        let query: [String: [String]]
        let key: String
    }

    var routes: [String: Route]
    var calls: [Call] = []

    init(_ routes: [String: Route]) {
        self.routes = routes
    }

    /// Python's `parse_qs`.
    static func parseQuery(_ components: URLComponents) -> [String: [String]] {
        var query: [String: [String]] = [:]
        for item in components.queryItems ?? [] {
            query[item.name, default: []].append(item.value ?? "")
        }
        return query
    }

    func get(_ url: String, _ key: String) throws -> Any {
        let components = URLComponents(string: url)!
        let query = FakeApi.parseQuery(components)
        calls.append(Call(host: components.host ?? "", path: components.path, query: query, key: key))
        guard let route = routes["\(components.host ?? "") \(components.path)"] else {
            throw HTTP.UnexpectedAnswer(description: "KeyError: no route for \(url)")
        }
        switch route {
        case .json(let answer): return answer
        case .error(let error): throw error
        case .query(let answer): return answer(query)
        }
    }
}

private func httpError(_ code: Int) -> Route {
    .error(HTTP.StatusError(code: code))
}

/// A fake `security` that records each (args, input).
private final class FakeSecurity {
    var calls: [([String], String?)] = []
    let answer: ([String]) -> Subprocess.Result

    init(_ answer: @escaping ([String]) -> Subprocess.Result) {
        self.answer = answer
    }

    func run(_ args: [String], _ input: String?) -> Subprocess.Result {
        calls.append((args, input))
        return answer(args)
    }
}

// MARK: - keys

@Test func validKey() {
    #expect(Accounts.validKey("sk-admin-AbC_12.3-xyz"))
    #expect(!Accounts.validKey("short"))
    #expect(!Accounts.validKey("has space in it"))
    #expect(!Accounts.validKey("quote\"injection-attempt"))
    #expect(!Accounts.validKey("new\nline-injection"))
}

@Test func saveKeySendsItOnStdinNotArgv() throws {
    let security = FakeSecurity { args in
        if Array(args.prefix(2)) == ["security", "find-generic-password"] {
            return Subprocess.Result(status: 0, stdout: "sk-test-1234567890\n")
        }
        return Subprocess.Result(status: 0, stdout: "")
    }

    try Accounts.saveKey("deepseek", "sk-test-1234567890", run: security.run)

    let (args, input) = security.calls[0]
    #expect(args == ["security", "-i"])
    #expect(!args.joined(separator: " ").contains("sk-test-1234567890"))
    #expect(input == "add-generic-password -U -s com.raymondtian.claudetracker.apikey "
        + "-a deepseek -w sk-test-1234567890\n")
}

@Test func saveKeyRejectsInvalidKeysWithoutRunningAnything() {
    #expect(throws: Accounts.InvalidKey.self) {
        try Accounts.saveKey("kimi", "bad key", run: { _, _ in
            Issue.record("ran")
            return Subprocess.Result()
        })
    }
}

@Test func saveKeyFailsIfKeychainDidNotStoreIt() {
    let run: Subprocess.Runner = { args, _ in
        Subprocess.Result(status: args[1] == "-i" ? 0 : 44, stdout: "")
    }
    #expect(throws: Accounts.KeychainError.self) {
        try Accounts.saveKey("kimi", "sk-test-1234567890", run: run)
    }
}

@Test func loadAndDeleteKey() {
    let security = FakeSecurity { _ in Subprocess.Result(status: 0, stdout: "sk-abc-1234567890\n") }

    #expect(Accounts.loadKey("openai", run: security.run) == "sk-abc-1234567890")
    Accounts.deleteKey("openai", run: security.run)
    #expect(security.calls.map(\.0) == [
        ["security", "find-generic-password", "-s", "com.raymondtian.claudetracker.apikey",
         "-a", "openai", "-w"],
        ["security", "delete-generic-password", "-s", "com.raymondtian.claudetracker.apikey",
         "-a", "openai"],
    ])
}

@Test func loadKeyMissing() {
    #expect(Accounts.loadKey("openai", run: { _, _ in Subprocess.Result(status: 44, stdout: "") }) == nil)
}

// MARK: - OpenAI

private func ts(_ day: Day) -> Int {
    Int(LocalTime.timestamp(day.year, day.month, day.day))
}

private func openaiRoutes() -> [String: Route] {
    let usagePages: [String: JSONObject] = [
        "": ["data": [["start_time": ts(Day(2026, 11, 7)), "results": [
            ["model": "gpt-5", "input_tokens": 100, "input_cached_tokens": 60, "output_tokens": 9],
        ]]], "has_more": true, "next_page": "p2"],
        "p2": ["data": [["start_time": ts(TODAY), "results": [
            ["model": "gpt-5", "input_tokens": 10, "input_cached_tokens": 0, "output_tokens": 1],
            ["model": NSNull(), "input_tokens": 4, "output_tokens": 0],
        ]]], "has_more": false, "next_page": NSNull()],
    ]
    let costs: JSONObject = ["data": [
        ["start_time": ts(Day(2026, 11, 7)), "results": [["amount": ["value": 1.25, "currency": "usd"]]]],
        ["start_time": ts(TODAY), "results": [["amount": ["value": 0.5, "currency": "usd"]],
                                              ["amount": ["value": 0.25, "currency": "usd"]]]],
    ], "has_more": false, "next_page": NSNull()]
    return [
        "api.openai.com /v1/organization/usage/completions":
            .query { q in usagePages[q["page"]?.first ?? ""]! },
        "api.openai.com /v1/organization/costs": .json(costs),
    ]
}

@Test func openaiAdminKeyGivesDailyTokensAndBilledCost() {
    let api = FakeApi(openaiRoutes())

    let result = Accounts.fetchAccount("openai", "sk-admin-1234567890", today: TODAY, get: api.get)

    #expect(JSON.isNull(result["error"]))
    let nov7 = dig(result, "daily", "2026-11-07", "models", "gpt-5") as? JSONObject ?? [:]
    #expect([nov7.int("input"), nov7.int("cache_read"), nov7.int("output")] == [40, 60, 9])
    #expect(JSON.int(dig(result, "daily", "2026-11-08", "models", "unknown", "input")) == 4)
    #expect(jsonEqual(result["cost"], ["2026-11-07": 1.25, "2026-11-08": 0.75]))
    let usageCall = api.calls[0]
    #expect(usageCall.query["bucket_width"] == ["1d"])
    #expect(usageCall.query["group_by"] == ["model"])
    #expect(usageCall.query["start_time"] == [String(ts(Day(2026, 10, 10)))])
}

@Test func openaiNeedsAnAdminKeyAndSendsNothingOtherwise() {
    let api = FakeApi([:])

    let result = Accounts.fetchAccount("openai", "sk-proj-1234567890", today: TODAY, get: api.get)

    #expect(result.string("error")?.contains("admin key") == true)
    #expect(api.calls.isEmpty)
}

@Test func openaiCostFailureKeepsUsage() {
    var routes = openaiRoutes()
    routes["api.openai.com /v1/organization/costs"] = httpError(404)

    let result = Accounts.fetchAccount("openai", "sk-admin-1234567890", today: TODAY,
                                       get: FakeApi(routes).get)

    #expect(JSON.isNull(result["error"]))
    #expect(JSON.truthy(result["daily"]))
    #expect(jsonEqual(result["cost"], JSONObject()))
    #expect((result.array("notes") ?? []).contains { ($0 as? String)?.lowercased().contains("cost") == true })
}

// MARK: - DeepSeek

@Test func deepseekBalance() {
    let api = FakeApi(["api.deepseek.com /user/balance": .json([
        "is_available": false,
        "balance_infos": [["currency": "CNY", "total_balance": "110.00",
                           "granted_balance": "10.00", "topped_up_balance": "100.00"]],
    ] as JSONObject)])

    let result = Accounts.fetchAccount("deepseek", "sk-1234567890", today: TODAY, get: api.get)

    #expect(JSON.isNull(result["error"]))
    #expect(jsonEqual(result["daily"], JSONObject()))
    #expect(jsonEqual(result["rows"], [["Balance", "¥110.00"], ["Granted", "¥10.00"], ["Topped up", "¥100.00"]]))
    #expect(jsonEqual(result["notes"], ["Balance too low for API calls",
                                        "DeepSeek's API reports balance only, not usage history"]))
}

// MARK: - Kimi

@Test func kimiApiKeyBalance() {
    let api = FakeApi(["api.moonshot.ai /v1/users/me/balance": .json([
        "code": 0, "data": ["available_balance": 49.58894, "voucher_balance": 46.58893,
                            "cash_balance": 3.00001], "status": true,
    ] as JSONObject)])

    let result = Accounts.fetchAccount("kimi", "sk-1234567890", today: TODAY, get: api.get)

    #expect(jsonEqual(result["rows"], [["Balance", "$49.59"], ["Vouchers", "$46.59"], ["Cash", "$3.00"]]))
    #expect(jsonEqual(result["daily"], JSONObject()))
}

@Test func kimiChinaKeyFallsBackToTheCnHost() {
    let api = FakeApi([
        "api.moonshot.ai /v1/users/me/balance": httpError(401),
        "api.moonshot.cn /v1/users/me/balance": .json([
            "code": 0, "data": ["available_balance": 10, "voucher_balance": 0, "cash_balance": 10]
        ] as JSONObject),
    ])

    let result = Accounts.fetchAccount("kimi", "sk-1234567890", today: TODAY, get: api.get)

    #expect(JSON.isNull(result["error"]))
    #expect(jsonEqual(result.array("rows")?.first, ["Balance", "¥10.00"]))
}

@Test func kimiAdminKeyGivesUsageAndSpend() {
    let pages: [String: JSONObject] = [
        "": ["data": [
            ["bucket_time": "2026-11-07T00:00:00Z", "model_id": "kimi-k2", "prompt_tokens": 50,
             "completion_tokens": 5, "cached_tokens": 20],
            ["bucket_time": "2026-11-07T00:00:00Z", "model_id": "kimi-k2", "prompt_tokens": 10,
             "completion_tokens": 1, "cached_tokens": 0],
        ], "has_more": true, "next": "c2"],
        "c2": ["data": [["bucket_time": "2026-11-08T00:00:00Z", "model_id": "kimi-k2",
                         "prompt_tokens": 3, "completion_tokens": 2, "cached_tokens": 0]],
               "has_more": false, "next": NSNull()],
    ]
    let api = FakeApi([
        "api.moonshot.ai /v1/admin/organizations/usage/completions":
            .query { q in pages[q["cursor"]?.first ?? ""]! },
        "api.moonshot.ai /v1/admin/organizations/account": .json([
            "available_balance": 4_958_894, "total_consume": 1_250_000,
            "total_recharge_amount": 0, "total_voucher_amount": 0] as JSONObject),
    ])

    let result = Accounts.fetchAccount("kimi", "sk-admin-1234567890", today: TODAY, get: api.get)

    let nov7 = dig(result, "daily", "2026-11-07", "models", "kimi-k2") as? JSONObject ?? [:]
    #expect([nov7.int("input"), nov7.int("cache_read"), nov7.int("output")] == [40, 20, 6])
    #expect(jsonEqual(result["rows"], [["Balance", "$49.59"], ["Total spent", "$12.50"]]))
    let query = api.calls[0].query
    #expect(query["granularity"] == ["1d"])
}

// MARK: - errors and safety

@Test func rejectedKeyReportsAnErrorWithoutTheKey() {
    let api = FakeApi(["api.deepseek.com /user/balance": httpError(401)])

    let result = Accounts.fetchAccount("deepseek", "sk-secret-1234567890", today: TODAY, get: api.get)

    #expect(result.string("error") == "the API key was rejected (HTTP 401)")
    #expect(!String(describing: result).contains("sk-secret"))
}

@Test func unexpectedResponseIsAnError() {
    let api = FakeApi(["api.deepseek.com /user/balance": .json(["weird": true] as JSONObject)])

    #expect(Accounts.fetchAccount("deepseek", "sk-1234567890", get: api.get).string("error")
        == "DeepSeek sent an unexpected response")
}

@Test func keysOnlyGoToTheProvidersOwnHosts() {
    #expect(Accounts.allowedHosts == [
        "openai": ["api.openai.com"],
        "deepseek": ["api.deepseek.com"],
        "kimi": ["api.moonshot.ai", "api.moonshot.cn"],
    ])
    // `send` stands in for the network: refusing means it's never called.
    let send: HTTP.Send = { _, _ in
        Issue.record("sent a request")
        return Data()
    }
    #expect(throws: HTTP.RefusedURL.self) {
        try Accounts.httpGetJSON("https://evil.example.com/x", key: "sk-1234567890", provider: "openai",
                                 send: send)
    }
    #expect(throws: HTTP.RefusedURL.self) {
        try Accounts.httpGetJSON("http://api.openai.com/x", key: "sk-1234567890", provider: "openai",
                                 send: send)
    }
}

@Test func storeResultKeepsLastGoodNumbersOnError() {
    var state = JSONObject()
    Accounts.storeResult(&state, "kimi", ["daily": ["d": 1], "cost": JSONObject(),
                                          "rows": [["Balance", "$1.00"]], "notes": [Any](),
                                          "error": NSNull(), "fetched_at": "t1"])
    Accounts.storeResult(&state, "kimi", ["daily": JSONObject(), "cost": JSONObject(), "rows": [Any](),
                                          "notes": [Any](), "error": "boom", "fetched_at": "t2"])

    let saved = dig(state, "accounts", "kimi") as? JSONObject ?? [:]
    #expect(jsonEqual(saved["rows"], [["Balance", "$1.00"]]))
    #expect(jsonEqual(saved["daily"], ["d": 1]))
    #expect(saved.string("error") == "boom")
    #expect(saved.string("attempted_at") == "t2")
}

@Test func accountDue() {
    let now = LocalTime.timestamp(2026, 11, 8, 12, 0, 0)
    #expect(Accounts.accountDue(nil, now: now))
    #expect(Accounts.accountDue(["attempted_at": "2026-11-08T11:44:00"], now: now))
    #expect(!Accounts.accountDue(["attempted_at": "2026-11-08T11:50:00"], now: now))
}

@Test func timeoutIsReportedNotRaised() {
    let api = FakeApi(["api.deepseek.com /user/balance": .error(HTTP.ConnectionError(reason: "timed out"))])

    #expect(Accounts.fetchAccount("deepseek", "sk-1234567890", get: api.get).string("error")
        == "couldn't reach DeepSeek (timed out)")
}

@Test func hasUsageMarksKeysThatReturnTokenUsage() {
    let openai = Accounts.fetchAccount("openai", "sk-admin-1234567890", today: TODAY,
                                       get: FakeApi(openaiRoutes()).get)
    let deepseek = Accounts.fetchAccount("deepseek", "sk-1234567890", today: TODAY, get: FakeApi([
        "api.deepseek.com /user/balance": .json(["is_available": true, "balance_infos": [Any]()] as JSONObject),
    ]).get)

    #expect(openai.bool("has_usage") == true)
    #expect(deepseek.bool("has_usage") == false)
}

// Not in the Python tests: the request the real `get` sends, without
// sending it, and the money format's thousands separators.
@Test func accountRequestHeadersAndNoRedirects() throws {
    var sent: [(URLRequest, Bool)] = []
    let send: HTTP.Send = { request, follow in
        sent.append((request, follow))
        return Data("{}".utf8)
    }

    _ = try Accounts.httpGetJSON("https://api.moonshot.cn/v1/users/me/balance", key: "sk-1234567890",
                                 provider: "kimi", send: send)

    let (request, followRedirects) = try #require(sent.first)
    #expect(!followRedirects)
    #expect(request.timeoutInterval == 20)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1234567890")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeTracker/\(Version.version)")
}

@Test func moneyMatchesPythonsFormat() throws {
    #expect(try Accounts.money(1234567.891, "$") == "$1,234,567.89")
    #expect(try Accounts.money("110.00", "¥") == "¥110.00")
    #expect(try Accounts.money(-1234.5, "$") == "$-1,234.50")
    #expect(try Accounts.money(0, "CHF ") == "CHF 0.00")
}
