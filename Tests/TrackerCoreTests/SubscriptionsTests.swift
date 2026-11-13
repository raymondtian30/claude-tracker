import Foundation
import Testing
@testable import TrackerCore

private func fakeToken(email: String, plan: String, issued: Int) throws -> String {
    let claims: JSONObject = [
        "iat": issued,
        "email": email,
        "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
    ]
    let payload = try JSON.encode(claims).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(payload).signature"
}

@Test func codexUpgradeRefreshesFromLocalSignIn() throws {
    let tmp = TempDir()
    let auth = tmp.url("auth.json")
    var state: JSONObject = ["enabled_tools": ["codex"]]
    let oldToken = try fakeToken(email: "user@example.com", plan: "plus", issued: 100)
    try JSON.write(["auth_mode": "chatgpt", "tokens": ["id_token": oldToken]], to: auth)
    #expect(Subscriptions.refresh(&state, authURL: auth))
    #expect(state.object("subscriptions")?.object("codex")?.string("plan") == "plus")
    #expect(!Subscriptions.refresh(&state, authURL: auth))

    let newToken = try fakeToken(email: "user@example.com", plan: "pro", issued: 200)
    try JSON.write(["auth_mode": "chatgpt", "tokens": ["id_token": oldToken, "access_token": newToken]], to: auth)
    #expect(Subscriptions.refresh(&state, authURL: auth))
    let found = state.object("subscriptions")?.object("codex") ?? [:]
    #expect(found.string("plan") == "pro")
    #expect(found.string("email") == "user@example.com")
    #expect(!String(data: try JSON.encode(state), encoding: .utf8)!.contains(newToken))

    try FileManager.default.removeItem(at: auth)
    #expect(Subscriptions.refresh(&state, authURL: auth))
    #expect(state.object("subscriptions")?.object("codex")?.isEmpty == true)
}

@Test func removeCardDetailsDropsTheDigitsAndEmptyEntries() {
    var state: JSONObject = ["subscription_details": [
        "codex": ["last_four": "4242", "card_email": "a@example.com"] as JSONObject,
        "claude_code": ["last_four": "1111", "email": "me@example.com"] as JSONObject,
    ]]
    Subscriptions.removeCardDetails(&state)
    #expect(state.object("subscription_details")?.object("codex") == nil)
    #expect(state.object("subscription_details")?.object("claude_code")?.string("email") == "me@example.com")
    #expect(state.object("subscription_details")?.object("claude_code")?.string("last_four") == nil)
    var empty: JSONObject = ["subscription_details": ["codex": ["last_four": "4242"] as JSONObject]]
    Subscriptions.removeCardDetails(&empty)
    #expect(empty["subscription_details"] == nil)
}

@Test func setDetailNoLongerStoresCardDigits() {
    var state = JSONObject()
    Subscriptions.setDetail(&state, tool: "codex", field: "last_four", value: "4242")
    #expect(state["subscription_details"] == nil)
}

@Test func launchDefaultsRemoveSavedCardDigits() {
    var state: JSONObject = ["subscription_details": ["codex": ["last_four": "4242"] as JSONObject]]
    AppState.applyLaunchDefaults(&state, freshInstall: false, today: Day(2026, 11, 12))
    #expect(state["subscription_details"] == nil)
}

@Test func claudeAccountProfileSuppliesPlanAndEmail() throws {
    let tmp = TempDir()
    let config = tmp.url("claude.json")
    try JSON.write(["oauthAccount": ["emailAddress": "claude@example.com",
                                     "organizationType": "claude_pro",
                                     "accountUuid": "private-id"]], to: config)
    var state: JSONObject = ["enabled_tools": ["claude_code"]]
    #expect(Subscriptions.refresh(&state, claudeURL: config))
    let found = state.object("subscriptions")?.object("claude_code") ?? [:]
    #expect(found.string("plan") == "Claude Pro")
    #expect(found.string("email") == "claude@example.com")
    #expect(found["accountUuid"] == nil)
}

@Test func subscriptionsTabShowsPlanAndEmailButNoCard() {
    let state: JSONObject = [
        "enabled_tools": ["codex"],
        "subscriptions": ["codex": ["plan": "pro", "email": "user@example.com"]],
        "subscription_details": ["codex": ["last_four": "4242"]],
    ]
    let tabs = PanelModel.buildPanel(Tools.toolView(state, "codex"), state: state,
                                     sessions: [], friends: [], showLeaderboard: false)
    let tab = tabs.first { $0.key == "subscriptions" }
    let card = tab?.cards.first { $0.title == "Codex" }
    #expect(tab?.title == "Subscriptions")
    #expect(card?.items.contains(.row(label: "Plan", value: "ChatGPT Pro")) == true)
    #expect(card?.items.contains(.row(label: "Email", value: "user@example.com")) == true)
    #expect(card?.items.contains { if case let .row(label, _, _) = $0 { return label == "Card" }; return false } == false)
    let buttons = card?.items.compactMap { item -> [Item.Button]? in
        if case let .buttons(b) = item { return b }
        return nil
    }.flatMap { $0 } ?? []
    #expect(!buttons.contains { $0.action.hasPrefix("subscription_card") })
    #expect(buttons.contains { $0.action == "subscription_email:codex" } == false)  // the email came from Codex
}

@Test func subscriptionActionsAcceptOnlySupportedTools() {
    #expect(AppAction.parse("subscription_email:codex", .none) == .subscriptionEmail("codex"))
    #expect(AppAction.parse("subscription_card:claude_code", .none) == nil)
    #expect(AppAction.parse("subscription_email:opencode", .none) == nil)
    #expect(AppAction.subscriptionEmail("codex").opensDialog)
}

