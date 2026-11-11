import AppKit
import TrackerCore

/// Stop, Resume and Quit on the Live tab: signals to Claude Code processes.
/// `SessionControl` checks that each one is a listed, still-running `claude`
/// process before anything is sent. Every action is logged (with process ids
/// only) to ~/Library/Logs/ClaudeTracker/agent.err.log, to look at if one
/// doesn't do what it should.
extension AppController {
    /// The process ids of the sessions the Live tab can stop or quit right
    /// now: the counted Claude Code sessions, the same ones its rows show.
    var livePids: [Int32] { liveView.controllablePids }

    /// Pause or resume `pids`; the tab shows the change at once.
    func pauseOrResume(_ action: SessionControl.Action, _ pids: [Int32]) {
        guard !pids.isEmpty else { return }
        let live = liveView
        let known = live.controllablePids
        let starts = live.starts
        let verb = action == .stop ? "pause" : "resume"
        // Anything the Live tab learned before this click may now be wrong; a
        // scan already running must not put the old list back.
        registry.invalidate()
        inBackground({
            pids.map { SessionControl.send(action, to: $0, among: known, starts: starts) }
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
            self.registry.apply(action, to: worked)
            self.registry.invalidate()
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
        let live = liveView
        let sessions = pids.compactMap { pid in live.controllable.first { $0.pid == pid } }
        guard !sessions.isEmpty else { return }
        let question = SessionControl.quitQuestion(sessions)
        guard Dialogs.confirmDestructive(title: question.title, message: question.message,
                                         confirm: question.confirm) else { return }
        let known = live.controllablePids
        let starts = live.starts
        registry.invalidate()
        inBackground({
            SessionControl.quit(sessions.compactMap(\.pid), among: known, starts: starts)
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
            self.registry.apply(.quit, to: gone)
            self.registry.invalidate()
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
