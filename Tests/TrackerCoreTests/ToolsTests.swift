// Ported from tests/test_tools.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private func parts(input: Int = 0, output: Int = 0) -> [String: Int] {
    ["input": input, "output": output, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0]
}

private func paths(_ tmp: TempDir) -> [String: URL] {
    [
        "claude_code": tmp.url("claude/projects"),
        "codex": tmp.url("codex/sessions"),
        "opencode": tmp.url("opencode.db"),
        "gemini_cli": tmp.url("gemini"),
    ]
}

@Test func toolNames() {
    #expect(Tools.tools.map { [$0.key, $0.name] } == [
        ["claude_code", "Claude Code"], ["codex", "Codex"], ["opencode", "opencode"],
        ["gemini_cli", "Gemini CLI"],
    ])
}

@Test func detectOnlyExisting() {
    let tmp = TempDir()
    let p = paths(tmp)
    tmp.mkdir("claude/projects")
    writeText(p["opencode"]!, "")

    #expect(Tools.detectTools(paths: p) == ["claude_code", "opencode"])
}

@Test func claudeViewUsesExistingKeys() {
    var daily = JSONObject()
    UsageStats.addUsage(&daily, day: Day(2026, 7, 29), model: "claude-opus-5-5", project: "~/p",
                        parts: parts(input: 7))
    let state: JSONObject = ["grand_total": 100, "daily": daily]

    let view = Tools.toolView(state, "claude_code")

    #expect(view.key == "claude_code")
    #expect(view.name == "Claude Code")
    #expect(jsonEqual(view.daily, daily))
    #expect(view.grandTotal == 100)
    #expect(view.error == nil)
    #expect(view.views == nil)
    #expect(state["sources"] == nil)
}

@Test func combinedSumsToolsAndGroupsByModel() {
    var claudeDaily = JSONObject(), opencodeDaily = JSONObject()
    UsageStats.addUsage(&claudeDaily, day: Day(2026, 7, 29), model: "claude-opus-5-5", project: "~/p",
                        parts: parts(input: 7))
    UsageStats.addUsage(&opencodeDaily, day: Day(2026, 7, 29), model: "claude-opus-5-5", project: "~/p",
                        parts: parts(input: 3))
    UsageStats.addUsage(&opencodeDaily, day: Day(2026, 7, 29), model: "gemini-4-argon", project: "~/p",
                        parts: parts(output: 5))
    let state: JSONObject = [
        "grand_total": 100,
        "daily": claudeDaily,
        "sources": ["opencode": ["daily": opencodeDaily, "error": "boom"]],
    ]

    let view = Tools.combinedView(state, enabled: ["claude_code", "opencode"])

    #expect(view.key == "all" && view.name == "All AIs")
    #expect(view.grandTotal == 108)
    let models = dig(view.daily, "2026-07-29", "models")
    #expect(JSON.int(dig(models, "claude-opus-5-5", "input")) == 10)
    #expect(JSON.int(dig(models, "gemini-4-argon", "output")) == 5)
    #expect(view.error == "opencode: boom")
}

@Test func scanSkipsDisabledTools() throws {
    let tmp = TempDir()
    let p = paths(tmp)
    writeText(p["claude_code"]!.appendingPathComponent("proj/s.jsonl"), jsonLine([
        "type": "assistant", "timestamp": "2026-07-29T12:00:00.000Z",
        "message": ["model": "claude-opus-5-5", "usage": ["input_tokens": 9, "output_tokens": 1]],
    ]))
    writeText(p["codex"]!.appendingPathComponent("2026/rollout.jsonl"), [
        ["timestamp": "2026-07-29T12:00:00.000Z", "type": "turn_context", "payload": ["model": "gpt-x", "cwd": "/x"]],
        ["timestamp": "2026-07-29T12:00:00.000Z", "type": "token_usage_record",
         "payload": ["response_id": "r", "usage": ["input_tokens": 4, "output_tokens": 2]]],
    ].map(jsonLine).joined())
    var state: JSONObject = ["grand_total": 0, "file_offsets": JSONObject(), "daily": JSONObject()]

    try Tools.scanTools(&state, enabled: ["codex"], paths: p)

    #expect(state.int("grand_total") == 0)
    #expect(Tools.toolView(state, "codex").grandTotal == 6)

    try Tools.scanTools(&state, enabled: ["claude_code", "codex"], paths: p)

    #expect(state.int("grand_total") == 10)
    #expect(Tools.toolView(state, "codex").grandTotal == 6)
}
