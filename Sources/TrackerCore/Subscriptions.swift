import Foundation

/// Subscription details available from local tool sign-ins. Only the small
/// fields shown in the panel are saved; tokens and full payment details are
/// never copied into the tracker state.
public enum Subscriptions {
    public static let codexAuthURL = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".codex/auth.json")
    public static let claudeConfigURL = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".claude.json")
    public static let supportedTools = ["codex", "claude_code"]

    /// Read the current Codex sign-in on every quick refresh. A missing or
    /// unreadable sign-in clears old identity details instead of showing an
    /// account that may have been signed out.
    @discardableResult
    public static func refresh(_ state: inout JSONObject, authURL: URL = codexAuthURL,
                               claudeURL: URL = claudeConfigURL) -> Bool {
        var all = state.object("subscriptions") ?? [:]
        let enabled = (JSON.array(state["enabled_tools"]) ?? []).compactMap(JSON.string)
        let nextCodex = enabled.contains("codex") ? codexIdentity(authURL: authURL) : [:]
        let nextClaude = enabled.contains("claude_code") ? claudeIdentity(configURL: claudeURL) : [:]
        let oldCodex = all.object("codex") ?? [:]
        let oldClaude = all.object("claude_code") ?? [:]
        guard !JSON.isEqual(oldCodex, nextCodex) || !JSON.isEqual(oldClaude, nextClaude) else { return false }
        all["codex"] = nextCodex
        all["claude_code"] = nextClaude
        state["subscriptions"] = all
        return true
    }

    static func claudeIdentity(configURL: URL) -> JSONObject {
        guard let config = try? JSON.loadObject(configURL), let account = config.object("oauthAccount") else {
            return [:]
        }
        var result = JSONObject()
        if let email = account.string("emailAddress"), validEmail(email) { result["email"] = email }
        switch account.string("organizationType") {
        case "claude_pro": result["plan"] = "Claude Pro"
        case "claude_max": result["plan"] = "Claude Max"
        case "claude_team": result["plan"] = "Claude Team"
        case "claude_enterprise": result["plan"] = "Claude Enterprise"
        default: break
        }
        return result
    }

    static func codexIdentity(authURL: URL) -> JSONObject {
        var result = JSONObject()
        if let auth = try? JSON.loadObject(authURL), auth.string("auth_mode") == "chatgpt",
           let tokens = auth.object("tokens") {
            let candidates = ["access_token", "id_token"].compactMap { key -> (key: String, claims: JSONObject)? in
                guard let token = tokens.string(key), let claims = jwtClaims(token) else { return nil }
                return (key, claims)
            }.sorted {
                let a = $0.claims.double("iat") ?? 0, b = $1.claims.double("iat") ?? 0
                return a == b ? $0.key == "access_token" : a > b
            }.map(\.claims)
            // Codex can refresh its access and ID tokens at different times.
            let email = candidates.lazy.compactMap { claims in
                claims.object("https://api.openai.com/profile")?.string("email") ?? claims.string("email")
            }.first(where: validEmail)
            if let email = email, validEmail(email) { result["email"] = email }
            let plan = candidates.lazy.compactMap {
                $0.object("https://api.openai.com/auth")?.string("chatgpt_plan_type")
            }.first { !$0.isEmpty }
            if let plan = plan {
                result["plan"] = plan
            }
        }
        return result
    }

    static func jwtClaims(_ token: String) -> JSONObject? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        let encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return JSON.parseObject(data)
    }

    public static func validEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return text.count <= 254 && parts.count == 2 && !parts[0].isEmpty &&
            parts[1].contains(".") && !text.contains(where: { $0.isWhitespace })
    }

    public static func displayPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pro": return "ChatGPT Pro"
        case "plus": return "ChatGPT Plus"
        case "free": return "Free"
        case "team": return "ChatGPT Team"
        case "business": return "ChatGPT Business"
        case "enterprise": return "ChatGPT Enterprise"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// The Plans tab used to record a payment card's last four digits (and
    /// the email it was entered for). It no longer shows them, so the saved
    /// digits are removed, and a tool's entry with nothing left goes too.
    public static func removeCardDetails(_ state: inout JSONObject) {
        guard var all = state.object("subscription_details") else { return }
        for (tool, value) in all {
            guard var detail = JSON.object(value) else { continue }
            detail["last_four"] = nil
            detail["card_email"] = nil
            all[tool] = detail.isEmpty ? nil : detail
        }
        state["subscription_details"] = all.isEmpty ? nil : all
    }

    public static func setDetail(_ state: inout JSONObject, tool: String, field: String, value: String?) {
        guard supportedTools.contains(tool), field == "email" else { return }
        if let value = value, !value.isEmpty {
            guard validEmail(value) else { return }
        }
        var all = state.object("subscription_details") ?? [:]
        var detail = all.object(tool) ?? [:]
        if let value = value, !value.isEmpty { detail[field] = value }
        else { detail.removeValue(forKey: field) }
        all[tool] = detail
        state["subscription_details"] = all
    }
}
