import Foundation

/// The subagents a Claude Code session has started with its Agent tool. They
/// are not processes and have no record: each has a log and a small metadata
/// file under `<project folder>/<sessionId>/subagents/`. A subagent is running
/// when its metadata does not say it finished. (Only `finished: true` has been
/// seen; the value for a running one is the rule's open point.)
public enum Subagents {
    /// The running subagents of session `sessionId`, in file-name order. An
    /// unreadable folder or file leaves out what it would have listed.
    /// `cache` remembers the ones that finished, since that does not go back.
    public static func running(projectDir: URL, sessionId: String, cache: inout EnrichmentCache) -> [Subagent] {
        let dir = projectDir.appendingPathComponent(sessionId).appendingPathComponent("subagents")
        let suffix = ".meta.json"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(suffix) }
            .sorted()
        var found = [Subagent]()
        for name in names {
            let url = dir.appendingPathComponent(name)
            if cache.finishedSubagents.contains(url.path) { continue }
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { continue }
            if object["finished"] as? Bool == true {
                cache.finishedSubagents.insert(url.path)
                continue
            }
            found.append(Subagent(id: String(name.dropLast(suffix.count)),
                                  type: object.string("agentType") ?? "agent",
                                  description: ActiveSessions.oneLine(object.string("description")),
                                  depth: Swift.max(1, object.int("spawnDepth") ?? 1)))
        }
        return found
    }
}
