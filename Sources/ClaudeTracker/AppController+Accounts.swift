import AppKit
import TrackerCore

/// Provider API keys and account numbers (OpenAI, DeepSeek, Kimi), and
/// Claude Code's limit percentages from Anthropic.
extension AppController {
    func editSubscriptionEmail(_ tool: String) {
        guard Subscriptions.supportedTools.contains(tool) else { return }
        let saved = state.object("subscription_details")?.object(tool)?.string("email") ?? ""
        guard let entered = Dialogs.ask(title: "\(Tools.toolNames[tool] ?? tool) Email",
                                        message: "Enter the email used for this subscription. Leave blank to clear it.",
                                        defaultText: saved, ok: "Save", cancel: "Cancel") else { return }
        let email = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.isEmpty || Subscriptions.validEmail(email) else {
            Dialogs.alert("Invalid Email", "Enter an email address such as name@example.com.")
            return
        }
        Subscriptions.setDetail(&state, tool: tool, field: "email", value: email)
        save()
    }

    func editSubscriptionCard(_ tool: String) {
        guard Subscriptions.supportedTools.contains(tool) else { return }
        guard let entered = Dialogs.ask(title: "\(Tools.toolNames[tool] ?? tool) Card",
                                        message: "Enter only the last four digits of the card used for this subscription. Leave blank to clear it.",
                                        ok: "Save", cancel: "Cancel", secure: true) else { return }
        let digits = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.isEmpty || Subscriptions.validLastFour(digits) else {
            Dialogs.alert("Invalid Card Digits", "Enter exactly four digits. Full card numbers are not accepted.")
            return
        }
        Subscriptions.setDetail(&state, tool: tool, field: "last_four", value: digits)
        var details = state.object("subscription_details") ?? [:]
        var saved = details.object(tool) ?? [:]
        if !digits.isEmpty, let email = state.object("subscriptions")?.object(tool)?.string("email")
            ?? saved.string("email") {
            saved["card_email"] = email
        } else {
            saved.removeValue(forKey: "card_email")
        }
        details[tool] = saved
        state["subscription_details"] = details
        save()
    }

    // MARK: - API keys

    func addAPIKey(_ provider: String) {
        let name = Providers.providerNames[provider] ?? provider
        let help = Accounts.keyHelp[provider] ?? ""
        guard let text = Dialogs.ask(
            title: "\(name) API Key",
            message: "Paste your \(name) API key. It's stored only in this Mac's Keychain "
                + "and sent only to \(name).\n\n\(help).",
            ok: "Save", cancel: "Cancel", secure: true),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        do {
            try Accounts.saveKey(provider, text)
        } catch {
            Dialogs.alert("Key Not Saved", "\(error)")
            return
        }
        AppState.addProviderKey(&state, provider)
        save()
        fetchAccounts(force: provider)
    }

    func removeAPIKey(_ provider: String) {
        let name = Providers.providerNames[provider] ?? provider
        let confirmed = Dialogs.alert(
            "Remove \(name) API Key?",
            "This deletes the key from this Mac's Keychain. To see \(name) account "
                + "numbers again you'll need to paste it again.",
            ok: "Remove", cancel: "Cancel")
        guard confirmed else { return }
        Accounts.deleteKey(provider)
        AppState.removeProviderKey(&state, provider)
        save()
        renderPanel()
    }

    // MARK: - Account numbers

    /// Start a background fetch for each enabled provider with a key whose
    /// numbers are due (every 15 minutes) or `force`d, and for each BYOK
    /// provider scanned from opencode.
    func fetchAccounts(force: String? = nil) {
        for provider in AppState.accountsToFetch(state, inFlight: fetchingAccounts, force: force) {
            fetchingAccounts.insert(provider)
            inBackground({
                guard let key = Accounts.loadKey(provider) else {
                    return AppState.failedAccountResult("the key is no longer in the Keychain",
                                                        now: Date().timeIntervalSince1970)
                }
                return Accounts.fetchAccount(provider, key)
            }, then: { [weak self] result in
                self?.showFetchedAccount(provider, result)
            })
        }
        for provider in AppState.byokProvidersToFetch(state, inFlight: fetchingAccounts) {
            let token = "byok:\(provider)"
            fetchingAccounts.insert(token)
            inBackground({
                let keys = OpencodeSource.loadCredentialKeys()
                guard let key = keys[provider] else {
                    return AppState.failedAccountResult("the BYOK key is no longer in opencode",
                                                        now: Date().timeIntervalSince1970)
                }
                return Accounts.fetchBYOK(provider, key)
            }, then: { [weak self] result in
                self?.showFetchedBYOK(provider, result)
            })
        }
    }

    private func showFetchedAccount(_ provider: String, _ result: JSONObject) {
        fetchingAccounts.remove(provider)
        if AppState.strings(state["provider_keys"]).contains(provider) {  // not removed meanwhile
            Accounts.storeResult(&state, provider, result)
        }
        save()
        renderPanel()
    }

    private func showFetchedBYOK(_ provider: String, _ result: JSONObject) {
        fetchingAccounts.remove("byok:\(provider)")
        if OpencodeSource.byokProviders(state).contains(provider) {
            OpencodeSource.storeBYOKFetch(&state, provider: provider, result: result)
        }
        save()
        renderPanel()
    }

    // MARK: - Claude Code's percentages

    /// Start a background fetch of Claude Code's limit percentages, every 5
    /// minutes while Claude Code is tracked and the switch is on.
    func fetchClaudeUsage() {
        guard AppState.claudeUsageDue(state, inFlight: fetchingClaudeUsage) else { return }
        fetchingClaudeUsage = true
        inBackground({ ClaudeUsage.fetchUsage() }, then: { [weak self] result in
            self?.showClaudeUsage(result)
        })
    }

    private func showClaudeUsage(_ result: JSONObject) {
        fetchingClaudeUsage = false
        guard JSON.truthy(state["claude_usage_enabled"]) else { return }  // turned off meanwhile
        state["claude_usage"] = result
        save()
        checkAlerts()
        renderPanel()
    }
}
