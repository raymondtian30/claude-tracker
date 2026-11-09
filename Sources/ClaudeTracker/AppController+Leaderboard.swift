import AppKit
import TrackerCore

/// The Leaderboard (Beta): your entry in a secret gist, friends' entries
/// read from theirs, synced once a day.
///
/// GitHub calls and the friends list run on `leaderboardQueue`, one at a
/// time; dialogs and state.json changes stay on the main thread.
extension AppController {
    /// friends.json, or no friends if it can't be read.
    func loadFriends() -> [JSONObject] {
        Self.loadFriends(files.friends) { [weak self] in self?.log($0) }
    }

    nonisolated static func loadFriends(_ file: URL, log: (String) -> Void) -> [JSONObject] {
        do {
            return try Leaderboard.loadFriends(file)
        } catch {
            log("Couldn't read \(file.path): \(error)")
            return []
        }
    }

    /// Your entry. Yesterday's count reads Claude Code's logs, so call it
    /// off the main thread.
    nonisolated static func payload(_ state: JSONObject) -> JSONObject {
        let today = Day.today()
        let yesterday = (try? TokenMath.sumUsageForToday(today: today.adding(days: -1))) ?? 0
        return AppState.leaderboardPayload(state, yesterdayTokens: yesterday, today: today)
    }

    func startLeaderboardSetup() {
        let proceed = Dialogs.alert(
            "Set Up Leaderboard (Beta)",
            "This opens GitHub in your browser to create a personal access "
                + "token scoped only to 'gist'. Generate it, then come back here "
                + "and paste it in.",
            ok: "Open GitHub", cancel: "Cancel")
        guard proceed else { return }
        if let url = URL(string: GistSync.newTokenURL) {
            NSWorkspace.shared.open(url)
        }

        guard let token = Dialogs.ask(title: "GitHub Token", message: "Paste your GitHub token here:",
                                      ok: "Continue", cancel: "Cancel", secure: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return }

        guard let name = Dialogs.ask(title: "Your Leaderboard Name",
                                     message: "What name should show on the leaderboard?",
                                     defaultText: ProcessInfo.processInfo.environment["USER"] ?? "",
                                     ok: "Continue", cancel: "Cancel")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return }
        state["leaderboard_name"] = name

        let snapshot = UncheckedBox(state)
        inBackground(on: leaderboardQueue, {
            Result<String, Error> {
                try GistSync.setGithubToken(token)
                return try GistSync.createGist(token, Self.payload(snapshot.value))
            }
        }, then: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                Dialogs.alert("Setup Failed", "\(error)")
            case .success(let gistID):
                self.state["my_gist_id"] = gistID
                self.save()
                self.renderPanel()
                Dialogs.alert("All Set", "Your friend code is:\n\n\(gistID)")
            }
        })
    }

    func shareFriendCode() {
        Dialogs.alert("Your Friend Code", state.string("my_gist_id") ?? "")
    }

    func pushLeaderboardUpdate() {
        guard let gistID = state.string("my_gist_id"), !gistID.isEmpty else { return }
        let snapshot = UncheckedBox(state)
        // nil when pushed, else the dialog to show: (title, message).
        inBackground(on: leaderboardQueue, { () -> (String, String)? in
            guard let token = GistSync.getGithubToken(), !token.isEmpty else {
                return ("Leaderboard", "No GitHub token found -- run Get Set Up again.")
            }
            do {
                try GistSync.updateGist(token, gistID, Self.payload(snapshot.value))
                return nil
            } catch {
                return ("Push Failed", "\(error)")
            }
        }, then: { problem in
            if let (title, message) = problem {
                Dialogs.alert(title, message)
            }
        })
    }

    func addFriendByCode() {
        guard let gistID = Dialogs.ask(title: "Add Friend",
                                       message: "Paste your friend's Gist ID (their friend code):",
                                       ok: "Add", cancel: "Cancel")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !gistID.isEmpty,
              let friends = AppState.addingFriend(loadFriends(), gistID: gistID)
        else { return }
        attempt("save \(files.friends.path)") { try Leaderboard.saveFriends(friends, files.friends) }
        pullLeaderboardUpdates()
    }

    /// Refresh every friend's numbers from their gist, then redraw.
    func pullLeaderboardUpdates() {
        let file = files.friends
        inBackground(on: leaderboardQueue, { () -> String? in
            let friends = Self.loadFriends(file, log: { _ in })
            let updated = AppState.pulledFriends(friends) { try GistSync.fetchGist($0) }
            do {
                try Leaderboard.saveFriends(updated, file)
                return nil
            } catch {
                return "Couldn't save \(file.path): \(error)"
            }
        }, then: { [weak self] problem in
            if let problem = problem {
                self?.log(problem)
            }
            self?.renderPanel()
        })
    }

    /// Push and pull once a day while the Leaderboard is on.
    func runDailyLeaderboardSync() {
        let today = Day.today()
        guard AppState.leaderboardSyncDue(state, today: today) else { return }
        pushLeaderboardUpdate()
        pullLeaderboardUpdates()
        state["last_leaderboard_sync_date"] = today.iso
        save()
    }
}
