// The registry: the reducer that turns one scan into a snapshot (remembering
// what the last one held), and the object that runs scans one at a time.

import Foundation
import Testing
@testable import TrackerCore

private typealias Registry = SessionRegistry

private let t1 = "Tue Nov 10 18:00:00 2026"
private let t2 = "Tue Nov 10 19:30:00 2026"

private func claude(_ pid: Int32, start: String = t1, folder: String = "/w/app") -> ProcInfo {
    ProcInfo(pid: pid, ppid: 1, tty: nil, state: "S", start: start, program: "claude",
             args: "/x/claude --verbose", folder: folder)
}

private func record(_ pid: Int32, session: String, start: String = t1) -> ClaudeRecords.Record {
    ClaudeRecords.Record(pid: pid, sessionId: session, cwd: "/w/app", procStart: start, startedAt: nil,
                         kind: .interactive, entrypoint: "claude-vscode", status: .idle, statusUpdatedAt: nil,
                         waitingFor: nil)
}

private func reduce(_ previous: Registry.Snapshot?, _ processes: [ProcInfo],
                    _ records: [ClaudeRecords.Record] = []) -> Registry.Snapshot {
    Registry.reduce(previous: previous, processes: processes,
                    records: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }), now: 1_794_336_000)
}

// MARK: The reducer

@Test func beforeTheFirstScanTheSnapshotSaysNothingWasScanned() {
    let initial = Registry.Snapshot.initial
    #expect(!initial.scanned)
    #expect(initial.counted.isEmpty)
}

@Test func anEmptyProcessTableAfterAScanIsAConfidentZero() {
    let snapshot = reduce(nil, [])
    #expect(snapshot.scanned)
    #expect(snapshot.counted.isEmpty)
    #expect(snapshot.ended.isEmpty)
}

@Test func theSameInputsGiveEqualSnapshotsScanAfterScan() {
    let processes = [claude(100)]
    let records = [record(100, session: "a")]
    let first = reduce(nil, processes, records)
    let second = reduce(first, processes, records)
    #expect(second == first)
    #expect(reduce(second, processes.reversed(), records) == first)
}

@Test func aSessionThatVanishedIsEndedForOneScanOnly() {
    let first = reduce(nil, [claude(100)], [record(100, session: "a")])
    let second = reduce(first, [])
    #expect(second.counted.isEmpty)
    #expect(second.ended == [Registry.Ended(tool: "claude_code", pid: 100, start: t1, folder: "/w/app")])
    let third = reduce(second, [])
    #expect(third.ended.isEmpty)
}

@Test func aReusedPidIsANewSessionAndTheOldOneEnded() {
    let first = reduce(nil, [claude(42, start: t1)], [record(42, session: "a", start: t1)])
    let second = reduce(first, [claude(42, start: t2)], [record(42, session: "b", start: t2)])
    #expect(second.counted.map(\.sessionId) == ["b"])
    #expect(second.ended.map(\.start) == [t1])
}

@Test func aStillRunningSessionIsNotEnded() {
    let first = reduce(nil, [claude(100), claude(200)], [record(100, session: "a"), record(200, session: "b")])
    let second = reduce(first, [claude(200)], [record(200, session: "b")])
    #expect(second.ended.map(\.pid) == [100])
    #expect(second.counted.map(\.pid) == [200])
}

@Test func onlyCountedAndBackgroundEntriesCanEnd() {
    let server = ProcInfo(pid: 9, ppid: 1, tty: nil, state: "Ss", start: t1, program: "opencode",
                          args: "/o/opencode serve --service", folder: "/h")
    let first = reduce(nil, [server])
    #expect(first.counted.isEmpty)
    #expect(reduce(first, []).ended.isEmpty)
}

@Test func theNotCountedTallyLeavesOutBackgroundAgentsWhichAreListed() {
    let server = ProcInfo(pid: 9, ppid: 1, tty: nil, state: "Ss", start: t1, program: "opencode",
                          args: "/o/opencode serve --service", folder: "/h")
    var background = record(200, session: "b")
    background.kind = .background
    let snapshot = reduce(nil, [server, claude(200)], [background])
    #expect(snapshot.notCountedCount == 1)
    #expect(snapshot.background.map(\.pid) == [200])
}

@Test func quitRemovesAndStopPausesAtOnceUntilTheNextScan() {
    var snapshot = reduce(nil, [claude(100), claude(200)], [record(100, session: "a"), record(200, session: "b")])
    snapshot.apply(.stop, to: [100])
    #expect(snapshot.counted.first { $0.pid == 100 }?.paused == true)
    snapshot.apply(.resume, to: [100])
    #expect(snapshot.counted.first { $0.pid == 100 }?.paused == false)
    snapshot.apply(.quit, to: [100])
    #expect(snapshot.counted.map(\.pid) == [200])
    snapshot.apply(.forceQuit, to: [200])
    #expect(snapshot.counted.isEmpty)
}

// MARK: The registry object

/// Stands in for the background queue and the main queue: work runs only when
/// the test says so, so overlapping scans can be set up exactly.
private final class Queues {
    var background = [() -> Void]()
    var main = [() -> Void]()

    func dispatchBackground(_ work: @escaping () -> Void) { background.append(work) }
    func dispatchMain(_ work: @escaping () -> Void) { main.append(work) }

    func runBackground() {
        let work = background
        background = []
        work.forEach { $0() }
    }

    func runMain() {
        let work = main
        main = []
        work.forEach { $0() }
    }

    /// Runs everything until nothing is left.
    func drain() {
        while !background.isEmpty || !main.isEmpty {
            runBackground()
            runMain()
        }
    }
}

private final class Harness {
    let queues = Queues()
    var inputs = Registry.Inputs(processes: [], records: [:], now: 0)
    var failing = false
    var clock = 0.0
    var reads = 0
    var delivered = [(snapshot: Registry.Snapshot, changed: Bool)]()
    var reports = [String]()
    lazy var registry = Registry(
        source: { [unowned self] in
            self.reads += 1
            if self.failing { throw ActiveSessions.CommandFailed(description: "ps exited with 1") }
            return self.inputs
        },
        background: { [unowned self] in self.queues.dispatchBackground($0) },
        main: { [unowned self] in self.queues.dispatchMain($0) },
        onScan: { [unowned self] snapshot, changed in self.delivered.append((snapshot, changed)) },
        report: { [unowned self] in self.reports.append($0) },
        uptime: { [unowned self] in self.clock })

    func set(_ processes: [ProcInfo], _ records: [ClaudeRecords.Record] = []) {
        inputs = Registry.Inputs(processes: processes,
                                 records: Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) }), now: 0)
    }
}

@Test func aScanRunsInTheBackgroundAndDeliversOnTheMainQueue() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()
    #expect(harness.reads == 0)  // nothing ran yet: it was only queued
    #expect(!harness.registry.snapshot.scanned)
    harness.queues.runBackground()
    #expect(harness.delivered.isEmpty)  // delivery waits for the main queue
    harness.queues.runMain()
    #expect(harness.delivered.count == 1)
    #expect(harness.delivered[0].changed)
    #expect(harness.registry.snapshot.counted.map(\.pid) == [100])
}

@Test func aSecondScanWithNothingNewReportsNoChange() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()
    harness.queues.drain()
    harness.registry.refresh()
    harness.queues.drain()
    #expect(harness.delivered.map(\.changed) == [true, false])
}

@Test func aScanAskedForDuringAScanRunsRightAfterIt() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()
    harness.registry.refresh()  // while the first is queued
    harness.registry.refresh()
    harness.queues.runBackground()
    #expect(harness.reads == 1)  // only one scan at a time
    harness.queues.runMain()  // finishing it starts the one that was asked for
    harness.queues.drain()
    #expect(harness.reads == 2)  // the two asks became one more scan
    #expect(harness.delivered.count == 2)
}

@Test func aStopOrQuitDuringAScanThrowsAwayWhatItFoundAndScansAgain() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()
    harness.queues.runBackground()  // the scan has read the old table
    harness.registry.invalidate()  // Quit happened meanwhile
    harness.set([])
    harness.queues.runMain()  // its result is stale: dropped, not shown
    #expect(harness.delivered.isEmpty)
    #expect(!harness.registry.snapshot.scanned)
    harness.queues.drain()  // a fresh scan reads the new table
    #expect(harness.delivered.count == 1)
    #expect(harness.registry.snapshot.counted.isEmpty)
    #expect(harness.registry.snapshot.scanned)
}

@Test func aFailedReadKeepsWhatWasKnownAndSaysWhy() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()
    harness.queues.drain()
    harness.failing = true
    harness.registry.refresh()
    harness.queues.drain()
    #expect(harness.registry.snapshot.counted.map(\.pid) == [100])  // not wiped to zero
    #expect(harness.registry.snapshot.error?.contains("ps exited with 1") == true)
    #expect(harness.reports.count == 1)
    harness.failing = false
    harness.registry.refresh()
    harness.queues.drain()
    #expect(harness.registry.snapshot.error == nil)
}

@Test func aFailureBeforeTheFirstScanLeavesTheSnapshotUnscanned() {
    let harness = Harness()
    harness.failing = true
    harness.registry.refresh()
    harness.queues.drain()
    #expect(!harness.registry.snapshot.scanned)
    #expect(harness.registry.snapshot.error != nil)
}

@Test func applyShowsAQuitAtOnceAndTheNextScanConfirmsIt() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()
    harness.queues.drain()
    harness.registry.apply(.quit, to: [100])
    #expect(harness.registry.snapshot.counted.isEmpty)
    // The process is still shutting down when the next scan looks: it is
    // honestly there again, and the scan after that drops it.
    harness.registry.refresh()
    harness.queues.drain()
    #expect(harness.registry.snapshot.counted.map(\.pid) == [100])
    harness.set([])
    harness.registry.refresh()
    harness.queues.drain()
    #expect(harness.registry.snapshot.counted.isEmpty)
}

@Test func aScanThatNeverEndsIsGivenUpOnAndLaterScansStillRun() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()  // queued, and the test never lets it finish: a stuck command
    harness.clock = 10
    harness.registry.refresh()  // too soon to give up: only noted
    #expect(harness.queues.background.count == 1)
    harness.clock = 31
    harness.registry.refresh()  // past the timeout: another scan starts
    #expect(harness.queues.background.count == 2)
    #expect(harness.reports.count == 1)
    // The new scan finishes and shows its result; the stuck one then ends and is ignored.
    let stuck = harness.queues.background.removeFirst()
    harness.queues.runBackground()
    harness.queues.runMain()
    #expect(harness.registry.snapshot.counted.map(\.pid) == [100])
    harness.set([])
    stuck()
    harness.queues.runMain()
    #expect(harness.registry.snapshot.counted.map(\.pid) == [100])  // the old result did not replace it
    #expect(harness.delivered.count == 1)
    #expect(!harness.registry.isScanning)
}

@Test func aStaleSnapshotReadsAsNotScannedUntilTheNextScanLands() {
    let harness = Harness()
    harness.set([claude(100)], [record(100, session: "a")])
    harness.registry.refresh()
    harness.queues.drain()
    #expect(harness.registry.snapshot.scanned)
    harness.registry.markStale()
    harness.registry.refresh()
    #expect(!harness.registry.snapshot.scanned)  // the old rows are not shown while it runs
    harness.queues.drain()
    #expect(harness.registry.snapshot.scanned)
    #expect(harness.registry.snapshot.counted.map(\.pid) == [100])
}
