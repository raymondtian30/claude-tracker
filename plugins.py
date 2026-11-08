"""Which Claude Code plugins are enabled, which open sessions run them, and
what each has been doing there.

Everything comes from files Claude Code already keeps:
- ~/.claude/settings.json "enabledPlugins": what's turned on for you
- a project's .claude/settings.json and settings.local.json: per-folder overrides
- ~/.claude/plugins/installed_plugins.json: where each plugin's files are
- each plugin's own files: its skills, agents, hooks and MCP servers, so
  activity in a session log can be traced back to it
- the session logs: skills run, agents started, MCP tools used, hooks fired

Kept free of AppKit so it can be unit-tested.
"""

import json
import os
from collections import Counter
from datetime import datetime
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
PROJECT_SETTINGS = (".claude/settings.json", ".claude/settings.local.json")

# Cheap text checks that skip the many log lines with no plugin activity.
ACTIVITY_MARKERS = ('"tool_use"', "<command-name>", '"hook_')


def _load_json(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _hook_details(hooks):
    """(events, strings) from a hooks config: the events it hooks into and
    each hook's command and status message (Claude Code logs the status
    message in place of the command when there is one)."""
    events, strings = set(), set()
    if not isinstance(hooks, dict):
        return events, strings
    for event, groups in hooks.items():
        for group in groups if isinstance(groups, list) else []:
            for h in group.get("hooks", []) if isinstance(group, dict) else []:
                if not isinstance(h, dict):
                    continue
                events.add(event)
                strings.update(s for s in (h.get("command"), h.get("statusMessage")) if s)
    return events, strings


def _profile(install_path):
    """What a plugin brings, read from its install folder: its name as used
    in skill and agent names, those names, and its hooks and MCP servers."""
    root = Path(install_path) if install_path else None
    manifest = _load_json(root / ".claude-plugin" / "plugin.json") if root else {}
    names = set()
    events, strings = set(), set()
    servers = set()
    if root and root.is_dir():
        for folder in ("skills", "agents", "commands"):
            for entry in (root / folder).glob("*") if (root / folder).is_dir() else []:
                names.add(entry.stem)
        hooks_file = _load_json(root / "hooks" / "hooks.json").get("hooks")
        for config in (hooks_file, manifest.get("hooks")):
            if isinstance(config, str):
                config = _load_json(root / config).get("hooks")
            e, s = _hook_details(config)
            events |= e
            strings |= s
        for config in (_load_json(root / ".mcp.json").get("mcpServers"), manifest.get("mcpServers")):
            if isinstance(config, dict):
                servers.update(config)
    return {
        "prefix": manifest.get("name"),
        "names": names,
        "hook_events": events,
        "hook_strings": strings,
        "servers": servers,
    }


def user_enabled_ids(claude_dir=CLAUDE_DIR):
    """Ids of the plugins turned on in your own settings, in order."""
    settings = _load_json(Path(claude_dir) / "settings.json").get("enabledPlugins")
    return [pid for pid, on in settings.items() if on is True] if isinstance(settings, dict) else []


def enabled_plugins(claude_dir=CLAUDE_DIR, extra_ids=()):
    """The plugins turned on in your settings (plus `extra_ids`, ones a
    project turns on), in settings order, each a dict with its id
    ("name@source"), name, label (name, plus its source when two enabled
    plugins share a name) and what _profile() finds in its files."""
    claude_dir = Path(claude_dir)
    installed = _load_json(claude_dir / "plugins" / "installed_plugins.json").get("plugins")
    installed = installed if isinstance(installed, dict) else {}
    ids = user_enabled_ids(claude_dir)
    ids += [pid for pid in extra_ids if pid not in ids]

    found = []
    for pid in ids:
        name, _, source = pid.partition("@")
        installs = installed.get(pid)
        install = installs[0] if isinstance(installs, list) and installs and isinstance(installs[0], dict) else {}
        profile = _profile(install.get("installPath"))
        found.append({"id": pid, "name": name, "source": source, **profile,
                      "prefix": profile["prefix"] or name})
    counts = Counter(p["name"] for p in found)
    for p in found:
        p["label"] = f"{p['name']} ({p['source']})" if counts[p["name"]] > 1 and p["source"] else p["name"]
    return found


def project_overrides(cwd):
    """enabledPlugins from a folder's own Claude settings (local wins)."""
    overrides = {}
    for name in PROJECT_SETTINGS:
        value = _load_json(Path(cwd) / name).get("enabledPlugins")
        if isinstance(value, dict):
            overrides.update(value)
    return overrides


def loaded_in(cwd, enabled, overrides=None):
    """{plugin id: whether it runs} for a session in `cwd`."""
    overrides = project_overrides(cwd) if overrides is None else overrides
    return {p["id"]: overrides.get(p["id"], True) is not False for p in enabled}


# -- reading what happened in a session log


def _timestamp(entry):
    try:
        return datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).timestamp()
    except (KeyError, AttributeError, ValueError):
        return None


def _command_name(content):
    """The plugin slash command in a user message ("plugin:name"), if any."""
    if isinstance(content, list):
        content = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    if not isinstance(content, str):
        return None
    start = content.find("<command-name>")
    end = content.find("</command-name>")
    if start < 0 or end < start:
        return None
    name = content[start + len("<command-name>"):end].strip().lstrip("/")
    return name if ":" in name else None


def log_events(path):
    """Plugin-related events in one session log, oldest first, each
    (when, kind, detail): ("skill", "plugin:skill"), ("agent", "plugin:agent"),
    ("tool", "mcp__plugin_..."), ("hook", (event, command)) or
    ("context", event) for text a hook added."""
    events = []
    try:
        f = open(path, errors="replace")
    except OSError:
        return events
    with f:
        for line in f:
            if not any(marker in line for marker in ACTIVITY_MARKERS):
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            when = _timestamp(entry)
            if when is None:
                continue
            attachment = entry.get("attachment")
            if isinstance(attachment, dict):
                kind = attachment.get("type", "")
                if kind == "hook_additional_context":
                    events.append((when, "context", attachment.get("hookEvent")))
                elif kind.startswith("hook_") and attachment.get("command"):
                    events.append((when, "hook", (attachment.get("hookEvent"), attachment["command"])))
                continue
            message = entry.get("message")
            if not isinstance(message, dict):
                continue
            if entry.get("type") == "user":
                name = _command_name(message.get("content"))
                if name:
                    events.append((when, "skill", name))
                continue
            content = message.get("content")
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tool = block.get("name", "")
                inputs = block.get("input") if isinstance(block.get("input"), dict) else {}
                if tool == "Skill" and ":" in str(inputs.get("skill", "")):
                    events.append((when, "skill", inputs["skill"]))
                elif tool in ("Agent", "Task") and ":" in str(inputs.get("subagent_type", "")):
                    events.append((when, "agent", inputs["subagent_type"]))
                elif tool.startswith("mcp__plugin_"):
                    events.append((when, "tool", tool))
    return events


_cache = {}  # log path -> ((mtime, size), events)


def cached_log_events(path):
    """log_events(), reread only when the log has changed."""
    try:
        stat = os.stat(path)
    except OSError:
        return []
    key = (stat.st_mtime, stat.st_size)
    hit = _cache.get(path)
    if hit and hit[0] == key:
        return hit[1]
    events = log_events(path)
    _cache[path] = (key, events)
    return events


def _attribute(kind, detail, running):
    """(plugin, what it did) for one event, among the plugins `running` in
    that session, or None. Plugins that share a name can't be told apart
    in the log, so the first one listed in settings gets it."""
    if kind in ("skill", "agent"):
        prefix, _, name = detail.partition(":")
        matches = [p for p in running if p["prefix"] == prefix]
        matches = [p for p in matches if name in p["names"]] or matches
        text = f"Ran {name} skill" if kind == "skill" else f"Started {name} agent"
    elif kind == "tool":
        matches = [p for p in running if detail.startswith(f"mcp__plugin_{p['prefix']}_")]
        text = f"Used {detail.rsplit('__', 1)[-1]} tool"
    elif kind == "hook":
        event, command = detail
        matches = [p for p in running if command in p["hook_strings"]]
        text = f"{event} hook ran"
    elif kind == "context":
        # Only the event is logged; credit it when just one plugin hooks it.
        matches = [p for p in running if detail in p["hook_events"]]
        if len({p["prefix"] for p in matches}) != 1:
            return None
        text = "Added context to your prompt" if detail == "UserPromptSubmit" else f"{detail} hook ran"
        kind = "hook"
    else:
        return None
    return (matches[0], kind, text) if matches else None


def live_plugins(sessions, claude_dir=CLAUDE_DIR, now=None):
    """Plugin rows for the Live tab, most recently active first, each
    {"label", "sessions": open sessions running it, "latest": {"text", "at"}
    or None, "today": {kind: count}}.

    Also gives each Claude Code session (one with a "cwd" and "log") a
    "plugins" list of (name, runs in it), in settings order."""
    claude_sessions = [s for s in sessions if s.get("cwd") and s.get("log")]
    overrides = {s["cwd"]: project_overrides(s["cwd"]) for s in claude_sessions}
    extra = [pid for o in overrides.values() for pid, on in o.items() if on is True]
    enabled = enabled_plugins(claude_dir, extra_ids=extra)
    user_on = set(user_enabled_ids(claude_dir))

    today = datetime.fromtimestamp(now if now is not None else datetime.now().timestamp()).date()
    rows = {p["id"]: {"label": p["label"], "sessions": 0, "latest": None, "today": Counter()}
            for p in enabled}
    for session in claude_sessions:
        loaded = loaded_in(session["cwd"], enabled, overrides[session["cwd"]])
        # A plugin only a different project turns on doesn't belong here.
        shown = [p for p in enabled if p["id"] in user_on or overrides[session["cwd"]].get(p["id"]) is True]
        # Tags use the bare name: two installs of one plugin are one tag,
        # on if either runs, so the tags stay short.
        tags = {}
        for p in shown:
            tags[p["name"]] = tags.get(p["name"], False) or loaded[p["id"]]
        session["plugins"] = list(tags.items())
        running = [p for p in shown if loaded[p["id"]]]
        for p in running:
            rows[p["id"]]["sessions"] += 1
        for when, kind, detail in cached_log_events(session["log"]):
            found = _attribute(kind, detail, running)
            if not found:
                continue
            plugin, kind, text = found
            row = rows[plugin["id"]]
            if row["latest"] is None or when >= row["latest"]["at"]:
                row["latest"] = {"text": text, "at": when}
            if datetime.fromtimestamp(when).date() == today:
                row["today"][kind] += 1

    result = [rows[p["id"]] for p in enabled if p["id"] in user_on or rows[p["id"]]["sessions"]]
    for row in result:
        row["today"] = dict(row["today"])
    result.sort(key=lambda r: -(r["latest"]["at"] if r["latest"] else float("-inf")))
    return result
