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

@Test func subscriptionCardStoresOnlyFourDigits() {
    var state = JSONObject()
    Subscriptions.setDetail(&state, tool: "codex", field: "last_four", value: "4242")
    #expect(state.object("subscription_details")?.object("codex")?.string("last_four") == "4242")
    Subscriptions.setDetail(&state, tool: "codex", field: "last_four", value: "4111111111114242")
    #expect(state.object("subscription_details")?.object("codex")?.string("last_four") == "4242")
    Subscriptions.setDetail(&state, tool: "codex", field: "last_four", value: nil)
    #expect(state.object("subscription_details")?.object("codex")?.string("last_four") == nil)
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

@Test func subscriptionsTabShowsPlanEmailAndMaskedCard() {
    let state: JSONObject = [
        "enabled_tools": ["codex"],
        "subscriptions": ["codex": ["plan": "pro", "email": "user@example.com"]],
        "subscription_details": ["codex": ["last_four": "4242"]],
    ]
    let tabs = PanelModel.buildPanel(Tools.toolView(state, "codex"), state: state,
                                     sessions: [], friends: [], showLeaderboard: false)
    let tab = tabs.first { $0.key == "subscriptions" }
    #expect(tab?.title == "Subscriptions")
    #expect(tab?.cards.first?.items.contains(.row(label: "Plan", value: "ChatGPT Pro")) == true)
    #expect(tab?.cards.first?.items.contains(.row(label: "Email", value: "user@example.com")) == true)
    #expect(tab?.cards.first?.items.contains(.row(label: "Card", value: "•••• 4242")) == true)
}

@Test func subscriptionActionsAcceptOnlySupportedTools() {
    #expect(AppAction.parse("subscription_email:codex", .none) == .subscriptionEmail("codex"))
    #expect(AppAction.parse("subscription_card:claude_code", .none) == .subscriptionCard("claude_code"))
    #expect(AppAction.parse("subscription_card:opencode", .none) == nil)
    #expect(AppAction.subscriptionCard("codex").opensDialog)
}

@Test func cardEndingDoesNotFollowAnotherAccount() {
    let state: JSONObject = [
        "enabled_tools": ["codex"],
        "subscriptions": ["codex": ["plan": "pro", "email": "new@example.com"]],
        "subscription_details": ["codex": ["last_four": "4242", "card_email": "old@example.com"]],
    ]
    let tab = PanelModel.buildPanel(Tools.toolView(state, "codex"), state: state,
                                    sessions: [], friends: [], showLeaderboard: false)
        .first { $0.key == "subscriptions" }
    #expect(tab?.cards.first?.items.contains(.row(label: "Card", value: "Unavailable")) == true)
}
