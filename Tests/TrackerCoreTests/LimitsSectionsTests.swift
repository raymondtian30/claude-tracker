// The Usage Limits tab's one "Limits" card: a section for every tracked AI,
// "No data" when there is nothing, and a note on numbers that may be old.

import Foundation
import Testing
@testable import TrackerCore

private let now = LocalTime.timestamp(2026, 11, 12, 12, 0, 0)

private func utc(_ secondsAgo: Double) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now - secondsAgo))
}

private func limits(_ state: JSONObject, _ viewKey: String) -> Tab {
    PanelModel.buildPanel(Tools.toolView(state, viewKey), state: state, sessions: [], friends: [],
                          showLeaderboard: false, today: Day(2026, 11, 12), now: now)
        .first { $0.key == "limits" }!
}

private func card(_ tab: Tab) -> [Item] {
    tab.cards.first { $0.title == "Limits" }!.items
}

private func notes(_ items: [Item]) -> String {
    items.compactMap { item -> String? in
        if case let .note(text) = item { return text }
        return nil
    }.joined(separator: " ")
}

private func codexFile(_ used: Double, ageSeconds: Double, resetsAt: Double = now + 3 * 3600) -> JSONObject {
    let record: JSONObject = ["at": utc(ageSeconds), "rate_limits": [
        "limit_id": "codex",
        "primary": ["used_percent": used, "window_minutes": 300, "resets_at": resetsAt] as JSONObject,
        "secondary": NSNull(),
    ] as JSONObject]
    return ["codex": ["files": ["f": ["size": 1, "mtime": 1, "daily": JSONObject(), "limits": record] as JSONObject]]]
}

private func claudeUsage(_ percent: Double, fetchedAgo: Double) -> JSONObject {
    ["limits": [["kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": percent,
                 "resets_at": now + 3600] as JSONObject],
     "error": NSNull(), "fetched_at": now - fetchedAgo]
}

@Test func allAIsHasASectionForEveryTrackedAIEvenWithNoData() {
    let state: JSONObject = [
        "enabled_tools": ["claude_code", "codex", "gemini_cli"],
        "enabled_providers": ["deepseek"],
        "claude_usage": claudeUsage(40, fetchedAgo: 60),
        "sources": codexFile(20, ageSeconds: 60),
    ]
    let items = card(limits(state, "all"))
    let headings = items.compactMap { item -> String? in
        if case let .heading(text) = item { return text }
        return nil
    }
    #expect(headings == ["Claude Code", "Codex", "Gemini CLI", "DeepSeek"])
    // Gemini CLI and DeepSeek have nothing: each says so under its heading.
    let gemini = items.firstIndex(of: .heading("Gemini CLI"))!
    #expect(items[gemini + 1] == .row(label: "Limits", value: "No data"))
    let deepseek = items.firstIndex(of: .heading("DeepSeek"))!
    #expect(items[deepseek + 1] == .row(label: "Limits", value: "No data"))
    #expect(items.contains(.bar(label: "5-hour", value: "40%", fraction: 0.4, sub: "Resets 1:00 PM")))
    #expect(!notes(items).contains("out of date"))
}

@Test func aProvidersOwnViewSaysNoDataWithoutAnything() {
    let state: JSONObject = ["enabled_providers": ["deepseek"]]
    #expect(card(limits(state, "deepseek")).first == .row(label: "Limits", value: "No data"))
}

@Test func aProvidersAccountRowsShowAndNonLimitRowsDoNot() {
    let state: JSONObject = [
        "enabled_providers": ["kimi"], "provider_keys": ["kimi"],
        "accounts": ["kimi": ["rows": [["Balance", "$5.00"], ["Total spent", "$9.00"], ["Models available", "3"]],
                              "error": NSNull(), "fetched_at": Accounts.isoSeconds(now - 60)] as JSONObject],
    ]
    let items = card(limits(state, "kimi"))
    #expect(items.contains(.row(label: "Balance", value: "$5.00")))
    #expect(!items.contains { if case let .row(label, _, _) = $0 { return label == "Total spent" || label == "Models available" }; return false })
    #expect(!notes(items).contains("out of date"))
}

@Test func aFailedAccountRefreshMarksItsRowsAsOld() {
    let state: JSONObject = [
        "enabled_providers": ["kimi"], "provider_keys": ["kimi"],
        "accounts": ["kimi": ["rows": [["Balance", "$5.00"]], "error": "timed out",
                              "fetched_at": Accounts.isoSeconds(now - 2 * 3600)] as JSONObject],
    ]
    #expect(notes(card(limits(state, "kimi"))).contains("Last updated 2 hr ago, so this may be out of date."))
}

@Test func oldCodexNumbersStayWithANote() {
    let fresh = card(limits(["sources": codexFile(30, ageSeconds: 20 * 60)], "codex"))
    #expect(fresh.first == .bar(label: "Codex (5-hour)", value: "30%", fraction: 0.3, sub: "Resets 3:00 PM"))
    #expect(!notes(fresh).contains("out of date"))

    let old = card(limits(["sources": codexFile(30, ageSeconds: 2 * 3600)], "codex"))
    #expect(old.first == .bar(label: "Codex (5-hour)", value: "30%", fraction: 0.3, sub: "Resets 3:00 PM"))
    #expect(notes(old).contains("Last updated 2 hr ago, so this may be out of date."))
}

@Test func aCodexWindowThatResetSinceIsMarkedOld() {
    let items = card(limits(["sources": codexFile(70, ageSeconds: 20 * 60, resetsAt: now - 60)], "codex"))
    #expect(items.first == .bar(label: "Codex (5-hour)", value: "0%", fraction: 0, sub: nil))
    #expect(notes(items).contains("out of date"))
}

@Test func claudesLastGoodAnswerShowsWhenAFetchFails() {
    var usage = claudeUsage(55, fetchedAgo: 3 * 3600)
    let lastGood: JSONObject = ["limits": usage["limits"]!, "fetched_at": usage["fetched_at"]!]
    usage = ["limits": [Any](), "error": ClaudeUsage.offline, "fetched_at": now - 60, "last_good": lastGood]
    let state: JSONObject = ["claude_usage": usage]
    let items = card(limits(state, "claude_code"))
    #expect(items.first == .bar(label: "Claude Code (5-hour)", value: "55%", fraction: 0.55, sub: "Resets 1:00 PM"))
    #expect(notes(items).contains("Last updated 3 hr ago, so this may be out of date."))
    #expect(notes(items).contains(ClaudeUsage.offline))
    // Alerts and the Live tab never use the old numbers.
    #expect(Limits.claudeLimits(state, now: now).isEmpty)
}

@Test func aReachedLimitInTheLogsBeatsAnOldPercentage() {
    let lastGood: JSONObject = ["limits": claudeUsage(55, fetchedAgo: 3 * 3600)["limits"]!, "fetched_at": now - 3 * 3600]
    let state: JSONObject = [
        "claude_usage": ["limits": [Any](), "error": ClaudeUsage.offline, "fetched_at": now, "last_good": lastGood] as JSONObject,
        "claude_limit_hits": ["five_hour": now + 1800],
    ]
    let shown = Limits.claudeShown(state, now: now)
    #expect(shown.levels.count == 1)
    #expect(shown.levels[0].reached)
    #expect(shown.stale)
}

@Test func oldClaudePercentagesGetTheNote() {
    let items = card(limits(["claude_usage": claudeUsage(10, fetchedAgo: 40 * 60)], "claude_code"))
    #expect(notes(items).contains("Last updated 40 min ago"))
    let unknown = Limits.claudeShown(["claude_usage": claudeUsage(10, fetchedAgo: now)], now: now)
    #expect(unknown.stale && unknown.updatedAt == nil)
    #expect(PanelModel.staleNote(nil, now: now) == "Last updated at an unknown time, so this may be out of date.")
}

@Test func claudeSaysLoadingBeforeTheFirstAnswer() {
    let items = card(limits(["enabled_tools": ["claude_code"]], "claude_code"))
    #expect(items.first == .row(label: "Limits", value: "Loading…"))
}

@Test func mergedKeepsTheLastGoodAnswerAcrossFailures() {
    let good = ClaudeUsage.merged(previous: nil, fetched: claudeUsage(20, fetchedAgo: 0))
    #expect((good.object("last_good")?.array("limits") ?? []).count == 1)
    let failed = ClaudeUsage.merged(previous: good, fetched: ["limits": [Any](), "error": ClaudeUsage.offline,
                                                             "fetched_at": now + 300])
    #expect(failed.object("last_good")?.double("fetched_at") == now)
    #expect((failed.array("limits") ?? []).isEmpty)
    let signedOut = ClaudeUsage.merged(previous: failed, fetched: ["limits": [Any](), "error": ClaudeUsage.signedOut,
                                                                  "fetched_at": now + 600])
    #expect(signedOut["last_good"] == nil)
    let none = ClaudeUsage.merged(previous: nil, fetched: ["limits": [Any](), "error": ClaudeUsage.offline])
    #expect(none["last_good"] == nil)
}

@Test func inAllAIsOpencodeLeavesATrackedProvidersRowsToItsOwnSection() {
    let state: JSONObject = [
        "enabled_tools": ["opencode"], "enabled_providers": ["google"],
        "sources": ["opencode": ["byok": ["providers": ["google", "deepseek"]] as JSONObject] as JSONObject],
    ]
    let items = card(limits(state, "all"))
    let google = items.indices.filter { items[$0] == .row(label: "Google API key", value: "Active (opencode)") }
    let googleHeading = items.firstIndex(of: .heading("Google"))!
    #expect(google == [googleHeading + 1])
    let opencode = items.firstIndex(of: .heading("opencode"))!
    #expect(items[opencode + 1] == .row(label: "DeepSeek API key", value: "Active (opencode)"))
}

@Test func trackedKeysFollowTheAppsOrder() {
    let state: JSONObject = ["enabled_tools": ["codex", "claude_code"], "enabled_providers": ["kimi", "openai"]]
    #expect(Limits.trackedKeys("all", state: state) == ["claude_code", "codex", "openai", "kimi"])
    #expect(Limits.trackedKeys("kimi", state: state) == ["kimi"])
    #expect(Limits.trackedKeys("nope", state: state) == [])
}

@Test func aProviderWithOnlyCatalogModelsHasNoData() {
    let state: JSONObject = [
        "enabled_providers": ["google"],
        "sources": ["opencode": ["byok": ["models": ["gemini-x": ["provider": "google", "context": 1000,
                                                                  "output": 100] as JSONObject] as JSONObject]
                                 as JSONObject] as JSONObject],
    ]
    let items = card(limits(state, "google"))
    #expect(items.first == .row(label: "Limits", value: "No data"))
    #expect(notes(items).contains("No API key or account numbers for Google yet."))
}

@Test func anAnswerWithoutLimitsIsNoDataNotLoading() {
    let state: JSONObject = ["claude_usage": ["limits": [Any](), "error": NSNull(), "fetched_at": now - 60] as JSONObject]
    #expect(card(limits(state, "claude_code")).first == .row(label: "Limits", value: "No data"))
}

@Test func mergedTakesAnOlderVersionsAnswerAsTheLastGoodOne() {
    let old: JSONObject = claudeUsage(30, fetchedAgo: 600)  // no "last_good": saved before it existed
    let failed = ClaudeUsage.merged(previous: old, fetched: ["limits": [Any](), "error": ClaudeUsage.offline,
                                                            "fetched_at": now])
    #expect((failed.object("last_good")?.array("limits") ?? []).count == 1)
    #expect(failed.object("last_good")?.double("fetched_at") == now - 600)
}

@Test func opencodeWhoseKeysAllHaveTheirOwnSectionSaysSo() {
    let state: JSONObject = [
        "enabled_tools": ["opencode"], "enabled_providers": ["google"],
        "sources": ["opencode": ["byok": ["providers": ["google"]] as JSONObject] as JSONObject],
    ]
    let items = card(limits(state, "all"))
    let opencode = items.firstIndex(of: .heading("opencode"))!
    #expect(items[opencode + 1] == .note("Its API keys are shown under each provider."))
}

@Test func anExpiredSignInKeepsTheOldNumbersButAnotherAccountDropsThem() {
    let good = ClaudeUsage.merged(previous: nil, fetched: claudeUsage(20, fetchedAgo: 0), account: "a@example.com")
    let expired = ClaudeUsage.merged(previous: good, fetched: ["limits": [Any](), "error": ClaudeUsage.expired],
                                     account: "a@example.com")
    #expect(expired["last_good"] != nil)
    let other = ClaudeUsage.merged(previous: good, fetched: ["limits": [Any](), "error": ClaudeUsage.offline],
                                   account: "b@example.com")
    #expect(other["last_good"] == nil)
    let emptyAnswer = ClaudeUsage.merged(previous: good, fetched: ["limits": [Any](), "error": NSNull()],
                                         account: "a@example.com")
    #expect(emptyAnswer["last_good"] != nil)
}
