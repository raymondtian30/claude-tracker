import Foundation

/// Which Claude Code plugins are enabled, which open sessions run them, and
/// what each has been doing there.
///
/// Everything comes from files Claude Code already keeps:
/// - ~/.claude/settings.json "enabledPlugins": what's turned on for you
/// - a project's .claude/settings.json and settings.local.json: per-folder overrides
/// - ~/.claude/plugins/installed_plugins.json: where each plugin's files are
/// - each plugin's own files: its skills, agents, hooks and MCP servers, so
///   activity in a session log can be traced back to it
/// - the session logs: skills run, agents started, MCP tools used, hooks fired
///
/// Kept free of AppKit so it can be unit-tested.
///
/// "Settings order" matters (rows, tags, and which of two same-named plugins
/// gets credit), and JSONSerialization doesn't keep key order, so the
/// enabledPlugins keys are read in file order by `JSONKeyOrder`.
public enum Plugins {
    public static let claudeDir = URL(fileURLWithPath: UsageStats.homeDirectory)
        .appendingPathComponent(".claude")
    static let projectSettings = [".claude/settings.json", ".claude/settings.local.json"]

    // Cheap text checks that skip the many log lines with no plugin activity.
    static let activityMarkers = [#""tool_use""#, "<command-name>", #""hook_"#].map { Data($0.utf8) }

    /// An enabled plugin: its id ("name@source"), name, label (name, plus its
    /// source when two enabled plugins share a name) and what `profile` finds
    /// in its files.
    public struct Plugin: Equatable {
        public var id: String
        public var name: String
        public var source: String
        /// Its name as used in skill and agent names.
        public var prefix: String
        /// Its skills, agents and commands.
        public var names: Set<String>
        public var hookEvents: Set<String>
        /// Each hook's command and status message.
        public var hookStrings: Set<String>
        public var servers: Set<String>
        public var label: String
    }

    /// A session's tag: a plugin's name and whether it runs there.
    public struct Tag: Equatable {
        public var name: String
        public var runs: Bool

        public init(_ name: String, _ runs: Bool) {
            self.name = name
            self.runs = runs
        }
    }

    /// What a plugin did last.
    public struct Activity: Equatable {
        public var text: String
        public var at: Double
    }

    /// One row of the Plugins card.
    public struct Row: Equatable {
        public var label: String
        /// Open sessions running it.
        public var sessions: Int
        public var latest: Activity?
        /// {kind: count} of today's activity ("skill", "agent", "tool", "hook").
        public var today: [String: Int]
    }

    /// A plugin-related event in a session log.
    public struct LogEvent: Equatable {
        public var when: Double
        /// "skill", "agent", "tool", "hook" or "context".
        public var kind: String
        /// "plugin:skill", "plugin:agent", "mcp__plugin_..." or, for "hook"
        /// and "context", the hook event (nil if the log didn't say).
        public var detail: String?
        /// For "hook": the command (or status message) logged.
        public var command: String?
    }

    /// enabledPlugins from settings, in file order: [(plugin id, value)].
    public struct Overrides {
        public var order = [String]()
        public var values = JSONObject()

        public init() {}

        /// Python's dict.update: a key already there keeps its place.
        mutating func update(order newOrder: [String], values newValues: JSONObject) {
            for id in newOrder where newValues[id] != nil {
                if values[id] == nil {
                    order.append(id)
                }
                values[id] = newValues[id]
            }
        }

        func isOn(_ id: String) -> Bool { JSON.bool(values[id]) == true }
        func isOff(_ id: String) -> Bool { JSON.bool(values[id]) == false }
    }

    static func loadJSON(_ url: URL) -> JSONObject {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return JSON.parseObject(data) ?? [:]
    }

    /// The "enabledPlugins" object of a settings file, keys in file order.
    static func enabledPluginsSetting(_ url: URL) -> Overrides? {
        guard let data = try? Data(contentsOf: url),
              let values = JSON.parseObject(data)?.object("enabledPlugins")
        else { return nil }
        var setting = Overrides()
        let order = JSONKeyOrder.keys(data, under: "enabledPlugins") ?? values.keys.sorted()
        setting.update(order: order, values: values)
        return setting
    }

    /// (events, strings) from a hooks config: the events it hooks into and
    /// each hook's command and status message (Claude Code logs the status
    /// message in place of the command when there is one).
    static func hookDetails(_ hooks: Any?) -> (events: Set<String>, strings: Set<String>) {
        var events = Set<String>(), strings = Set<String>()
        guard let hooks = JSON.object(hooks) else { return (events, strings) }
        for (event, groups) in hooks {
            for group in JSON.array(groups) ?? [] {
                for hook in JSON.array(JSON.object(group)?["hooks"]) ?? [] {
                    guard let hook = JSON.object(hook) else { continue }
                    events.insert(event)
                    for text in [hook.string("command"), hook.string("statusMessage")] {
                        if let text = text, !text.isEmpty {
                            strings.insert(text)
                        }
                    }
                }
            }
        }
        return (events, strings)
    }

    /// Python's `Path.stem`: the name without its last suffix.
    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// What a plugin brings, read from its install folder: its name as used
    /// in skill and agent names, those names, and its hooks and MCP servers.
    static func profile(_ installPath: String?)
        -> (prefix: String?, names: Set<String>, hookEvents: Set<String>, hookStrings: Set<String>,
            servers: Set<String>) {
        let root = CodexSource.nonEmpty(installPath).map { URL(fileURLWithPath: $0) }
        let manifest = root.map { loadJSON($0.appendingPathComponent(".claude-plugin/plugin.json")) } ?? [:]
        var names = Set<String>()
        var events = Set<String>(), strings = Set<String>()
        var servers = Set<String>()
        if let root = root, isDirectory(root) {
            for folder in ["skills", "agents", "commands"] {
                let dir = root.appendingPathComponent(folder)
                guard isDirectory(dir) else { continue }
                for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                    names.insert(stem(entry))
                }
            }
            let hooksFile = loadJSON(root.appendingPathComponent("hooks/hooks.json"))["hooks"]
            for var config in [hooksFile, manifest["hooks"]] {
                if let path = config as? String {
                    let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
                    config = loadJSON(file)["hooks"]
                }
                let (e, s) = hookDetails(config)
                events.formUnion(e)
                strings.formUnion(s)
            }
            for config in [loadJSON(root.appendingPathComponent(".mcp.json"))["mcpServers"], manifest["mcpServers"]] {
                if let config = JSON.object(config) {
                    servers.formUnion(config.keys)
                }
            }
        }
        return (CodexSource.nonEmpty(manifest.string("name")), names, events, strings, servers)
    }

    /// Ids of the plugins turned on in your own settings, in order.
    public static func userEnabledIds(claudeDir: URL = claudeDir) -> [String] {
        guard let setting = enabledPluginsSetting(claudeDir.appendingPathComponent("settings.json")) else {
            return []
        }
        return setting.order.filter(setting.isOn)
    }

    /// The plugins turned on in your settings (plus `extraIds`, ones a
    /// project turns on), in settings order.
    public static func enabledPlugins(claudeDir: URL = claudeDir, extraIds: [String] = []) -> [Plugin] {
        let installed = loadJSON(claudeDir.appendingPathComponent("plugins/installed_plugins.json"))
            .object("plugins") ?? [:]
        var ids = userEnabledIds(claudeDir: claudeDir)
        // As in Python, each extra id is checked against your own ids only, so
        // one that two projects turn on is listed twice.
        ids += extraIds.filter { !ids.contains($0) }

        var found = [Plugin]()
        for id in ids {
            let (name, source) = partition(id, "@")
            let install = JSON.object(JSON.array(installed[id])?.first) ?? [:]
            let profile = self.profile(install.string("installPath"))
            found.append(Plugin(id: id, name: name, source: source, prefix: profile.prefix ?? name,
                                names: profile.names, hookEvents: profile.hookEvents,
                                hookStrings: profile.hookStrings, servers: profile.servers, label: name))
        }
        var counts = [String: Int]()
        for plugin in found {
            counts[plugin.name, default: 0] += 1
        }
        for index in found.indices where (counts[found[index].name] ?? 0) > 1 && !found[index].source.isEmpty {
            found[index].label = "\(found[index].name) (\(found[index].source))"
        }
        return found
    }

    /// Python's `str.partition`: (before, after) the first `separator`, or
    /// (text, "") without one.
    static func partition(_ text: String, _ separator: Character) -> (String, String) {
        guard let index = text.firstIndex(of: separator) else { return (text, "") }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    /// enabledPlugins from a folder's own Claude settings (local wins).
    public static func projectOverrides(_ cwd: String) -> Overrides {
        var overrides = Overrides()
        for name in projectSettings {
            if let setting = enabledPluginsSetting(URL(fileURLWithPath: cwd).appendingPathComponent(name)) {
                overrides.update(order: setting.order, values: setting.values)
            }
        }
        return overrides
    }

    /// {plugin id: whether it runs} for a session in `cwd`.
    public static func loadedIn(_ cwd: String, _ enabled: [Plugin], overrides: Overrides? = nil) -> [String: Bool] {
        let overrides = overrides ?? projectOverrides(cwd)
        var loaded = [String: Bool]()
        for plugin in enabled {
            loaded[plugin.id] = !overrides.isOff(plugin.id)
        }
        return loaded
    }

    // MARK: - Reading what happened in a session log

    static func timestamp(_ entry: JSONObject) -> Double? {
        entry.string("timestamp").flatMap(LocalTime.parseISO)
    }

    /// The plugin slash command in a user message ("plugin:name"), if any.
    static func commandName(_ content: Any?) -> String? {
        var text: String
        if let blocks = JSON.array(content) {
            text = blocks.compactMap { JSON.object($0) }.map { $0.string("text") ?? "" }.joined(separator: " ")
        } else if let content = content as? String {
            text = content
        } else {
            return nil
        }
        guard let start = text.range(of: "<command-name>"), let end = text.range(of: "</command-name>"),
              end.lowerBound >= start.lowerBound
        else { return nil }
        guard start.upperBound <= end.lowerBound else { return nil }
        text = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(text.drop { $0 == "/" })
        return name.contains(":") ? name : nil
    }

    /// Plugin-related events in one session log, oldest first:
    /// ("skill", "plugin:skill"), ("agent", "plugin:agent"),
    /// ("tool", "mcp__plugin_..."), ("hook", event, command) or
    /// ("context", event) for text a hook added.
    public static func logEvents(_ path: String) -> [LogEvent] {
        var events = [LogEvent]()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return events }
        for line in textLines(data) {
            guard activityMarkers.contains(where: { line.range(of: $0) != nil }) else { continue }
            // Python reads the log with errors="replace".
            let text = String(decoding: line, as: UTF8.self)
            guard let entry = JSON.parseObject(Data(text.utf8)), let when = timestamp(entry) else { continue }
            if let attachment = entry.object("attachment") {
                let kind = attachment.string("type") ?? ""
                if kind == "hook_additional_context" {
                    events.append(LogEvent(when: when, kind: "context", detail: attachment.string("hookEvent")))
                } else if kind.hasPrefix("hook_"), let command = CodexSource.nonEmpty(attachment.string("command")) {
                    events.append(LogEvent(when: when, kind: "hook", detail: attachment.string("hookEvent"),
                                           command: command))
                }
                continue
            }
            guard let message = entry.object("message") else { continue }
            if entry.string("type") == "user" {
                if let name = commandName(message["content"]) {
                    events.append(LogEvent(when: when, kind: "skill", detail: name))
                }
                continue
            }
            for block in message.array("content") ?? [] {
                guard let block = JSON.object(block), block.string("type") == "tool_use" else { continue }
                let tool = block.string("name") ?? ""
                let inputs = block.object("input") ?? [:]
                if tool == "Skill", let skill = inputs.string("skill"), skill.contains(":") {
                    events.append(LogEvent(when: when, kind: "skill", detail: skill))
                } else if tool == "Agent" || tool == "Task",
                          let agent = inputs.string("subagent_type"), agent.contains(":") {
                    events.append(LogEvent(when: when, kind: "agent", detail: agent))
                } else if tool.hasPrefix("mcp__plugin_") {
                    events.append(LogEvent(when: when, kind: "tool", detail: tool))
                }
            }
        }
        return events
    }

    /// The lines of a text file, split where Python's text mode splits them
    /// ("\n", "\r\n" or "\r").
    static func textLines(_ data: Data) -> [Data] {
        var lines = [Data]()
        let bytes = [UInt8](data)
        var start = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A || bytes[index] == 0x0D {
                lines.append(Data(bytes[start..<index]))
                if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 1
                }
                start = index + 1
            }
            index += 1
        }
        if start < bytes.count {
            lines.append(Data(bytes[start...]))
        }
        return lines
    }

    private static var cache = [String: (mtime: Double, size: Int, events: [LogEvent])]()
    private static let cacheLock = NSLock()

    /// `logEvents`, reread only when the log has changed.
    public static func cachedLogEvents(_ path: String) -> [LogEvent] {
        guard let stat = SourceFile.Stat(path) else { return [] }
        cacheLock.lock()
        let hit = cache[path]
        cacheLock.unlock()
        if let hit = hit, hit.mtime == stat.mtime, hit.size == stat.size {
            return hit.events
        }
        let events = logEvents(path)
        cacheLock.lock()
        cache[path] = (stat.mtime, stat.size, events)
        cacheLock.unlock()
        return events
    }

    /// (plugin, kind, what it did) for one event, among the plugins `running`
    /// in that session, or nil. Plugins that share a name can't be told apart
    /// in the log, so the first one listed in settings gets it.
    static func attribute(_ event: LogEvent, _ running: [Plugin]) -> (plugin: Plugin, kind: String, text: String)? {
        var kind = event.kind
        let matches: [Plugin]
        let text: String
        switch event.kind {
        case "skill", "agent":
            let (prefix, name) = partition(event.detail ?? "", ":")
            let sameName = running.filter { $0.prefix == prefix }
            let withName = sameName.filter { $0.names.contains(name) }
            matches = withName.isEmpty ? sameName : withName
            text = event.kind == "skill" ? "Ran \(name) skill" : "Started \(name) agent"
        case "tool":
            let detail = event.detail ?? ""
            matches = running.filter { detail.hasPrefix("mcp__plugin_\($0.prefix)_") }
            // Python's detail.rsplit("__", 1)[-1]: what follows the last "__".
            let toolName = detail.range(of: "__", options: .backwards).map { String(detail[$0.upperBound...]) }
                ?? detail
            text = "Used \(toolName) tool"
        case "hook":
            matches = running.filter { $0.hookStrings.contains(event.command ?? "") }
            text = "\(event.detail ?? "None") hook ran"
        case "context":
            // Only the event is logged; credit it when just one plugin hooks it.
            matches = running.filter { plugin in event.detail.map(plugin.hookEvents.contains) ?? false }
            if Set(matches.map(\.prefix)).count != 1 {
                return nil
            }
            text = event.detail == "UserPromptSubmit"
                ? "Added context to your prompt" : "\(event.detail ?? "None") hook ran"
            kind = "hook"
        default:
            return nil
        }
        return matches.first.map { ($0, kind, text) }
    }

    /// Plugin rows for the Live tab, most recently active first.
    ///
    /// Also gives each Claude Code session (one with a cwd and log) a
    /// `plugins` list of tags (name, runs in it), in settings order.
    public static func livePlugins(_ sessions: inout [ActiveSessions.Session], claudeDir: URL = claudeDir,
                                   now: Double? = nil) -> [Row] {
        let claudeIndices = sessions.indices.filter {
            !(sessions[$0].cwd ?? "").isEmpty && !(sessions[$0].log ?? "").isEmpty
        }
        // Each folder's overrides, folders in first-seen order (Python's dict).
        var cwdOrder = [String]()
        var overrides = [String: Overrides]()
        for index in claudeIndices {
            let cwd = sessions[index].cwd!
            if overrides[cwd] == nil {
                cwdOrder.append(cwd)
            }
            overrides[cwd] = projectOverrides(cwd)
        }
        let extra = cwdOrder.flatMap { cwd in overrides[cwd]!.order.filter(overrides[cwd]!.isOn) }
        let enabled = enabledPlugins(claudeDir: claudeDir, extraIds: extra)
        let userOn = Set(userEnabledIds(claudeDir: claudeDir))

        let today = Day(timestamp: now ?? Date().timeIntervalSince1970)
        var rows = [String: Row]()
        for plugin in enabled {
            rows[plugin.id] = Row(label: plugin.label, sessions: 0, latest: nil, today: [:])
        }
        for index in claudeIndices {
            let cwd = sessions[index].cwd!
            let cwdOverrides = overrides[cwd]!
            let loaded = loadedIn(cwd, enabled, overrides: cwdOverrides)
            // A plugin only a different project turns on doesn't belong here.
            let shown = enabled.filter { userOn.contains($0.id) || cwdOverrides.isOn($0.id) }
            // Tags use the bare name: two installs of one plugin are one tag,
            // on if either runs, so the tags stay short.
            var tags = [Tag]()
            for plugin in shown {
                let runs = loaded[plugin.id] ?? false
                if let at = tags.firstIndex(where: { $0.name == plugin.name }) {
                    tags[at].runs = tags[at].runs || runs
                } else {
                    tags.append(Tag(plugin.name, runs))
                }
            }
            sessions[index].plugins = tags
            let running = shown.filter { loaded[$0.id] ?? false }
            for plugin in running {
                rows[plugin.id]!.sessions += 1
            }
            for event in cachedLogEvents(sessions[index].log!) {
                guard let (plugin, kind, text) = attribute(event, running) else { continue }
                var row = rows[plugin.id]!
                if row.latest == nil || event.when >= row.latest!.at {
                    row.latest = Activity(text: text, at: event.when)
                }
                if Day(timestamp: event.when) == today {
                    row.today[kind, default: 0] += 1
                }
                rows[plugin.id] = row
            }
        }

        let result = enabled.filter { userOn.contains($0.id) || rows[$0.id]!.sessions > 0 }.map { rows[$0.id]! }
        // Stable, as Python's sort: rows with no activity last, in settings order.
        return result.enumerated().sorted { a, b in
            let (x, y) = (a.element.latest?.at ?? -.infinity, b.element.latest?.at ?? -.infinity)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }
}

/// The key order of a JSON object, which JSONSerialization doesn't keep.
enum JSONKeyOrder {
    /// The keys, in file order, of the object under the top-level `key` of
    /// the JSON object in `data`; nil if there isn't one or the JSON is
    /// malformed. A key given twice keeps its first place, as in Python.
    static func keys(_ data: Data, under key: String) -> [String]? {
        var scanner = Scanner(bytes: [UInt8](data))
        var found: [String]?
        let complete = scanner.object { name, scanner in
            if name == key, scanner.peek() == UInt8(ascii: "{") {
                var keys = [String]()
                let ok = scanner.object { inner, scanner in
                    if !keys.contains(inner) {
                        keys.append(inner)
                    }
                    return scanner.skipValue()
                }
                found = ok ? keys : nil
                return ok
            }
            return scanner.skipValue()
        }
        return complete ? found : nil
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // A UTF-8 byte order mark.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                index = 3
            }
        }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func peek() -> UInt8? {
            skipSpace()
            return index < bytes.count ? bytes[index] : nil
        }

        mutating func expect(_ character: Character) -> Bool {
            guard peek() == character.asciiValue else { return false }
            index += 1
            return true
        }

        /// Reads `{ "key": value, ... }`, calling `member` with each key
        /// once the scanner sits before its value; `member` must read the value.
        mutating func object(_ member: (String, inout Scanner) -> Bool) -> Bool {
            guard expect("{") else { return false }
            if expect("}") {
                return true
            }
            repeat {
                guard let name = string(), expect(":"), member(name, &self) else { return false }
            } while expect(",")
            return expect("}")
        }

        /// A JSON string, decoded.
        mutating func string() -> String? {
            guard peek() == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { return nil }
            index += 1
            return JSON.parse(Data(bytes[start..<index])) as? String
        }

        mutating func skipValue() -> Bool {
            switch peek() {
            case UInt8(ascii: "{"):
                return object { _, scanner in scanner.skipValue() }
            case UInt8(ascii: "["):
                index += 1
                if expect("]") {
                    return true
                }
                repeat {
                    guard skipValue() else { return false }
                } while expect(",")
                return expect("]")
            case UInt8(ascii: "\""):
                return string() != nil
            case nil:
                return false
            default:
                // A number, true, false or null.
                let start = index
                while index < bytes.count, !Array(",]} \t\n\r".utf8).contains(bytes[index]) {
                    index += 1
                }
                return index > start
            }
        }
    }
}
