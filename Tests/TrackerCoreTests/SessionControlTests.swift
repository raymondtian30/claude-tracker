// Stop (pause), resume and quit for a Claude Code session's process. These
// signal real processes, so the checks matter as much as the signals.

import Foundation
import Testing
@testable import TrackerCore

private final class Signals {
    var sent = [(pid: Int32, signal: Int32)]()
    var result: Int32 = 0
    func kill(_ pid: Int32, _ signal: Int32) -> Int32 {
        sent.append((pid, signal))
        return result
    }
}

private let listedStart = "Tue Nov 10 18:46:36 2026"

/// Every pid listed with `listedStart`, as the Live tab's rows would carry.
private func listed(_ pids: [Int32]) -> [Int32: String] {
    Dictionary(uniqueKeysWithValues: pids.map { ($0, listedStart) })
}

private func claudeRunner(_ comm: String = "/Applications/Foo.app/Contents/MacOS/claude", status: Int32 = 0) -> Subprocess.Runner {
    { arguments, _ in
        #expect(arguments.prefix(4) == ["env", "TZ=UTC", "LC_ALL=C", "ps"] && arguments.last == "lstart=,comm=")
        return Subprocess.Result(status: status, stdout: status == 0 ? "\(listedStart) \(comm)\n" : "")
    }
}

/// The start time of a real process, as `send` compares it.
private func realStart(_ pid: Int32) -> [Int32: String] {
    let found = Subprocess.run(["env", "TZ=UTC", "LC_ALL=C", "ps", "-p", String(pid), "-o", "lstart="], input: nil)
    return [pid: found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
}

@Test func stopPausesAndResumeContinues() {
    let signals = Signals()
    #expect(SessionControl.send(.stop, to: 42, among: [42, 43], starts: listed([42, 43]), run: claudeRunner(), kill: signals.kill) == .done)
    #expect(SessionControl.send(.resume, to: 42, among: [42, 43], starts: listed([42, 43]), run: claudeRunner(), kill: signals.kill) == .done)

    #expect(signals.sent.map(\.pid) == [42, 42])
    #expect(signals.sent.map(\.signal) == [SIGSTOP, SIGCONT])
}

@Test func quitTerminatesAndAlsoContinuesSoAPausedOneCanAct() {
    let signals = Signals()

    #expect(SessionControl.send(.quit, to: 42, among: [42], starts: listed([42]), run: claudeRunner(), kill: signals.kill) == .done)

    // A paused process only acts on SIGTERM once it is continued.
    #expect(signals.sent.map(\.signal) == [SIGTERM, SIGCONT])
}

@Test func nothingIsSentToAProcessThatWasNotListed() {
    let signals = Signals()

    for pid: Int32 in [99, 0, 1, -5] {
        let outcome = SessionControl.send(.quit, to: pid, among: [42, 0, 1, -5], starts: listed([42, 0, 1, -5]), run: claudeRunner(), kill: signals.kill)
        if pid == 99 { #expect(outcome == .refused("That isn't one of the sessions listed.")) }
        else { #expect(outcome != .done) }
    }
    #expect(signals.sent.isEmpty)
}

@Test func nothingIsSentWhenThePidNowBelongsToAnotherProgram() {
    let signals = Signals()

    let reused = SessionControl.send(.quit, to: 42, among: [42], starts: listed([42]), run: claudeRunner("/bin/zsh"), kill: signals.kill)
    let gone = SessionControl.send(.quit, to: 42, among: [42], starts: listed([42]), run: claudeRunner("", status: 1), kill: signals.kill)

    #expect(reused == .refused("That process is no longer a Claude session."))
    #expect(gone == .refused("That process is no longer a Claude session."))
    #expect(signals.sent.isEmpty)
}

@Test func aFailedSignalIsReported() {
    let signals = Signals()
    signals.result = -1

    let outcome = SessionControl.send(.stop, to: 42, among: [42], starts: listed([42]), run: claudeRunner(), kill: signals.kill)

    guard case .refused(let reason) = outcome else { Issue.record("expected a refusal"); return }
    #expect(reason.hasPrefix("Couldn't"))
}

@Test func stopAllAndResumeAllReachEveryListedProcess() {
    let signals = Signals()

    let stopped = SessionControl.sendAll(.stop, among: [10, 11, 12], starts: listed([10, 11, 12]), run: claudeRunner(), kill: signals.kill)

    #expect(stopped == SessionControl.Tally(done: 3, refused: 0))
    #expect(signals.sent.map(\.pid) == [10, 11, 12] && Set(signals.sent.map(\.signal)) == [SIGSTOP])
}

@Test func stopAllCountsTheOnesItCouldNotReach() {
    let signals = Signals()
    let run: Subprocess.Runner = { arguments, _ in
        Subprocess.Result(status: 0, stdout: "\(listedStart) " + (arguments[5] == "11" ? "/bin/zsh\n" : "claude\n"))
    }

    let tally = SessionControl.sendAll(.stop, among: [10, 11, 12], starts: listed([10, 11, 12]), run: run, kill: signals.kill)

    #expect(tally == SessionControl.Tally(done: 2, refused: 1))
    #expect(signals.sent.map(\.pid) == [10, 12])
}

// The real thing, on a process of its own: a tiny program named `claude` that
// only sleeps, so nothing else is ever signalled. (A copy of /bin/sleep won't
// run: macOS kills copies of its own signed programs.)
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/cc")))
func stopResumeAndQuitWorkOnARealProcess() throws {
    let tmp = TempDir()
    let source = tmp.url("sleeper.c")
    writeText(source, "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n")
    let fake = tmp.url("claude")
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compile.arguments = [source.path, "-o", fake.path]
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    let child = Process()
    child.executableURL = fake
    child.currentDirectoryURL = tmp.root
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let pid = child.processIdentifier

    func mine() throws -> ActiveSessions.Proc? {
        try ActiveSessions.runningProcesses("claude").first { $0.pid == pid }
    }
    // Wait until ps can see it, with its folder.
    var found = try mine()
    for _ in 0..<50 where found == nil {
        Thread.sleep(forTimeInterval: 0.05)
        found = try mine()
    }
    #expect(found?.stopped == false)
    #expect(found.map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path }
            == tmp.root.resolvingSymlinksInPath().path)

    #expect(SessionControl.send(.stop, to: pid, among: [pid], starts: realStart(pid)) == .done)
    var paused = false
    for _ in 0..<50 where !paused {
        Thread.sleep(forTimeInterval: 0.05)
        paused = try mine()?.stopped == true
    }
    #expect(paused)

    // Quit works on a paused process too.
    #expect(SessionControl.send(.quit, to: pid, among: [pid], starts: realStart(pid)) == .done)
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
}

// MARK: - Quit: ask nicely, then force it

/// A pretend set of Claude processes: which are alive, and what ends them.
private final class World {
    var alive: Set<Int32>
    var ignoresTerm: Set<Int32> = []
    var survivesKill: Set<Int32> = []
    var sent = [(pid: Int32, signal: Int32)]()
    var slept = 0.0
    init(alive: Set<Int32>) { self.alive = alive }

    var run: Subprocess.Runner {
        { arguments, _ in
            let pid = Int32(arguments[5]) ?? 0
            return self.alive.contains(pid) ? Subprocess.Result(status: 0, stdout: "\(listedStart) claude\n") : Subprocess.Result(status: 1)
        }
    }
    var kill: SessionControl.Kill {
        { pid, signal in
            self.sent.append((pid, signal))
            if signal == SIGTERM, !self.ignoresTerm.contains(pid) { self.alive.remove(pid) }
            if signal == SIGKILL, !self.survivesKill.contains(pid) { self.alive.remove(pid) }
            return 0
        }
    }
    var sleep: (Double) -> Void { { self.slept += $0 } }
}

@Test func quitClosesASessionThatShutsDownWhenAsked() {
    let world = World(alive: [42])

    let results = SessionControl.quit([42], among: [42], starts: listed([42]), run: world.run, kill: world.kill, sleep: world.sleep)

    #expect(results == [42: .closed])
    #expect(world.sent.map(\.signal) == [SIGTERM, SIGCONT])  // never the hard kill
}

@Test func quitForcesASessionThatIgnoresTheRequest() {
    let world = World(alive: [42])
    world.ignoresTerm = [42]

    let results = SessionControl.quit([42], among: [42], starts: listed([42]), patience: 3, run: world.run, kill: world.kill, sleep: world.sleep)

    #expect(results == [42: .forced])
    #expect(world.sent.map(\.signal) == [SIGTERM, SIGCONT, SIGKILL])
    #expect(world.slept >= 3)  // it was given its three seconds first
}

@Test func quitSaysSoWhenNothingEndsTheSession() {
    let world = World(alive: [42])
    world.ignoresTerm = [42]
    world.survivesKill = [42]

    #expect(SessionControl.quit([42], among: [42], starts: listed([42]), run: world.run, kill: world.kill, sleep: world.sleep) == [42: .stuck])
}

@Test func quitAllHandlesEachSessionOnItsOwn() {
    let world = World(alive: [10, 11, 12])
    world.ignoresTerm = [11]

    let results = SessionControl.quit([10, 11, 12, 99], among: [10, 11, 12], starts: listed([10, 11, 12]), run: world.run, kill: world.kill,
                                      sleep: world.sleep)

    #expect(results[10] == .closed && results[11] == .forced && results[12] == .closed)
    #expect(results[99] == .refused("That isn't one of the sessions listed."))
    #expect(!world.sent.contains { $0.pid == 99 })
    #expect(world.sent.filter { $0.signal == SIGKILL }.map(\.pid) == [11])  // only the one that needed it
}

@Test func quitAllWaitsOnceForEveryoneNotOneAfterAnother() {
    let world = World(alive: [1 + 1, 3, 4])  // none ends by itself: ignore the request
    world.ignoresTerm = [2, 3, 4]

    _ = SessionControl.quit([2, 3, 4], among: [2, 3, 4], starts: listed([2, 3, 4]), patience: 3, run: world.run, kill: world.kill, sleep: world.sleep)

    #expect(world.slept < 3.5)  // three seconds in all, not nine
}

@Test func theQuitQuestionNamesWhatWillClose() {
    let one = SessionControl.quitQuestion([
        ActiveSessions.Session(label: "~/app", tokens: 1, cwd: "/app", pid: 42, title: "Active plugins", kind: "VS Code"),
    ])
    #expect(one.title == "Quit this session?")
    #expect(one.message.contains("Active plugins") && one.message.contains("VS Code") && one.message.contains("process 42"))
    #expect(one.message.contains("force-quit") && one.message.contains("lost"))
    #expect(one.confirm == "Quit Session")

    let many = SessionControl.quitQuestion((1...10).map {
        ActiveSessions.Session(label: "~/app", tokens: 1, cwd: "/app", pid: Int32($0 + 1), title: "Chat \($0)")
    })
    #expect(many.title == "Quit all 10 sessions?")
    #expect(many.message.contains("Chat 1") && many.message.contains("Chat 8") && !many.message.contains("Chat 9"))
    #expect(many.message.contains("and 2 more"))
    #expect(many.confirm == "Quit All")
}

// A session that ignores the request to quit, as a real process can: the
// force quit has to end it. Again a tiny stand-in named `claude`.
@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/cc")))
func quitForcesARealProcessThatIgnoresTheRequest() throws {
    let tmp = TempDir()
    let source = tmp.url("stubborn.c")
    writeText(source, "#include <signal.h>\n#include <unistd.h>\nint main(void) { signal(SIGTERM, SIG_IGN); sleep(60); return 0; }\n")
    let fake = tmp.url("claude")
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compile.arguments = [source.path, "-o", fake.path]
    try compile.run()
    compile.waitUntilExit()
    try #require(compile.terminationStatus == 0)
    let child = Process()
    child.executableURL = fake
    try child.run()
    defer { if child.isRunning { child.terminate(); kill(child.processIdentifier, SIGKILL) } }
    let pid = child.processIdentifier
    // Wait until ps can see it as claude (it may not have started executing yet).
    for _ in 0..<50 where !SessionControl.isClaude(pid, run: Subprocess.run) { Thread.sleep(forTimeInterval: 0.05) }
    Thread.sleep(forTimeInterval: 0.2)  // and has set up its signal handling

    let results = SessionControl.quit([pid], among: [pid], starts: realStart(pid), patience: 0.4, interval: 0.05)

    #expect(results == [pid: .forced])
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
}

// MARK: The start time is checked too (a pid can be reused by another `claude`)

private func identityRunner(_ start: String, comm: String = "/x/native-binary/claude",
                            status: Int32 = 0) -> Subprocess.Runner {
    { arguments, _ in
        #expect(arguments.prefix(4) == ["env", "TZ=UTC", "LC_ALL=C", "ps"] && arguments.last == "lstart=,comm=")
        return Subprocess.Result(status: status, stdout: status == 0 ? "\(start) \(comm)\n" : "")
    }
}

@Test func aMatchingStartTimeAllowsTheSignal() {
    let signals = Signals()
    let outcome = SessionControl.send(.stop, to: 42, among: [42], starts: [42: listedStart],
                                      run: identityRunner(listedStart), kill: signals.kill)
    #expect(outcome == .done)
    #expect(signals.sent.map(\.signal) == [SIGSTOP])
}

@Test func aReusedPidThatIsAnotherClaudeIsNotSignalled() {
    let signals = Signals()
    let outcome = SessionControl.send(.quit, to: 42, among: [42], starts: [42: listedStart],
                                      run: identityRunner("Tue Nov 10 19:30:00 2026"), kill: signals.kill)
    #expect(outcome == .refused("That isn't the session that was listed any more."))
    #expect(signals.sent.isEmpty)
}

@Test func theStartTimeCheckIgnoresPaddingOfTheDay() {
    let signals = Signals()
    let outcome = SessionControl.send(.stop, to: 42, among: [42], starts: [42: "Mon Nov 9 07:19:59 2026"],
                                      run: identityRunner("Mon Nov  9 07:19:59 2026"), kill: signals.kill)
    #expect(outcome == .done)
}

@Test func withAStartTimeAnotherProgramOrAGoneProcessIsStillRefused() {
    let signals = Signals()
    let other = SessionControl.send(.quit, to: 42, among: [42], starts: [42: listedStart],
                                    run: identityRunner(listedStart, comm: "/bin/zsh"), kill: signals.kill)
    let gone = SessionControl.send(.quit, to: 42, among: [42], starts: [42: listedStart],
                                   run: identityRunner("", status: 1), kill: signals.kill)
    #expect(other == .refused("That process is no longer a Claude session."))
    #expect(gone == .refused("That process is no longer a Claude session."))
    #expect(signals.sent.isEmpty)
}

@Test func quitCountsAReusedPidAsClosedAndNeverForceQuitsIt() {
    let signals = Signals()
    var calls = 0
    // First look: the listed process. After the quit request: the pid belongs
    // to another claude that started later.
    let runner: Subprocess.Runner = { arguments, _ in
        calls += 1
        let start = calls == 1 ? listedStart : "Tue Nov 10 19:30:00 2026"
        return Subprocess.Result(stdout: "\(start) /x/claude\n")
    }
    let results = SessionControl.quit([42], among: [42], starts: [42: listedStart], patience: 1, interval: 0.1,
                                      run: runner, kill: signals.kill, sleep: { _ in })
    #expect(results == [42: .closed])
    #expect(signals.sent.map(\.signal) == [SIGTERM, SIGCONT])  // no SIGKILL
}

@Test func sendAllPassesTheStartTimesOn() {
    let signals = Signals()
    let tally = SessionControl.sendAll(.stop, among: [41, 42], starts: [41: listedStart, 42: listedStart],
                                       run: { arguments, _ in
        let pid = arguments[arguments.firstIndex(of: "-p")! + 1]
        return Subprocess.Result(stdout: (pid == "41" ? listedStart : "Tue Nov 10 19:30:00 2026") + " /x/claude\n")
    }, kill: signals.kill)
    #expect(tally == SessionControl.Tally(done: 1, refused: 1))
    #expect(signals.sent.map(\.pid) == [41])
}

@Test func aSessionListedWithoutAStartTimeIsNotSignalled() {
    let signals = Signals()
    let outcome = SessionControl.send(.quit, to: 42, among: [42], starts: [:], run: identityRunner(listedStart),
                                      kill: signals.kill)
    #expect(outcome == .refused("That isn't the session that was listed any more."))
    #expect(signals.sent.isEmpty)
}
