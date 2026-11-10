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

    private func send(_ action: SessionControl.Action, to pids: [Int32], verb: String) {
        let known = livePids
        inBackground({
            // One at a time, each checked against the sessions that were listed.
            pids.map { SessionControl.send(action, to: $0, among: known) }
        }, then: { [weak self] outcomes in
            guard let self = self else { return }
            let done = Set(zip(pids, outcomes).filter { $0.1 == .done }.map(\.0))
            self.live.apply(action, to: done)
            self.renderPanel()
            // The next search confirms it (a quit process can take a moment to go).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                onMain { self?.searchLive() }
            }
            if let reason = outcomes.compactMap({ outcome -> String? in
                if case .refused(let reason) = outcome { return reason } else { return nil }
            }).first {
                self.panel.close()
                Dialogs.alert("Couldn't \(verb) it", reason)
            }
        })
    }
}
