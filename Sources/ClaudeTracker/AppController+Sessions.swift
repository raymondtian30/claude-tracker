import AppKit
import TrackerCore

/// Stop, Resume and Quit on the Live tab: signals to Claude Code processes.
/// `SessionControl` checks that each one is a listed, still-running `claude`
/// process before anything is sent.
extension AppController {
    /// The process ids of the sessions the Live tab lists right now.
    var livePids: [Int32] { live.sessions.compactMap(\.pid) }

    /// Pause or resume `pids`; the tab shows the change at once.
    func pauseOrResume(_ action: SessionControl.Action, _ pids: [Int32]) {
        guard !pids.isEmpty else { return }
        send(action, to: pids, verb: action == .stop ? "pause" : "resume")
    }

    /// Ends one session, after asking: whatever Claude was in the middle of is lost.
    func quitSession(_ pid: Int32) {
        guard let session = live.sessions.first(where: { $0.pid == pid }) else { return }
        let name = PanelModel.folderParts(session.label).name
        guard Dialogs.alert("Quit this Claude session?",
                            "\(name) (process \(pid)) will be closed. Anything Claude is in the middle of is lost.",
                            ok: "Quit Session", cancel: "Cancel") else { return }
        send(.quit, to: [pid], verb: "quit")
    }

    /// How long a quit session gets to shut down before it counts as still there.
    private static let quitSeconds = 3.0

    private func send(_ action: SessionControl.Action, to pids: [Int32], verb: String) {
        let known = livePids
        let patience = Self.quitSeconds
        // Anything the Live tab learned before this click may now be wrong; a
        // search already running must not put the old list back.
        liveGeneration += 1
        inBackground({
            // One at a time, each checked against the sessions that were listed.
            pids.map { pid -> (pid: Int32, outcome: SessionControl.Outcome, gone: Bool) in
                let outcome = SessionControl.send(action, to: pid, among: known)
                // A quit session takes a moment to shut down; wait, so the list
                // is right when it is drawn, not 15 seconds later.
                let gone = action == .quit && outcome == .done
                    && SessionControl.waitUntilGone(pid, timeout: patience)
                return (pid, outcome, gone)
            }
        }, then: { [weak self] results in
            guard let self = self else { return }
            let worked = Set(results.filter { $0.outcome == .done && (action != .quit || $0.gone) }.map(\.pid))
            self.live.apply(action, to: worked)
            self.liveGeneration += 1
            self.renderPanel()
            self.searchLive()  // confirms it, and refreshes the plugin counts
            var problem: String?
            for result in results {
                if case .refused(let reason) = result.outcome {
                    problem = reason
                } else if action == .quit && !result.gone {
                    problem = "It didn't close within \(Int(Self.quitSeconds)) seconds. It may be busy; try again."
                }
            }
            if let problem = problem {
                self.panel.close()
                Dialogs.alert("Couldn't \(verb) it", problem)
            }
        })
    }
}
