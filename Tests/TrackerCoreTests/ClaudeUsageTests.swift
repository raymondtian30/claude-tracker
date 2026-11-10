// Ported from tests/test_claude_usage.py, test for test.
//
// Python's urllib errors are HTTP's error types here: HTTPError is
// `HTTP.StatusError`, URLError and TimeoutError are `HTTP.ConnectionError`,
// ValueError is `HTTP.UnexpectedAnswer`.

import Foundation
import Testing
@testable import TrackerCore

private let NOW = LocalTime.parseISO("2026-11-08T12:00:00Z")!

/// A fake `security` run that returns `payload` as the stored item.
private final class Keychain {
    var calls: [[String]] = []
    let stdout: String
    let status: Int32

    init(_ payload: Any, status: Int32 = 0) {
        stdout = payload as? String ?? String(decoding: try! JSON.encode(payload), as: UTF8.self)
        self.status = status
    }

    func run(_ args: [String], _ input: String?) -> Subprocess.Result {
        calls.append(args)
        return Subprocess.Result(status: status, stdout: stdout)
    }
}

private func signedIn(expiresIn: Double = 3600) -> Keychain {
    Keychain(["claudeAiOauth": ["accessToken": "tok", "refreshToken": "never-used",
                                "expiresAt": (NOW + expiresIn) * 1000]])
}

private let ANSWER: JSONObject = [
    "five_hour": ["utilization": 23.0, "resets_at": "2026-11-08T15:30:00.000000+00:00"],
    "seven_day": ["utilization": 41.5, "resets_at": "2026-11-12T09:00:00Z"],
    "seven_day_opus": NSNull(),
    "seven_day_sonnet": ["utilization": 3, "resets_at": NSNull()],
]

@Test func loadTokenReadsClaudeCodesKeychainItem() {
    let keychain = signedIn()

    let (token, error) = ClaudeUsage.loadToken(run: keychain.run, now: NOW)

    #expect(token == "tok" && error == nil)
    #expect(keychain.calls == [["security", "find-generic-password", "-s", "Claude Code-credentials",
                                "-w"]])
}

@Test func loadTokenWhenSignedOutOrExpired() {
    let signedOut = ClaudeUsage.loadToken(run: Keychain("", status: 44).run, now: NOW)
    #expect(signedOut.token == nil && signedOut.error == ClaudeUsage.signedOut)
    let notJSON = ClaudeUsage.loadToken(run: Keychain("not json").run, now: NOW)
    #expect(notJSON.token == nil && notJSON.error == ClaudeUsage.signedOut)
    let expired = ClaudeUsage.loadToken(run: signedIn(expiresIn: -1).run, now: NOW)
    #expect(expired.token == nil && expired.error == ClaudeUsage.expired)
}

@Test func parseUsage() throws {
    #expect(jsonEqual(try ClaudeUsage.parseUsage(ANSWER), [
        ["kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 23.0,
         "resets_at": LocalTime.parseISO("2026-11-08T15:30:00Z")!],
        ["kind": "weekly", "window": "weekly", "label": "Weekly", "percent": 41.5,
         "resets_at": LocalTime.parseISO("2026-11-12T09:00:00Z")!],
        ["kind": "weekly_sonnet", "window": "weekly", "label": "Weekly · Sonnet", "percent": 3.0,
         "resets_at": NSNull()],
    ]))
}

@Test func parseUsageRejectsAnAnswerWithoutLimits() {
    #expect(throws: HTTP.UnexpectedAnswer.self) {
        try ClaudeUsage.parseUsage(["something": "else"])
    }
}

@Test func fetchUsageSendsTheTokenToTheUsageEndpoint() {
    var seen: [[String]] = []
    let get: ClaudeUsage.Get = { url, token in
        seen.append([url, token])
        return ANSWER
    }

    let result = ClaudeUsage.fetchUsage(get: get, run: signedIn().run, now: NOW)

    #expect(seen == [["https://api.anthropic.com/api/oauth/usage", "tok"]])
    #expect(JSON.isNull(result["error"]) && result.double("fetched_at") == NOW)
    #expect((result.array("limits") ?? []).map { JSON.object($0)?.double("percent") } == [23.0, 41.5, 3.0])
}

struct UsageFailure: Sendable, CustomTestStringConvertible {
    let error: any Error & Sendable
    let message: String
    var testDescription: String { message }
}

@Test(arguments: [
    UsageFailure(error: HTTP.ConnectionError(reason: "offline"), message: ClaudeUsage.offline),
    UsageFailure(error: HTTP.ConnectionError(reason: "timed out"), message: ClaudeUsage.offline),
    UsageFailure(error: HTTP.StatusError(code: 401), message: ClaudeUsage.expired),
    UsageFailure(error: HTTP.StatusError(code: 500),
                 message: "Anthropic answered HTTP 500. Percentage unavailable."),
    UsageFailure(error: HTTP.UnexpectedAnswer(description: "bad"),
                 message: "Anthropic sent an unexpected answer. Percentage unavailable."),
])
func fetchUsageWithoutAConnectionSaysPercentageUnavailable(_ failure: UsageFailure) {
    let get: ClaudeUsage.Get = { _, _ in throw failure.error }

    let result = ClaudeUsage.fetchUsage(get: get, run: signedIn().run, now: NOW)

    #expect(jsonEqual(result, ["limits": [Any](), "error": failure.message, "fetched_at": NOW]))
}

@Test func fetchUsageNeverCallsOutWithAnExpiredSignIn() {
    let get: ClaudeUsage.Get = { _, _ in
        Issue.record("shouldn't be called")
        return [:] as JSONObject
    }

    #expect(ClaudeUsage.fetchUsage(get: get, run: signedIn(expiresIn: -1).run, now: NOW)
        .string("error") == ClaudeUsage.expired)
}

@Test func theTokenOnlyGoesToAnthropic() {
    // `send` stands in for the network: refusing means it's never called.
    let send: HTTP.Send = { _, _ in
        Issue.record("sent a request")
        return Data()
    }
    #expect(throws: HTTP.RefusedURL.self) {
        try ClaudeUsage.httpGetJSON("https://example.com/api/oauth/usage", token: "tok", send: send)
    }
    #expect(throws: HTTP.RefusedURL.self) {
        try ClaudeUsage.httpGetJSON("http://api.anthropic.com/api/oauth/usage", token: "tok", send: send)
    }
}

@Test func usageDueEveryFiveMinutes() {
    #expect(ClaudeUsage.usageDue(nil, now: NOW))
    #expect(!ClaudeUsage.usageDue(["fetched_at": NOW - 299], now: NOW))
    #expect(ClaudeUsage.usageDue(["fetched_at": NOW - 300], now: NOW))
}

// Not in the Python tests: the request the real `get` sends, without sending it.
@Test func usageRequestHeadersAndNoRedirects() throws {
    var sent: [(URLRequest, Bool)] = []
    let send: HTTP.Send = { request, follow in
        sent.append((request, follow))
        return Data(#"{"ok": true}"#.utf8)
    }

    _ = try ClaudeUsage.httpGetJSON(ClaudeUsage.usageURL, token: "tok", send: send)

    let (request, followRedirects) = try #require(sent.first)
    #expect(!followRedirects)
    #expect(request.timeoutInterval == 20)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeTracker/\(Version.version)")
}

/// Many commands at once, each started from a GCD pool thread, must all
/// finish. The pipe readers used to borrow pool threads too: with more
/// callers than the pool's thread limit (64) blocked waiting on them, the
/// readers never got a thread and every caller hung.
@Test func manyCommandsAtOnceAllFinish() {
    let group = DispatchGroup()
    let lock = NSLock()
    var results = [Subprocess.Result]()
    for i in 0..<128 {
        DispatchQueue.global().async(group: group) {
            let result = Subprocess.run(["/bin/sh", "-c", "sleep 0.2; echo out\(i); echo err\(i) >&2"])
            lock.lock(); results.append(result); lock.unlock()
        }
    }
    #expect(group.wait(timeout: .now() + 60) == .success)
    lock.lock(); defer { lock.unlock() }
    #expect(results.count == 128)
    #expect(results.allSatisfy { $0.status == 0 && $0.stdout.hasPrefix("out") && $0.stderr.hasPrefix("err") })
}

// The `limits` list: Anthropic's newer answer lists model-scoped limits
// (Fable) there, not as a `seven_day_*` key.

private func scoped(_ name: Any?, percent: Any? = 0, resetsAt: Any? = "2026-11-10T19:00:00+00:00",
                    kind: String = "weekly_scoped") -> JSONObject {
    ["kind": kind, "group": "weekly", "percent": percent as Any, "severity": "normal",
     "resets_at": resetsAt as Any, "scope": ["model": ["id": NSNull(), "display_name": name as Any],
                                             "surface": NSNull()] as JSONObject,
     "is_active": false]
}

private func answer(adding items: [JSONObject]) -> JSONObject {
    var answer = ANSWER
    answer["limits"] = items
    return answer
}

private func fableLimit(_ name: String = "Fable", kind: String = "weekly_fable", percent: Double = 0.0) -> JSONObject {
    ["kind": kind, "window": "weekly", "label": "Weekly · \(name)", "percent": percent,
     "resets_at": LocalTime.parseISO("2026-11-10T19:00:00Z")!]
}

@Test func fableFromTheLimitsList() throws {
    let parsed = try ClaudeUsage.parseUsage(answer(adding: [scoped("Fable")]))
    #expect(parsed.count == 4)
    #expect(jsonEqual(Array(parsed.suffix(1)), [fableLimit()]))
}

@Test func sessionAndWeeklyAllItemsAddNothing() throws {
    let items = [["kind": "session", "group": "session", "percent": 26, "resets_at": "2026-11-10T01:29:59+00:00",
                  "scope": NSNull()] as JSONObject,
                 ["kind": "weekly_all", "group": "weekly", "percent": 91, "resets_at": "2026-11-10T18:59:59+00:00",
                  "scope": NSNull()] as JSONObject]
    #expect(try ClaudeUsage.parseUsage(answer(adding: items)).count == 3)
}

@Test func scopedItemWithoutAModelIsSkipped() throws {
    let noModel: JSONObject = ["kind": "weekly_scoped", "percent": 5, "resets_at": NSNull(),
                               "scope": ["model": NSNull(), "surface": "web"] as JSONObject]
    let items = [noModel, scoped(NSNull()), scoped(""), scoped(5)]
    #expect(try ClaudeUsage.parseUsage(answer(adding: items)).count == 3)
}

@Test func aBadItemSkipsOnlyThatItem() throws {
    let items = [scoped("Fable", percent: "x"), scoped("Mist", resetsAt: "not a time"), scoped("Ember", percent: true),
                 scoped("Opal")]
    let parsed = try ClaudeUsage.parseUsage(answer(adding: items))
    #expect(parsed.count == 4)
    #expect(parsed.last?.string("kind") == "weekly_opal")
}

@Test func numericStringPercentIsSkipped() throws {
    #expect(try ClaudeUsage.parseUsage(answer(adding: [scoped("Fable", percent: "12")])).count == 3)
}

@Test func nullResetTimeIsKept() throws {
    let parsed = try ClaudeUsage.parseUsage(answer(adding: [scoped("Fable", percent: 40, resetsAt: NSNull())]))
    #expect(jsonEqual(Array(parsed.suffix(1)), [["kind": "weekly_fable", "window": "weekly",
                                                 "label": "Weekly · Fable", "percent": 40.0,
                                                 "resets_at": NSNull()]]))
}

@Test func scopedItemMatchingAnExistingKindIsSkipped() throws {
    var legacy = ANSWER
    legacy["seven_day_opus"] = ["utilization": 7.0, "resets_at": NSNull()]
    legacy["limits"] = [scoped("Opus")]
    let kinds = try ClaudeUsage.parseUsage(legacy).map { $0.string("kind") }
    #expect(kinds.filter { $0 == "weekly_opus" }.count == 1)
}

@Test func twoItemsWithTheSameKindKeepTheFirst() throws {
    let parsed = try ClaudeUsage.parseUsage(answer(adding: [scoped("Fable", percent: 10), scoped("fable", percent: 20)]))
    #expect(parsed.filter { $0.string("kind") == "weekly_fable" }.map { $0.double("percent") } == [10.0])
}

@Test func limitsMissingOrNotAListParsesAsBefore() throws {
    #expect(try ClaudeUsage.parseUsage(ANSWER).count == 3)
    var notAList = ANSWER
    notAList["limits"] = "nope"
    #expect(try ClaudeUsage.parseUsage(notAList).count == 3)
    var onlyAList: JSONObject = ["limits": [scoped("Fable")]]
    #expect(try ClaudeUsage.parseUsage(onlyAList).count == 1)
    onlyAList["limits"] = [scoped("!!!")]
    #expect(throws: HTTP.UnexpectedAnswer.self) { try ClaudeUsage.parseUsage(onlyAList) }
}

@Test func nameBecomesKind() throws {
    func kind(_ name: String) throws -> String? {
        try ClaudeUsage.parseUsage(answer(adding: [scoped(name)])).last?.string("kind")
    }
    #expect(try kind("Fable!") == "weekly_fable")
    #expect(try kind("GPT-5 Pro") == "weekly_gpt_5_pro")
    #expect(try kind("  Mist  ") == "weekly_mist")
    let cut = try ClaudeUsage.parseUsage(answer(adding: [scoped(String(repeating: "a", count: 40))])).last
    #expect(cut?.string("kind") == "weekly_" + String(repeating: "a", count: 24))
    #expect(cut?.string("label") == "Weekly · " + String(repeating: "a", count: 24))
}

@Test func numericResetTimeIsSkipped() throws {
    // Only an ISO time or null: a number (or one too big for a date) skips the item.
    for resetsAt: Any in [1794337200.0, 1e20, -1e20, true] {
        #expect(try ClaudeUsage.parseUsage(answer(adding: [scoped("Fable", resetsAt: resetsAt)])).count == 3)
    }
}
