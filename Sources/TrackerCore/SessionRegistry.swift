import Foundation

/// The session registry. Three layers, each calling the one below:
///
/// 1. `SessionRules.scan`: which processes are sessions (pure, no memory).
/// 2. `SessionRegistry.reduce`: a scan plus the previous snapshot, so a
///    session that has just gone can be listed as ended (pure).
/// 3. `SessionRegistry` itself: runs scans one at a time off the main queue,
///    throws away a scan that a Stop or Quit overtook, and keeps the latest
///    snapshot. Everything the Live tab shows or does reads that snapshot, so
///    the count, the rows and the Stop all / Quit all targets cannot disagree.
///
/// All of the object's state is touched on the main queue only; the scan
/// itself gets copies (the previous snapshot and the enrichment cache) and
/// hands its result back through the `main` queue, so no lock is needed.
public final class SessionRegistry {
    /// A session seen in the previous scan and gone in this one. Listed for
    /// one scan, in diagnostics only.
    public struct Ended: Equatable {
        public var tool: String
        public var pid: Int32
        public var start: String
        public var folder: String?
    }

    public struct Snapshot: Equatable {
        /// False until a scan has finished: the Live tab then says it is
        /// looking, instead of showing a count of 0.
        public var scanned: Bool
        public var scan: SessionRules.Scan
        public var ended: [Ended]
        /// Tokens, titles, plugins and subagents, by process id.
        public var details: [Int32: SessionDetails]
        /// What each plugin did in open sessions; nil when not asked for.
        public var pluginRows: [Plugins.Row]?
        /// Why the last scan failed, if it did; what was known before stays.
        public var error: String?

        public static let initial = Snapshot(scanned: false, scan: SessionRules.Scan(entries: [], staleRecords: []),
                                             ended: [], details: [:], pluginRows: nil, error: nil)

        /// The sessions in "Sessions (N)".
        public var counted: [SessionRules.Entry] { scan.entries.filter(\.counted) }
        /// Background agents, listed on the Live tab and not counted.
        public var background: [SessionRules.Entry] { scan.entries.filter { $0.role == .background } }
        /// Tool processes that are neither counted nor listed: servers,
        /// processes with no terminal, other tools' children.
        public var notCountedCount: Int { scan.entries.filter { !$0.counted && $0.role != .background }.count }

        /// What Stop, Resume or Quit did to the processes with these ids,
        /// shown at once; the next scan confirms it.
        public mutating func apply(_ action: SessionControl.Action, to pids: Set<Int32>) {
            switch action {
            case .stop, .resume:
                for index in scan.entries.indices where pids.contains(scan.entries[index].pid) {
                    scan.entries[index].paused = action == .stop
                }
            case .quit, .forceQuit:
                scan.entries.removeAll { pids.contains($0.pid) }
                details = details.filter { !pids.contains($0.key) }
            }
        }
    }

    /// What one scan reads: the process table, Claude's records and the time.
    public struct Inputs {
        public var processes: [ProcInfo]
        public var records: [Int32: ClaudeRecords.Record]
        public var now: Double

        public init(processes: [ProcInfo], records: [Int32: ClaudeRecords.Record], now: Double) {
            self.processes = processes
            self.records = records
            self.now = now
        }
    }

    public typealias Source = () throws -> Inputs
    /// Looks up tokens, titles and so on for the sessions a scan found.
    public typealias Enrich = (_ scan: SessionRules.Scan, _ cache: inout EnrichmentCache,
                               _ withPlugins: Bool) -> EnrichmentResult
    /// Runs a piece of work later, off the main queue or on it.
    public typealias Dispatch = (@escaping () -> Void) -> Void

    public private(set) var snapshot = Snapshot.initial
    /// Whether scans also work out what each plugin did (only the views that
    /// show plugins need it). Read when a scan starts.
    public var withPlugins = false

    private let source: Source
    private let enrich: Enrich
    private let background: Dispatch
    private let main: Dispatch
    private let onScan: (Snapshot, _ changed: Bool) -> Void
    private let report: (String) -> Void
    private var cache = EnrichmentCache()
    private var scanning = false
    private var scanAgain = false
    private var generation = 0
    /// Numbers each scan, so the result of one that was given up on (see
    /// `scanTimeout`) is ignored when it finally arrives.
    private var scanSerial = 0
    private var scanStartedAt = 0.0
    private let uptime: () -> Double

    /// A scan running longer than this is given up on, so one stuck command
    /// (an `lsof` waiting on a dead network folder) cannot stop all later scans.
    public static let scanTimeout = 30.0

    /// `onScan` is called on the main queue after every scan that was kept,
    /// with whether the snapshot differs from the one before.
    public init(source: @escaping Source, enrich: @escaping Enrich = { _, _, _ in EnrichmentResult() },
                background: @escaping Dispatch, main: @escaping Dispatch,
                onScan: @escaping (Snapshot, Bool) -> Void, report: @escaping (String) -> Void = { _ in },
                uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        self.source = source
        self.enrich = enrich
        self.background = background
        self.main = main
        self.onScan = onScan
        self.report = report
    }

    /// Whether a scan is running. Main queue only.
    public var isScanning: Bool { scanning }

    /// Starts a scan, or, if one is running, asks for another right after it.
    /// Main queue only.
    public func refresh() {
        if scanning {
            guard uptime() - scanStartedAt > Self.scanTimeout else {
                scanAgain = true
                return
            }
            // Stuck: let go of it. Its thread stays blocked, but its result,
            // if it ever comes, is dropped.
            report("A scan took more than \(Int(Self.scanTimeout)) seconds; starting another.")
            scanSerial += 1
            scanning = false
            scanAgain = false
        }
        scanning = true
        scanStartedAt = uptime()
        scanSerial += 1
        let serial = scanSerial
        let started = generation
        let previous = snapshot
        var workingCache = cache
        let plugins = withPlugins
        background { [self] in
            let outcome: Result<(Snapshot, EnrichmentCache), Error>
            do {
                let inputs = try source()
                var next = Self.reduce(previous: previous, processes: inputs.processes, records: inputs.records,
                                       now: inputs.now)
                let enriched = enrich(next.scan, &workingCache, plugins)
                next.details = enriched.details
                next.pluginRows = enriched.pluginRows
                outcome = .success((next, workingCache))
            } catch {
                outcome = .failure(error)
            }
            main { self.finish(outcome, started: started, serial: serial) }
        }
    }

    /// Something (a Stop or Quit) made what a running scan found out of date:
    /// that scan's result is dropped and a new one starts. Main queue only.
    public func invalidate() {
        generation += 1
    }

    /// Shows what an action did at once. Main queue only.
    public func apply(_ action: SessionControl.Action, to pids: Set<Int32>) {
        snapshot.apply(action, to: pids)
    }

    private func finish(_ outcome: Result<(Snapshot, EnrichmentCache), Error>, started: Int, serial: Int) {
        guard serial == scanSerial else { return }  // given up on, and replaced
        scanning = false
        if started != generation {
            scanAgain = false
            refresh()
            return
        }
        let before = snapshot
        switch outcome {
        case .success(let (next, newCache)):
            cache = newCache
            snapshot = next
        case .failure(let error):
            let message = "Couldn't list sessions: \(error)"
            report(message)
            snapshot.error = message
        }
        onScan(snapshot, snapshot != before)
        if scanAgain {
            scanAgain = false
            refresh()
        }
    }

    /// The snapshot after a scan: the rules' answer, plus the sessions in
    /// `previous` that are not in it any more. Pure.
    public static func reduce(previous: Snapshot?, processes: [ProcInfo], records: [Int32: ClaudeRecords.Record],
                              now: Double) -> Snapshot {
        let scan = SessionRules.scan(processes: processes, records: records, now: now)
        func identity(_ entry: SessionRules.Entry) -> String { "\(entry.tool)|\(entry.pid)|\(entry.start)" }
        let present = Set(scan.entries.map(identity))
        var ended = [Ended]()
        for entry in previous?.scan.entries ?? []
        where (entry.counted || entry.role == .background) && !present.contains(identity(entry)) {
            ended.append(Ended(tool: entry.tool, pid: entry.pid, start: entry.start, folder: entry.folder))
        }
        return Snapshot(scanned: true, scan: scan, ended: ended, details: [:], pluginRows: nil, error: nil)
    }
}
