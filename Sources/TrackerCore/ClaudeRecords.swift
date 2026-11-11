import Foundation

/// Claude Code's own record of each running process: `~/.claude/sessions/<pid>.json`.
/// The format is Claude Code's, not documented, and can change, so a value
/// this code doesn't know is kept as raw text and shown as Unknown, never
/// guessed. Only `<pid>.json` files are read; the `<pid>.<hash>.key` files
/// next to them are never opened.
public enum ClaudeRecords {
    /// What kind of process the record is for. `bg`, `daemon` and
    /// `daemon-worker` are background agents, not chats someone works in.
    public enum RecordKind: Equatable {
        case interactive
        case background
        case daemon
        case daemonWorker
        case unrecognized(String)
        case missing
    }

    /// What Claude Code says the session is doing.
    public enum RecordStatus: Equatable {
        case busy
        case idle
        case waiting
        /// Seen in Claude Code's code, never in a record; kept apart so it
        /// is not mistaken for busy.
        case shell
        case unrecognized(String)
        case missing
    }

    public struct Record: Equatable {
        public var pid: Int32
        public var sessionId: String
        public var cwd: String
        /// When the process started, as UTC text ("Tue Nov 10 18:46:36 2026").
        public var procStart: String?
        /// When the record was made (Unix seconds); a second or so after the
        /// process started, so not its start time.
        public var startedAt: Double?
        public var kind: RecordKind
        public var entrypoint: String?
        public var status: RecordStatus
        /// When the status last changed (Unix seconds), if recorded.
        public var statusUpdatedAt: Double?
        /// What it waits for ("input needed"), as one short line.
        public var waitingFor: String?
    }

    /// Every readable record in `dir`, by process id.
    public static func read(dir: URL = ActiveSessions.claudeSessionsDir) -> [Int32: Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var found = [Int32: Record]()
        for name in names where isRecordName(name) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let record = decode(data, fileName: name) else { continue }
            found[record.pid] = record
        }
        return found
    }

    /// `<digits>.json`, nothing else.
    static func isRecordName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return !stem.isEmpty && stem.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The record in `data`, or nil when it isn't valid, isn't for the process
    /// its file name says (a leftover), has no folder, or has an id that is
    /// not a plain session id (it becomes part of a log's file name).
    static func decode(_ data: Data, fileName: String) -> Record? {
        guard isRecordName(fileName), let filePid = Int32(fileName.dropLast(5)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              object.int("pid") == Int(filePid),
              let cwd = object.string("cwd"), !cwd.isEmpty,
              let id = object.string("sessionId"), !id.isEmpty,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        let milliseconds = JSON.double(object["statusUpdatedAt"]) ?? JSON.double(object["updatedAt"])
        return Record(pid: filePid, sessionId: id, cwd: cwd, procStart: object.string("procStart"),
                      startedAt: JSON.double(object["startedAt"]).map { $0 / 1000 },
                      kind: kind(object.string("kind")), entrypoint: object.string("entrypoint"),
                      status: status(object.string("status")),
                      statusUpdatedAt: milliseconds.map { $0 / 1000 },
                      waitingFor: ActiveSessions.oneLine(object.string("waitingFor")))
    }

    static func kind(_ raw: String?) -> RecordKind {
        switch raw {
        case nil: return .missing
        case "interactive": return .interactive
        case "bg": return .background
        case "daemon": return .daemon
        case "daemon-worker": return .daemonWorker
        case let other?: return .unrecognized(other)
        }
    }

    static func status(_ raw: String?) -> RecordStatus {
        switch raw {
        case nil: return .missing
        case "busy": return .busy
        case "idle": return .idle
        case "waiting": return .waiting
        case "shell": return .shell
        case let other?: return .unrecognized(other)
        }
    }
}
