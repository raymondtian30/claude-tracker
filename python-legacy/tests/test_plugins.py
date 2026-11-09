import json
from datetime import datetime, timezone

import plugins


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))


def make_plugin(root, name, skills=(), agents=(), hooks=None, mcp=None):
    """A plugin install folder like the ones in ~/.claude/plugins/cache."""
    write_json(root / ".claude-plugin" / "plugin.json", {"name": name})
    for skill in skills:
        (root / "skills" / skill).mkdir(parents=True)
        (root / "skills" / skill / "SKILL.md").write_text("---\n---\n")
    for agent in agents:
        (root / "agents").mkdir(parents=True, exist_ok=True)
        (root / "agents" / f"{agent}.md").write_text("")
    if hooks:
        write_json(root / "hooks" / "hooks.json", {"hooks": hooks})
    if mcp:
        write_json(root / ".mcp.json", {"mcpServers": mcp})
    return root


def setup_claude(tmp_path, enabled, installs):
    """A ~/.claude with `enabled` plugin ids and their install folders."""
    claude = tmp_path / ".claude"
    write_json(claude / "settings.json", {"enabledPlugins": enabled})
    write_json(claude / "plugins" / "installed_plugins.json", {
        "version": 2,
        "plugins": {pid: [{"installPath": str(path)}] for pid, path in installs.items()},
    })
    return claude


def hook(command, status=None):
    entry = {"type": "command", "command": command}
    if status:
        entry["statusMessage"] = status
    return entry


def ts(hour, minute=0):
    return f"2026-11-08T{hour:02d}:{minute:02d}:00.000Z"


def tool_use(name, when, **inputs):
    return {"type": "assistant", "timestamp": when,
            "message": {"content": [{"type": "tool_use", "name": name, "input": inputs}]}}


def write_log(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(e) for e in entries) + "\n")
    return path


NOW = datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc).timestamp()


def test_enabled_plugins_reads_settings_and_install_paths(tmp_path):
    sp = make_plugin(tmp_path / "sp", "superpowers")
    claude = setup_claude(tmp_path, {"superpowers@dev": True, "off@x": False}, {"superpowers@dev": sp})

    found = plugins.enabled_plugins(claude)

    assert [(p["id"], p["name"], p["prefix"]) for p in found] == [("superpowers@dev", "superpowers", "superpowers")]


def test_enabled_plugins_labels_duplicate_names_by_source(tmp_path):
    a = make_plugin(tmp_path / "a", "superpowers")
    b = make_plugin(tmp_path / "b", "superpowers")
    claude = setup_claude(tmp_path, {"superpowers@dev": True, "superpowers@dir": True},
                          {"superpowers@dev": a, "superpowers@dir": b})

    labels = [p["label"] for p in plugins.enabled_plugins(claude)]

    assert labels == ["superpowers (dev)", "superpowers (dir)"]


def test_enabled_plugins_survives_missing_files(tmp_path):
    assert plugins.enabled_plugins(tmp_path / "nothing") == []


def test_enabled_plugins_survives_odd_settings(tmp_path):
    claude = tmp_path / ".claude"
    write_json(claude / "settings.json", {"enabledPlugins": ["not", "a", "dict"]})
    write_json(claude / "plugins" / "installed_plugins.json", {"plugins": {"x@y": "bad"}})
    assert plugins.enabled_plugins(claude) == []
    write_json(claude / "settings.json", {"enabledPlugins": {"x@y": True}})
    assert [p["id"] for p in plugins.enabled_plugins(claude)] == ["x@y"]


def test_project_settings_turn_plugins_off_for_that_folder(tmp_path):
    sp = make_plugin(tmp_path / "sp", "superpowers")
    cm = make_plugin(tmp_path / "cm", "caveman")
    claude = setup_claude(tmp_path, {"superpowers@dev": True, "caveman@cm": True},
                          {"superpowers@dev": sp, "caveman@cm": cm})
    project = tmp_path / "proj"
    write_json(project / ".claude" / "settings.local.json", {"enabledPlugins": {"caveman@cm": False}})

    loaded = plugins.loaded_in(str(project), plugins.enabled_plugins(claude))

    assert loaded == {"superpowers@dev": True, "caveman@cm": False}


def test_live_plugins_attributes_skills_agents_hooks_and_tools(tmp_path):
    sp = make_plugin(tmp_path / "sp", "superpowers", skills=["brainstorming"],
                     hooks={"SessionStart": [{"hooks": [hook("run-hook session-start")]}]})
    cm = make_plugin(tmp_path / "cm", "caveman", agents=["cavecrew-builder"],
                     hooks={"UserPromptSubmit": [{"hooks": [hook("node track.js", "Tracking...")]}]},
                     mcp={"mem": {"command": "x"}})
    claude = setup_claude(tmp_path, {"superpowers@dev": True, "caveman@cm": True},
                          {"superpowers@dev": sp, "caveman@cm": cm})
    log = write_log(tmp_path / "log.jsonl", [
        {"type": "attachment", "timestamp": ts(9),
         "attachment": {"type": "hook_success", "hookEvent": "SessionStart",
                        "command": "run-hook session-start"}},
        {"type": "user", "timestamp": ts(9, 1),
         "message": {"content": "<command-name>/superpowers:brainstorming</command-name>"}},
        tool_use("Skill", ts(9, 2), skill="superpowers:brainstorming"),
        tool_use("Agent", ts(10), subagent_type="caveman:cavecrew-builder"),
        tool_use("mcp__plugin_caveman_mem__recall", ts(10, 5)),
        {"type": "attachment", "timestamp": ts(11),
         "attachment": {"type": "hook_additional_context", "hookEvent": "UserPromptSubmit"}},
        tool_use("Bash", ts(11, 30), command="ls"),
    ])
    sessions = [{"label": "~/proj", "tokens": 5, "cwd": str(tmp_path / "proj"), "log": str(log)}]

    rows = plugins.live_plugins(sessions, claude_dir=claude, now=NOW)

    assert sessions[0]["plugins"] == [("superpowers", True), ("caveman", True)]
    by_label = {r["label"]: r for r in rows}
    assert by_label["superpowers"]["sessions"] == 1
    assert by_label["superpowers"]["today"] == {"skill": 2, "hook": 1}
    assert by_label["superpowers"]["latest"]["text"] == "Ran brainstorming skill"
    assert by_label["caveman"]["today"] == {"agent": 1, "tool": 1, "hook": 1}
    assert by_label["caveman"]["latest"]["text"] == "Added context to your prompt"
    # Most recently active first.
    assert [r["label"] for r in rows] == ["caveman", "superpowers"]


def test_live_plugins_hook_status_message_matches(tmp_path):
    """Claude Code logs a hook's statusMessage in place of its command."""
    cm = make_plugin(tmp_path / "cm", "caveman",
                     hooks={"SessionStart": [{"hooks": [hook("node activate.js", "Loading caveman mode...")]}]})
    claude = setup_claude(tmp_path, {"caveman@cm": True}, {"caveman@cm": cm})
    log = write_log(tmp_path / "log.jsonl", [
        {"type": "attachment", "timestamp": ts(9),
         "attachment": {"type": "hook_success", "hookEvent": "SessionStart",
                        "command": "Loading caveman mode..."}},
    ])
    sessions = [{"label": "~/p", "tokens": 1, "cwd": str(tmp_path), "log": str(log)}]

    rows = plugins.live_plugins(sessions, claude_dir=claude, now=NOW)

    assert rows[0]["latest"]["text"] == "SessionStart hook ran"


def test_live_plugins_hooks_in_plugin_json_count(tmp_path):
    cm = make_plugin(tmp_path / "cm", "caveman")
    write_json(cm / ".claude-plugin" / "plugin.json", {
        "name": "caveman",
        "hooks": {"SessionEnd": [{"hooks": [hook("node stats.js", "Recording caveman stats...")]}]},
    })
    claude = setup_claude(tmp_path, {"caveman@cm": True}, {"caveman@cm": cm})
    log = write_log(tmp_path / "log.jsonl", [
        {"type": "attachment", "timestamp": ts(9),
         "attachment": {"type": "hook_success", "hookEvent": "SessionEnd",
                        "command": "Recording caveman stats..."}},
    ])
    sessions = [{"label": "~/p", "tokens": 1, "cwd": str(tmp_path), "log": str(log)}]

    assert plugins.live_plugins(sessions, claude_dir=claude, now=NOW)[0]["today"] == {"hook": 1}


def test_live_plugins_skips_prompt_context_it_cannot_pin_on_one_plugin(tmp_path):
    a = make_plugin(tmp_path / "a", "one", hooks={"SessionStart": [{"hooks": [hook("a")]}]})
    b = make_plugin(tmp_path / "b", "two", hooks={"SessionStart": [{"hooks": [hook("b")]}]})
    claude = setup_claude(tmp_path, {"one@x": True, "two@x": True}, {"one@x": a, "two@x": b})
    log = write_log(tmp_path / "log.jsonl", [
        {"type": "attachment", "timestamp": ts(9),
         "attachment": {"type": "hook_additional_context", "hookEvent": "SessionStart"}},
    ])
    sessions = [{"label": "~/p", "tokens": 1, "cwd": str(tmp_path), "log": str(log)}]

    rows = plugins.live_plugins(sessions, claude_dir=claude, now=NOW)

    assert all(r["latest"] is None and r["today"] == {} for r in rows)


def test_live_plugins_counts_today_only_but_keeps_older_latest(tmp_path):
    sp = make_plugin(tmp_path / "sp", "superpowers", skills=["tdd"])
    claude = setup_claude(tmp_path, {"superpowers@dev": True}, {"superpowers@dev": sp})
    log = write_log(tmp_path / "log.jsonl", [
        tool_use("Skill", "2026-11-01T09:00:00.000Z", skill="superpowers:tdd"),
    ])
    sessions = [{"label": "~/p", "tokens": 1, "cwd": str(tmp_path), "log": str(log)}]

    row = plugins.live_plugins(sessions, claude_dir=claude, now=NOW)[0]

    assert row["today"] == {}
    assert row["latest"]["text"] == "Ran tdd skill"


def test_live_plugins_off_in_a_project_is_not_counted_there(tmp_path):
    cm = make_plugin(tmp_path / "cm", "caveman", skills=["caveman"])
    claude = setup_claude(tmp_path, {"caveman@cm": True}, {"caveman@cm": cm})
    project = tmp_path / "proj"
    write_json(project / ".claude" / "settings.json", {"enabledPlugins": {"caveman@cm": False}})
    log = write_log(tmp_path / "log.jsonl", [tool_use("Skill", ts(9), skill="caveman:caveman")])
    sessions = [{"label": "~/proj", "tokens": 1, "cwd": str(project), "log": str(log)}]

    row = plugins.live_plugins(sessions, claude_dir=claude, now=NOW)[0]

    assert sessions[0]["plugins"] == [("caveman", False)]
    assert row["sessions"] == 0 and row["latest"] is None


def test_live_plugins_leaves_other_tools_sessions_alone(tmp_path):
    claude = setup_claude(tmp_path, {}, {})
    sessions = [{"label": "~/game", "tokens": None}]

    assert plugins.live_plugins(sessions, claude_dir=claude, now=NOW) == []
    assert "plugins" not in sessions[0]


def test_live_plugins_ambiguous_duplicate_goes_to_first_install(tmp_path):
    a = make_plugin(tmp_path / "a", "superpowers", skills=["tdd"])
    b = make_plugin(tmp_path / "b", "superpowers", skills=["tdd"])
    claude = setup_claude(tmp_path, {"superpowers@dev": True, "superpowers@dir": True},
                          {"superpowers@dev": a, "superpowers@dir": b})
    log = write_log(tmp_path / "log.jsonl", [tool_use("Skill", ts(9), skill="superpowers:tdd")])
    sessions = [{"label": "~/p", "tokens": 1, "cwd": str(tmp_path), "log": str(log)}]

    rows = {r["label"]: r for r in plugins.live_plugins(sessions, claude_dir=claude, now=NOW)}

    assert rows["superpowers (dev)"]["today"] == {"skill": 1}
    assert rows["superpowers (dir)"]["today"] == {}
    # Both installs share one tag on the session.
    assert sessions[0]["plugins"] == [("superpowers", True)]
