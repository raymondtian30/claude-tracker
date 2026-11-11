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
        /// End it for certain (SIGKILL), when it ignored `quit`.
        case forceQuit
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
    public static func send(_ action: Action, to pid: Int32, among known: [Int32], starts: [Int32: String] = [:],
                            run: Subprocess.Runner = Subprocess.run,
                            kill: Kill = { Darwin.kill($0, $1) }) -> Outcome {
        // 0, 1 and negative ids mean "every process", launchd, or a whole group.
        guard pid > 1, known.contains(pid) else {
            return .refused("That isn't one of the sessions listed.")
        }
        switch identity(of: pid, start: starts[pid], run: run) {
        case .matches: break
        case .notClaude: return .refused("That process is no longer a Claude session.")
        case .startDiffers: return .refused("That isn't the session that was listed any more.")
        }
        // A paused process only acts on SIGTERM once it is continued.
        let signals: [Int32]
        switch action {
        case .stop: signals = [SIGSTOP]
        case .resume: signals = [SIGCONT]
        case .quit: signals = [SIGTERM, SIGCONT]
        case .forceQuit: signals = [SIGKILL]
        }
        for signal in signals where kill(pid, signal) != 0 {
            return .refused("Couldn't reach that process (error \(errno)).")
        }
        return .done
    }

    /// Whether `pid` is a running `claude` process right now, and, when its
    /// start time (`ps` text under `TZ=UTC`) is given, the same one that was
    /// listed: a process id can be reused by a later `claude`.
    static func isClaude(_ pid: Int32, start: String? = nil, run: Subprocess.Runner) -> Bool {
        identity(of: pid, start: start, run: run) == .matches
    }

    enum Identity: Equatable {
        case matches
        case notClaude
        case startDiffers
    }

    static func identity(of pid: Int32, start: String?, run: Subprocess.Runner) -> Identity {
        guard let expected = start else {
            let found = run(["ps", "-p", String(pid), "-o", "comm="], nil)
            let named = found.status == 0
                && ActiveSessions.basename(found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == program
            return named ? .matches : .notClaude
        }
        let found = run(["env", "TZ=UTC", "ps", "-p", String(pid), "-o", "lstart=,comm="], nil)
        // Five words of start time, then the program path.
        let parts = found.stdout.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard found.status == 0, parts.count == 6,
              ActiveSessions.basename(parts[5].trimmingCharacters(in: .whitespacesAndNewlines)) == program
        else { return .notClaude }
        return ProcessTable.sameStart(parts[0..<5].joined(separator: " "), expected) ? .matches : .startDiffers
    }

    /// Waits until `pid` is no longer a `claude` process (it can take a moment
    /// to shut down after Quit), up to `timeout` seconds. False if it is still there.
    public static func waitUntilGone(_ pid: Int32, start: String? = nil, timeout: Double = 3, interval: Double = 0.1,
                                     run: Subprocess.Runner = Subprocess.run,
                                     sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> Bool {
        var waited = 0.0
        while isClaude(pid, start: start, run: run) {
            if waited >= timeout - 0.000_001 { return false }
            sleep(interval)
            waited += interval
        }
        return true
    }

    /// How ending a session went.
    public enum QuitOutcome: Equatable {
        /// It shut down when asked.
        case closed
        /// It ignored the request for `patience` seconds, so it was force-quit.
        case forced
        /// Nothing ended it.
        case stuck
        /// Nothing was sent: not one of the listed sessions, or no longer Claude.
        case refused(String)
    }

    /// Ends the sessions with these process ids. Each is asked to quit (like
    /// closing it from a terminal); the ones still there after `patience`
    /// seconds, all waited for together, are force-quit, then given two more
    /// seconds. Only a listed, still-running `claude` process is ever signalled.
    public static func quit(_ pids: [Int32], among known: [Int32], starts: [Int32: String] = [:],
                            patience: Double = 3, interval: Double = 0.1,
                            run: Subprocess.Runner = Subprocess.run, kill: Kill = { Darwin.kill($0, $1) },
                            sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> [Int32: QuitOutcome] {
        var results = [Int32: QuitOutcome]()
        var asked = [Int32]()
        for pid in pids {
            switch send(.quit, to: pid, among: known, starts: starts, run: run, kill: kill) {
            case .done: asked.append(pid)
            case .refused(let reason): results[pid] = .refused(reason)
            }
        }
        /// The ones of `pids` still running `claude` after up to `timeout` seconds.
        func stillThere(_ pids: [Int32], _ timeout: Double) -> [Int32] {
            var remaining = pids
            var waited = 0.0
            while true {
                remaining = remaining.filter { isClaude($0, start: starts[$0], run: run) }
                if remaining.isEmpty || waited >= timeout - 0.000_001 { return remaining }
                sleep(interval)
                waited += interval
            }
        }
        let ignored = stillThere(asked, patience)
        for pid in asked where !ignored.contains(pid) { results[pid] = .closed }
        if !ignored.isEmpty {
            for pid in ignored { _ = send(.forceQuit, to: pid, among: known, starts: starts, run: run, kill: kill) }
            let survivors = stillThere(ignored, 2)
            for pid in ignored { results[pid] = survivors.contains(pid) ? .stuck : .forced }
        }
        return results
    }

    /// The "are you sure" box for ending `sessions`: its title, what it says
    /// and what the button that goes ahead is called.
    public static func quitQuestion(_ sessions: [ActiveSessions.Session]) -> (title: String, message: String, confirm: String) {
        func describe(_ session: ActiveSessions.Session) -> String {
            let folder = PanelModel.folderParts(session.label).name
            let details = [session.kind, session.pid.map { "process \($0)" }].compactMap { $0 }.joined(separator: ", ")
            return "\(session.title ?? folder) (\(details))"
        }
        if sessions.count == 1, let only = sessions.first {
            return ("Quit this session?",
                    "\(describe(only)) will be closed.\n\nAnything Claude is in the middle of is lost. "
                        + "If it doesn't close within 3 seconds, it is force-quit.",
                    "Quit Session")
        }
        let listed = sessions.prefix(8).map { "• " + describe($0) }
        let more = sessions.count > 8 ? ["…and \(sessions.count - 8) more"] : []
        return ("Quit all \(sessions.count) sessions?",
                (listed + more).joined(separator: "\n") + "\n\nAnything Claude is in the middle of is lost. "
                    + "Any that don't close within 3 seconds are force-quit.",
                "Quit All")
    }

    public struct Tally: Equatable {
        public var done: Int
        public var refused: Int
    }

    /// `send` to each of `pids`, all of which must be listed ones.
    public static func sendAll(_ action: Action, among pids: [Int32], starts: [Int32: String] = [:],
                               run: Subprocess.Runner = Subprocess.run,
                               kill: Kill = { Darwin.kill($0, $1) }) -> Tally {
        var tally = Tally(done: 0, refused: 0)
        for pid in pids {
            if send(action, to: pid, among: pids, starts: starts, run: run, kill: kill) == .done {
                tally.done += 1
            } else {
                tally.refused += 1
            }
        }
        return tally
    }
}
