import AppKit
import TrackerCore

/// Stop, Resume and Quit on the Live tab: signals to Claude Code processes.
/// `SessionControl` checks that each one is a listed, still-running `claude`
/// process before anything is sent. Every action is logged (with process ids
/// only) to ~/Library/Logs/ClaudeTracker/agent.err.log, to look at if one
/// doesn't do what it should.
extension AppController {
    /// The process ids of the sessions the Live tab lists right now.
    var livePids: [Int32] { live.sessions.compactMap(\.pid) }

    /// Pause or resume `pids`; the tab shows the change at once.
    func pauseOrResume(_ action: SessionControl.Action, _ pids: [Int32]) {
        guard !pids.isEmpty else { return }
        let known = livePids
        let verb = action == .stop ? "pause" : "resume"
        // Anything the Live tab learned before this click may now be wrong; a
        // search already running must not put the old list back.
        liveGeneration += 1
        inBackground({
            pids.map { SessionControl.send(action, to: $0, among: known) }
        }, then: { [weak self] outcomes in
            guard let self = self else { return }
            var problem: String?
            var worked = Set<Int32>()
            for (pid, outcome) in zip(pids, outcomes) {
                self.log("Live: \(verb) process \(pid): \(outcome)")
                if outcome == .done {
                    worked.insert(pid)
                } else if case .refused(let reason) = outcome {
                    problem = reason
                }
            }
            self.live.apply(action, to: worked)
            self.liveGeneration += 1
            self.renderPanel()
            self.searchLive()  // confirms it
            if let problem = problem {
                self.panel.close()
                Dialogs.alert("Couldn't \(verb) it", problem)
            }
        })
    }

    /// Ends the sessions with these process ids, after asking: whatever Claude
    /// is in the middle of is lost. Each is asked to quit, and force-quit if
    /// it ignores that for 3 seconds (`SessionControl.quit`).
    func quitSessions(_ pids: [Int32]) {
        let sessions = pids.compactMap { pid in live.sessions.first { $0.pid == pid } }
        guard !sessions.isEmpty else { return }
        let question = SessionControl.quitQuestion(sessions)
        guard Dialogs.confirmDestructive(title: question.title, message: question.message,
                                         confirm: question.confirm) else { return }
        let known = livePids
        liveGeneration += 1
        inBackground({
            SessionControl.quit(sessions.compactMap(\.pid), among: known)
        }, then: { [weak self] results in
            guard let self = self else { return }
            var gone = Set<Int32>()
            var stuck = 0
            var reasons = [String]()
            for (pid, outcome) in results.sorted(by: { $0.key < $1.key }) {
                self.log("Live: quit process \(pid): \(outcome)")
                switch outcome {
                case .closed, .forced: gone.insert(pid)
                case .stuck: stuck += 1
                case .refused(let reason): if !reasons.contains(reason) { reasons.append(reason) }
                }
            }
            self.live.apply(.quit, to: gone)
            self.liveGeneration += 1
            self.renderPanel()
            self.searchLive()  // confirms it, and refreshes the plugin counts
            var problems = reasons
            if stuck > 0 {
                problems.append("\(stuck) session\(stuck == 1 ? "" : "s") didn't close, even when forced.")
            }
            if !problems.isEmpty {
                self.panel.close()
                Dialogs.alert("Couldn't quit everything", problems.joined(separator: "\n"))
            }
        })
    }
}
