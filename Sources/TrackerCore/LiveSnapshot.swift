import Foundation

/// What the Live tab shows, cut from the registry's snapshot for the tools of
/// the current view. The registry scans all four tools, so changing the view
/// only filters what is drawn; it never needs a new scan, and it never shows
/// a count of 0 that is only a missing scan (`scanned` says whether there was
/// one). The count, the rows and the Stop all / Quit all targets all come
/// from this one value.
public struct LiveSnapshot: Equatable {
    /// False until a scan has finished.
    public var scanned: Bool
    /// The counted sessions of the view's tools, in the registry's order.
    public var sessions: [ActiveSessions.Session]
    /// Background agents of the view's tools: listed, not counted.
    public var background: [ActiveSessions.Session]
    /// Processes of the view's tools that are neither counted nor listed: a
    /// server, a helper, or a process with no terminal.
    public var notCounted: Int
    /// nil when the view has no plugins to show.
    public var plugins: [Plugins.Row]?
    /// Why the last scan failed, if it did.
    public var error: String?

    public init(scanned: Bool = false, sessions: [ActiveSessions.Session] = [],
                background: [ActiveSessions.Session] = [], notCounted: Int = 0, plugins: [Plugins.Row]? = nil,
                error: String? = nil) {
        self.scanned = scanned
        self.sessions = sessions
        self.background = background
        self.notCounted = notCounted
        self.plugins = plugins
        self.error = error
    }

    /// The part of `snapshot` that belongs to `tools`. `home` is for tests.
    public init(_ snapshot: SessionRegistry.Snapshot, tools: [String], home: String? = nil) {
        func session(_ entry: SessionRules.Entry) -> ActiveSessions.Session {
            let details = snapshot.details[entry.pid]
            let state = details?.state ?? entry.state
            let since = details?.since ?? entry.since
            let status: String?
            switch state {
            case .active: status = "busy"
            case .idle: status = "idle"
            case .waiting: status = "waiting"
            case .unknown: status = nil
            }
            let kind = ActiveSessions.kindLabel(entrypoint: entry.entrypoint)
                ?? (entry.terminal != nil ? "Terminal" : nil)
            return ActiveSessions.Session(
                label: entry.folder.map { ActiveSessions.displayName($0, home: home) } ?? "unknown folder",
                tokens: details?.tokens, cwd: entry.folder, log: details?.log, plugins: details?.plugins,
                pid: entry.pid, stopped: entry.paused, status: status, since: since,
                title: details?.title, kind: kind,
                tool: entry.tool, state: state, waitingFor: entry.waitingFor, start: entry.start,
                subagents: details?.subagents ?? [])
        }
        let inView = snapshot.scan.entries.filter { tools.contains($0.tool) }
        self.init(scanned: snapshot.scanned,
                  sessions: inView.filter(\.counted).map(session),
                  background: inView.filter { $0.role == .background }.map(session),
                  notCounted: inView.filter { !$0.counted && $0.role != .background }.count,
                  // Plugins belong to Claude Code: another tool's view has no plugin card,
                  // even if the last scan worked them out for a view that did.
                  plugins: tools.contains("claude_code") ? snapshot.pluginRows : nil, error: snapshot.error)
    }

    /// The sessions Stop, Resume and Quit may act on.
    public var controllable: [ActiveSessions.Session] { sessions.filter(\.isControllable) }

    /// Their process ids.
    public var controllablePids: [Int32] { controllable.compactMap(\.pid) }

    /// Their start times, which Stop, Resume and Quit check before signalling.
    public var starts: [Int32: String] {
        Dictionary(uniqueKeysWithValues: controllable.compactMap { session in
            session.pid.flatMap { pid in session.start.map { (pid, $0) } }
        })
    }
}
