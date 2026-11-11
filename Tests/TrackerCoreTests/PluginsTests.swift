// Ported from tests/test_plugins.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private typealias Session = ActiveSessions.Session
private typealias Tag = Plugins.Tag

/// Writes JSON text as given, so key order in the file is the order written
/// (the settings files' plugin order matters).
private func writeJSONText(_ url: URL, _ text: String) {
    writeText(url, text)
}

private func writeJSONValue(_ url: URL, _ value: Any) {
    writeText(url, String(decoding: try! JSON.encode(value), as: UTF8.self))
}

/// `{"a": true, "b": false}` with keys in the given order.
private func orderedObject(_ pairs: [(String, Any)]) -> String {
    "{" + pairs.map { key, value in
        String(decoding: try! JSON.encode(key), as: UTF8.self) + ": "
            + String(decoding: try! JSON.encode(value), as: UTF8.self)
    }.joined(separator: ", ") + "}"
}

/// A plugin install folder like the ones in ~/.claude/plugins/cache.
@discardableResult
private func makePlugin(_ root: URL, _ name: String, skills: [String] = [], agents: [String] = [],
                        hooks: JSONObject? = nil, mcp: JSONObject? = nil) -> URL {
    writeJSONValue(root.appendingPathComponent(".claude-plugin/plugin.json"), ["name": name])
    for skill in skills {
        writeText(root.appendingPathComponent("skills/\(skill)/SKILL.md"), "---\n---\n")
    }
    for agent in agents {
        writeText(root.appendingPathComponent("agents/\(agent).md"), "")
    }
    if let hooks = hooks {
        writeJSONValue(root.appendingPathComponent("hooks/hooks.json"), ["hooks": hooks])
    }
    if let mcp = mcp {
        writeJSONValue(root.appendingPathComponent(".mcp.json"), ["mcpServers": mcp])
    }
    return root
}

/// A ~/.claude with `enabled` plugin ids (in order) and their install folders.
private func setupClaude(_ tmp: TempDir, _ enabled: [(String, Any)], _ installs: [String: URL]) -> URL {
    let claude = tmp.url(".claude")
    writeJSONText(claude.appendingPathComponent("settings.json"),
                  "{\"enabledPlugins\": \(orderedObject(enabled))}")
    var plugins = JSONObject()
    for (id, path) in installs {
        plugins[id] = [["installPath": path.path]]
    }
    writeJSONValue(claude.appendingPathComponent("plugins/installed_plugins.json"),
                   ["version": 2, "plugins": plugins] as JSONObject)
    return claude
}

private func hook(_ command: String, _ status: String? = nil) -> JSONObject {
    var entry: JSONObject = ["type": "command", "command": command]
    if let status = status {
        entry["statusMessage"] = status
    }
    return entry
}

private func hooks(_ event: String, _ entries: [JSONObject]) -> JSONObject {
    [event: [["hooks": entries]]]
}

private func ts(_ hour: Int, _ minute: Int = 0) -> String {
    String(format: "2026-11-08T%02d:%02d:00.000Z", hour, minute)
}

private func toolUse(_ name: String, _ when: String, _ inputs: JSONObject = [:]) -> JSONObject {
    ["type": "assistant", "timestamp": when,
     "message": ["content": [["type": "tool_use", "name": name, "input": inputs] as JSONObject]]]
}

@discardableResult
private func writeLog(_ url: URL, _ entries: [JSONObject]) -> URL {
    writeText(url, entries.map(jsonLine).joined())
    return url
}

private func attachment(_ type: String, _ when: String, event: String, command: String? = nil) -> JSONObject {
    var body: JSONObject = ["type": type, "hookEvent": event]
    if let command = command {
        body["command"] = command
    }
    return ["type": "attachment", "timestamp": when, "attachment": body]
}

private let NOW = LocalTime.parseISO("2026-11-08T12:00:00+00:00")!

@Test func enabledPluginsReadsSettingsAndInstallPaths() {
    let tmp = TempDir()
    let sp = makePlugin(tmp.url("sp"), "superpowers")
    let claude = setupClaude(tmp, [("superpowers@dev", true), ("off@x", false)], ["superpowers@dev": sp])

    let found = Plugins.enabledPlugins(claudeDir: claude)

    #expect(found.map { [$0.id, $0.name, $0.prefix] } == [["superpowers@dev", "superpowers", "superpowers"]])
}

@Test func enabledPluginsLabelsDuplicateNamesBySource() {
    let tmp = TempDir()
    let a = makePlugin(tmp.url("a"), "superpowers")
    let b = makePlugin(tmp.url("b"), "superpowers")
    let claude = setupClaude(tmp, [("superpowers@dev", true), ("superpowers@dir", true)],
                             ["superpowers@dev": a, "superpowers@dir": b])

    let labels = Plugins.enabledPlugins(claudeDir: claude).map(\.label)

    #expect(labels == ["superpowers (dev)", "superpowers (dir)"])
}

@Test func enabledPluginsSurvivesMissingFiles() {
    let tmp = TempDir()
    #expect(Plugins.enabledPlugins(claudeDir: tmp.url("nothing")) == [])
}

@Test func enabledPluginsSurvivesOddSettings() {
    let tmp = TempDir()
    let claude = tmp.url(".claude")
    writeJSONValue(claude.appendingPathComponent("settings.json"), ["enabledPlugins": ["not", "a", "dict"]])
    writeJSONValue(claude.appendingPathComponent("plugins/installed_plugins.json"), ["plugins": ["x@y": "bad"]])
    #expect(Plugins.enabledPlugins(claudeDir: claude) == [])
    writeJSONValue(claude.appendingPathComponent("settings.json"), ["enabledPlugins": ["x@y": true]])
    #expect(Plugins.enabledPlugins(claudeDir: claude).map(\.id) == ["x@y"])
}

@Test func projectSettingsTurnPluginsOffForThatFolder() {
    let tmp = TempDir()
    let sp = makePlugin(tmp.url("sp"), "superpowers")
    let cm = makePlugin(tmp.url("cm"), "caveman")
    let claude = setupClaude(tmp, [("superpowers@dev", true), ("caveman@cm", true)],
                             ["superpowers@dev": sp, "caveman@cm": cm])
    let project = tmp.url("proj")
    writeJSONValue(project.appendingPathComponent(".claude/settings.local.json"),
                   ["enabledPlugins": ["caveman@cm": false]])

    let loaded = Plugins.loadedIn(project.path, Plugins.enabledPlugins(claudeDir: claude))

    #expect(loaded == ["superpowers@dev": true, "caveman@cm": false])
}

@Test func livePluginsAttributesSkillsAgentsHooksAndTools() {
    let tmp = TempDir()
    let sp = makePlugin(tmp.url("sp"), "superpowers", skills: ["brainstorming"],
                        hooks: hooks("SessionStart", [hook("run-hook session-start")]))
    let cm = makePlugin(tmp.url("cm"), "caveman", agents: ["cavecrew-builder"],
                        hooks: hooks("UserPromptSubmit", [hook("node track.js", "Tracking...")]),
                        mcp: ["mem": ["command": "x"]])
    let claude = setupClaude(tmp, [("superpowers@dev", true), ("caveman@cm", true)],
                             ["superpowers@dev": sp, "caveman@cm": cm])
    let log = writeLog(tmp.url("log.jsonl"), [
        attachment("hook_success", ts(9), event: "SessionStart", command: "run-hook session-start"),
        ["type": "user", "timestamp": ts(9, 1),
         "message": ["content": "<command-name>/superpowers:brainstorming</command-name>"]],
        toolUse("Skill", ts(9, 2), ["skill": "superpowers:brainstorming"]),
        toolUse("Agent", ts(10), ["subagent_type": "caveman:cavecrew-builder"]),
        toolUse("mcp__plugin_caveman_mem__recall", ts(10, 5)),
        attachment("hook_additional_context", ts(11), event: "UserPromptSubmit"),
        toolUse("Bash", ts(11, 30), ["command": "ls"]),
    ])
    var sessions = [Session(label: "~/proj", tokens: 5, cwd: tmp.url("proj").path, log: log.path)]

    let rows = Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW)

    #expect(sessions[0].plugins == [Tag("superpowers", true), Tag("caveman", true)])
    let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0) })
    #expect(byLabel["superpowers"]?.sessions == 1)
    #expect(byLabel["superpowers"]?.today == ["skill": 2, "hook": 1])
    #expect(byLabel["superpowers"]?.latest?.text == "Ran brainstorming skill")
    #expect(byLabel["caveman"]?.today == ["agent": 1, "tool": 1, "hook": 1])
    #expect(byLabel["caveman"]?.latest?.text == "Added context to your prompt")
    // Most recently active first.
    #expect(rows.map(\.label) == ["caveman", "superpowers"])
}

/// Claude Code logs a hook's statusMessage in place of its command.
@Test func livePluginsHookStatusMessageMatches() {
    let tmp = TempDir()
    let cm = makePlugin(tmp.url("cm"), "caveman",
                        hooks: hooks("SessionStart", [hook("node activate.js", "Loading caveman mode...")]))
    let claude = setupClaude(tmp, [("caveman@cm", true)], ["caveman@cm": cm])
    let log = writeLog(tmp.url("log.jsonl"), [
        attachment("hook_success", ts(9), event: "SessionStart", command: "Loading caveman mode..."),
    ])
    var sessions = [Session(label: "~/p", tokens: 1, cwd: tmp.path, log: log.path)]

    let rows = Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW)

    #expect(rows.first?.latest?.text == "SessionStart hook ran")
}

@Test func livePluginsHooksInPluginJsonCount() {
    let tmp = TempDir()
    let cm = makePlugin(tmp.url("cm"), "caveman")
    writeJSONValue(cm.appendingPathComponent(".claude-plugin/plugin.json"), [
        "name": "caveman",
        "hooks": hooks("SessionEnd", [hook("node stats.js", "Recording caveman stats...")]),
    ] as JSONObject)
    let claude = setupClaude(tmp, [("caveman@cm", true)], ["caveman@cm": cm])
    let log = writeLog(tmp.url("log.jsonl"), [
        attachment("hook_success", ts(9), event: "SessionEnd", command: "Recording caveman stats..."),
    ])
    var sessions = [Session(label: "~/p", tokens: 1, cwd: tmp.path, log: log.path)]

    #expect(Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW).first?.today == ["hook": 1])
}

@Test func livePluginsSkipsPromptContextItCannotPinOnOnePlugin() {
    let tmp = TempDir()
    let a = makePlugin(tmp.url("a"), "one", hooks: hooks("SessionStart", [hook("a")]))
    let b = makePlugin(tmp.url("b"), "two", hooks: hooks("SessionStart", [hook("b")]))
    let claude = setupClaude(tmp, [("one@x", true), ("two@x", true)], ["one@x": a, "two@x": b])
    let log = writeLog(tmp.url("log.jsonl"), [attachment("hook_additional_context", ts(9), event: "SessionStart")])
    var sessions = [Session(label: "~/p", tokens: 1, cwd: tmp.path, log: log.path)]

    let rows = Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW)

    #expect(rows.allSatisfy { $0.latest == nil && $0.today.isEmpty })
}

@Test func livePluginsCountsTodayOnlyButKeepsOlderLatest() {
    let tmp = TempDir()
    let sp = makePlugin(tmp.url("sp"), "superpowers", skills: ["tdd"])
    let claude = setupClaude(tmp, [("superpowers@dev", true)], ["superpowers@dev": sp])
    let log = writeLog(tmp.url("log.jsonl"), [toolUse("Skill", "2026-11-01T09:00:00.000Z", ["skill": "superpowers:tdd"])])
    var sessions = [Session(label: "~/p", tokens: 1, cwd: tmp.path, log: log.path)]

    let row = Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW).first

    #expect(row?.today == [:])
    #expect(row?.latest?.text == "Ran tdd skill")
}

@Test func livePluginsOffInAProjectIsNotCountedThere() {
    let tmp = TempDir()
    let cm = makePlugin(tmp.url("cm"), "caveman", skills: ["caveman"])
    let claude = setupClaude(tmp, [("caveman@cm", true)], ["caveman@cm": cm])
    let project = tmp.url("proj")
    writeJSONValue(project.appendingPathComponent(".claude/settings.json"), ["enabledPlugins": ["caveman@cm": false]])
    let log = writeLog(tmp.url("log.jsonl"), [toolUse("Skill", ts(9), ["skill": "caveman:caveman"])])
    var sessions = [Session(label: "~/proj", tokens: 1, cwd: project.path, log: log.path)]

    let row = Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW).first

    #expect(sessions[0].plugins == [Tag("caveman", false)])
    #expect(row?.sessions == 0 && row?.latest == nil)
}

@Test func livePluginsLeavesOtherToolsSessionsAlone() {
    let tmp = TempDir()
    let claude = setupClaude(tmp, [], [:])
    var sessions = [Session(label: "~/game", tokens: nil)]

    #expect(Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW) == [])
    #expect(sessions[0].plugins == nil)
}

@Test func livePluginsAmbiguousDuplicateGoesToFirstInstall() {
    let tmp = TempDir()
    let a = makePlugin(tmp.url("a"), "superpowers", skills: ["tdd"])
    let b = makePlugin(tmp.url("b"), "superpowers", skills: ["tdd"])
    let claude = setupClaude(tmp, [("superpowers@dev", true), ("superpowers@dir", true)],
                             ["superpowers@dev": a, "superpowers@dir": b])
    let log = writeLog(tmp.url("log.jsonl"), [toolUse("Skill", ts(9), ["skill": "superpowers:tdd"])])
    var sessions = [Session(label: "~/p", tokens: 1, cwd: tmp.path, log: log.path)]

    let rows = Dictionary(uniqueKeysWithValues: Plugins.livePlugins(&sessions, claudeDir: claude, now: NOW)
        .map { ($0.label, $0) })

    #expect(rows["superpowers (dev)"]?.today == ["skill": 1])
    #expect(rows["superpowers (dir)"]?.today == [:])
    // Both installs share one tag on the session.
    #expect(sessions[0].plugins == [Tag("superpowers", true)])
}

// MARK: Reading a log once

@Test func cachedLogEventsEqualAFullReadAfterAppends() {
    let tmp = TempDir()
    let log = tmp.url("a.jsonl")
    writeLog(log, [toolUse("Skill", ts(9, 1), ["skill": "superpowers:brainstorming"])])
    #expect(Plugins.cachedLogEvents(log.path) == Plugins.logEvents(log.path))
    #expect(Plugins.cachedLogEvents(log.path).count == 1)

    appendText(log, jsonLine(toolUse("Skill", ts(9, 2), ["skill": "superpowers:tdd"])))
    let grown = Plugins.cachedLogEvents(log.path)
    #expect(grown.count == 2)
    #expect(grown == Plugins.logEvents(log.path))
    // Unchanged: the same answer without touching the file again.
    #expect(Plugins.cachedLogEvents(log.path) == grown)
}

@Test func aHalfWrittenLastLineIsReadOnceItIsComplete() {
    let tmp = TempDir()
    let log = tmp.url("b.jsonl")
    let second = jsonLine(toolUse("Skill", ts(9, 2), ["skill": "superpowers:tdd"]))
    writeLog(log, [toolUse("Skill", ts(9, 1), ["skill": "superpowers:brainstorming"])])
    appendText(log, String(second.prefix(40)))  // cut off mid-line
    #expect(Plugins.cachedLogEvents(log.path).count == 1)
    appendText(log, String(second.dropFirst(40)))
    let done = Plugins.cachedLogEvents(log.path)
    #expect(done.count == 2)
    #expect(done == Plugins.logEvents(log.path))
}

@Test func aLogThatGotShorterIsReadAgainFromTheStart() {
    let tmp = TempDir()
    let log = tmp.url("c.jsonl")
    writeLog(log, [toolUse("Skill", ts(9, 1), ["skill": "superpowers:brainstorming"]),
                   toolUse("Skill", ts(9, 2), ["skill": "superpowers:tdd"])])
    #expect(Plugins.cachedLogEvents(log.path).count == 2)
    writeLog(log, [toolUse("Skill", ts(9, 3), ["skill": "superpowers:debugging"])])
    let events = Plugins.cachedLogEvents(log.path)
    #expect(events.count == 1)
    #expect(events == Plugins.logEvents(log.path))
}
