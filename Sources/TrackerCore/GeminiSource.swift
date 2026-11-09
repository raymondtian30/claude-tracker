import Foundation

/// Gemini CLI usage, read from the chat sessions Gemini CLI saves on this Mac.
///
/// Gemini CLI records each session under ~/.gemini/tmp/<project>/chats/ as a
/// JSONL file (older versions: one .json file). Each reply ("gemini" message)
/// carries the token counts the Gemini API returned and the model used. Only
/// those counts, the model, the time and the project folder are read; prompts
/// and replies in the same files are skipped.
///
/// Like Codex, each file is re-read whole when it changes and replaces its
/// previous contribution; files that disappear keep their last contribution.
public enum GeminiSource {
    public static let geminiDir = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".gemini")

    /// Gemini's counts -> the app's categories. `input` (promptTokenCount)
    /// includes the cached tokens, so they're split out; tool-use prompt tokens
    /// are input and thinking tokens are output, so the parts add up to the
    /// API's own total.
    static func parts(_ tokens: JSONObject) -> [String: Int] {
        let cached = tokens.int("cached") ?? 0
        return [
            "input": max((tokens.int("input") ?? 0) - cached, 0) + (tokens.int("tool") ?? 0),
            "output": (tokens.int("output") ?? 0) + (tokens.int("thoughts") ?? 0),
            "cache_write_5m": 0,
            "cache_write_1h": 0,
            "cache_read": cached,
        ]
    }

    /// The session's records. A JSONL line still being written (no newline
    /// yet) is left for the next scan.
    static func records(_ path: URL) throws -> [JSONObject] {
        let data = try Data(contentsOf: path)
        if path.pathExtension == "json" {
            guard let parsed = JSON.parse(data) else {
                throw UsageStats.SourceFormatError("\(path.lastPathComponent) isn't valid JSON")
            }
            guard let session = parsed as? JSONObject, let messages = session["messages"] else {
                throw UsageStats.SourceFormatError("\(path.lastPathComponent) doesn't look like a Gemini CLI session")
            }
            return [session] + (JSON.array(messages) ?? []).compactMap { JSON.object($0) }
        }
        return TokenMath.completeLines(data).compactMap { JSON.parseObject($0) }
    }

    /// This session file's per-day buckets, filed under `project` (a folder
    /// path or label).
    public static func readGeminiFile(_ path: URL, project: String) throws -> JSONObject {
        let records = try records(path)
        if !records.isEmpty,
           !records.contains(where: { $0["sessionId"] != nil || $0["type"] != nil || $0["$set"] != nil }) {
            throw UsageStats.SourceFormatError("\(path.lastPathComponent) doesn't look like a Gemini CLI session")
        }

        // A reply can be written again as its token counts arrive; the last
        // version of each message id wins.
        var replies = [AnyHashable: JSONObject]()
        for record in records where record.string("type") == "gemini" && JSON.truthy(record["tokens"]) {
            let id = record["id"].flatMap { JSON.truthy($0) ? $0 as? AnyHashable : nil }
            replies[id ?? AnyHashable(replies.count)] = record
        }

        var daily = JSONObject()
        let label = project.hasPrefix("/") ? UsageStats.projectLabel(project) : project
        for reply in replies.values {
            let parts = self.parts(reply.object("tokens") ?? [:])
            guard let timestamp = CodexSource.nonEmpty(reply.string("timestamp")),
                  parts.values.reduce(0, +) != 0,
                  let day = UsageStats.localDateOf(timestamp)
            else { continue }
            let model = CodexSource.nonEmpty(reply.string("model")) ?? "unknown"
            UsageStats.addUsage(&daily, day: day, model: model, project: label, parts: parts)
        }
        return daily
    }

    /// {project folder name under tmp/: project path}, from projects.json.
    static func projectRoots(_ geminiDir: URL) -> [String: String] {
        let file = geminiDir.appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: file),
              let projects = JSON.parseObject(data)?.object("projects")
        else { return [:] }
        var roots = [String: String]()
        for (root, slug) in projects {
            if let slug = slug as? String {
                roots[slug] = root
            }
        }
        return roots
    }

    static func projectOf(_ folder: URL, _ roots: [String: String]) -> String {
        let marker = folder.appendingPathComponent(".project_root")
        if let text = try? String(contentsOf: marker, encoding: .utf8) {
            let root = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !root.isEmpty {
                return root
            }
        }
        return roots[folder.lastPathComponent] ?? folder.lastPathComponent
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Update `sourceState` from Gemini CLI's saved sessions. Sets
    /// sourceState["error"] to a message if a file couldn't be read, else null.
    public static func scanGemini(_ sourceState: inout JSONObject, geminiDir: URL = geminiDir) {
        var files = sourceState.object("files") ?? [:]
        var errors = [String]()
        let temp = geminiDir.appendingPathComponent("tmp")
        let roots = projectRoots(geminiDir)
        let names = isDirectory(temp) ? (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] : []
        let folders = SourceFile.sortedPaths(names.map { temp.path + "/" + $0 })
            .map { URL(fileURLWithPath: $0) }
            .filter(isDirectory)
        for folder in folders {
            let chats = folder.appendingPathComponent("chats")
            if !isDirectory(chats) {
                continue
            }
            let project = projectOf(folder, roots)
            for path in SourceFile.find(in: chats, suffixes: [".jsonl", ".json"]) {
                guard let stat = SourceFile.Stat(path) else { continue }
                if let saved = files.object(path), stat.matches(saved) {
                    continue
                }
                do {
                    let daily = try readGeminiFile(URL(fileURLWithPath: path), project: project)
                    files[path] = ["size": stat.size, "mtime": stat.mtime, "daily": daily] as JSONObject
                } catch {
                    errors.append(SourceFile.message(error))
                }
            }
        }
        sourceState["files"] = files
        sourceState["error"] = errors.first ?? NSNull()
    }

    public static func geminiDaily(_ sourceState: JSONObject) -> JSONObject {
        UsageStats.mergeDaily(SourceFile.dailies(sourceState))
    }

    public static func geminiTotal(_ sourceState: JSONObject) -> Int {
        SourceFile.dailies(sourceState).reduce(0) { $0 + SourceFile.total($1) }
    }
}
