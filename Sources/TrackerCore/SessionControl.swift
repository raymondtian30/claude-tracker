import Foundation

/// Pausing, resuming and ending a Claude Code session from the Live tab, by
/// signalling its process. A signal to the wrong process does real harm, so a
/// process is only signalled if it is one the Live tab listed, and if it is
/// still a `claude` process right now (a process id can be reused once the
/// old process is gone).
public enum SessionControl {
    public enum Action: Equatable {
        /// Pause it (SIGSTOP). Nothing is lost; Resume carries on.
        case stop
        /// Carry on after Stop (SIGCONT).
        case resume
        /// End it (SIGTERM, the same as closing it from a terminal).
        case quit
    }

    public enum Outcome: Equatable {
        case done
        /// Nothing was sent, or it couldn't be: the reason, in a sentence.
        case refused(String)
    }

    /// `kill(2)`: the process id and the signal; 0 when it worked.
    public typealias Kill = (_ pid: Int32, _ signal: Int32) -> Int32

    public static let program = "claude"

    /// Sends `action` to `pid`, if `pid` is among `known` (the sessions the
    /// Live tab shows) and still runs `claude`.
    public static func send(_ action: Action, to pid: Int32, among known: [Int32],
                            run: Subprocess.Runner = Subprocess.run,
                            kill: Kill = { Darwin.kill($0, $1) }) -> Outcome {
        // 0, 1 and negative ids mean "every process", launchd, or a whole group.
        guard pid > 1, known.contains(pid) else {
            return .refused("That isn't one of the sessions listed.")
        }
        let found = run(["ps", "-p", String(pid), "-o", "comm="], nil)
        let name = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.status == 0, ActiveSessions.basename(name) == program else {
            return .refused("That process is no longer a Claude session.")
        }
        // A paused process only acts on SIGTERM once it is continued.
        let signals: [Int32]
        switch action {
        case .stop: signals = [SIGSTOP]
        case .resume: signals = [SIGCONT]
        case .quit: signals = [SIGTERM, SIGCONT]
        }
        for signal in signals where kill(pid, signal) != 0 {
            return .refused("Couldn't reach that process (error \(errno)).")
        }
        return .done
    }

    public struct Tally: Equatable {
        public var done: Int
        public var refused: Int
    }

    /// `send` to each of `pids`, all of which must be listed ones.
    public static func sendAll(_ action: Action, among pids: [Int32],
                               run: Subprocess.Runner = Subprocess.run,
                               kill: Kill = { Darwin.kill($0, $1) }) -> Tally {
        var tally = Tally(done: 0, refused: 0)
        for pid in pids {
            if send(action, to: pid, among: pids, run: run, kill: kill) == .done {
                tally.done += 1
            } else {
                tally.refused += 1
            }
        }
        return tally
    }
}
