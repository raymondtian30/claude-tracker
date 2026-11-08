"""Gemini CLI usage, read from the chat sessions Gemini CLI saves on this Mac.

Gemini CLI records each session under ~/.gemini/tmp/<project>/chats/ as a
JSONL file (older versions: one .json file). Each reply ("gemini" message)
carries the token counts the Gemini API returned and the model used. Only
those counts, the model, the time and the project folder are read; prompts
and replies in the same files are skipped.

Like Codex, each file is re-read whole when it changes and replaces its
previous contribution; files that disappear keep their last contribution.
"""

import json
from pathlib import Path

from usage_stats import (
    SourceFormatError,
    _local_date_of,
    add_usage,
    merge_daily,
    project_label,
)

GEMINI_DIR = Path.home() / ".gemini"


def _parts(tokens):
    """Gemini's counts -> the app's categories. `input` (promptTokenCount)
    includes the cached tokens, so they're split out; tool-use prompt tokens
    are input and thinking tokens are output, so the parts add up to the
    API's own total."""
    cached = tokens.get("cached", 0) or 0
    return {
        "input": max((tokens.get("input", 0) or 0) - cached, 0) + (tokens.get("tool", 0) or 0),
        "output": (tokens.get("output", 0) or 0) + (tokens.get("thoughts", 0) or 0),
        "cache_write_5m": 0,
        "cache_write_1h": 0,
        "cache_read": cached,
    }


def _records(path):
    """The session's records. A JSONL line still being written (no newline
    yet) is left for the next scan."""
    data = Path(path).read_bytes()
    if path.suffix == ".json":
        session = json.loads(data)
        if not isinstance(session, dict) or "messages" not in session:
            raise SourceFormatError(f"{path.name} doesn't look like a Gemini CLI session")
        return [session] + list(session["messages"])
    records = []
    for line in data.splitlines(keepends=True):
        if not line.endswith(b"\n"):
            break
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def read_gemini_file(path, project):
    """This session file's per-day buckets, filed under `project` (a folder
    path or label)."""
    path = Path(path)
    records = _records(path)
    if records and not any("sessionId" in r or "type" in r or "$set" in r for r in records):
        raise SourceFormatError(f"{path.name} doesn't look like a Gemini CLI session")

    # A reply can be written again as its token counts arrive; the last
    # version of each message id wins.
    replies = {}
    for record in records:
        if record.get("type") == "gemini" and record.get("tokens"):
            replies[record.get("id") or len(replies)] = record

    daily = {}
    label = project_label(project) if project.startswith("/") else project
    for reply in replies.values():
        parts = _parts(reply["tokens"])
        if reply.get("timestamp") and sum(parts.values()):
            add_usage(daily, _local_date_of(reply["timestamp"]), reply.get("model") or "unknown",
                      label, parts)
    return daily


def _project_roots(gemini_dir):
    """{project folder name under tmp/: project path}, from projects.json."""
    try:
        projects = json.loads((Path(gemini_dir) / "projects.json").read_text())["projects"]
        return {slug: root for root, slug in projects.items()}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def _project_of(folder, roots):
    marker = folder / ".project_root"
    try:
        root = marker.read_text().strip()
        if root:
            return root
    except OSError:
        pass
    return roots.get(folder.name, folder.name)


def scan_gemini(source_state, gemini_dir=GEMINI_DIR):
    """Update `source_state` from Gemini CLI's saved sessions. Sets
    source_state["error"] to a message if a file couldn't be read, else None."""
    files = source_state.setdefault("files", {})
    errors = []
    temp = Path(gemini_dir) / "tmp"
    roots = _project_roots(gemini_dir)
    folders = sorted(p for p in temp.iterdir() if p.is_dir()) if temp.is_dir() else []
    for folder in folders:
        chats = folder / "chats"
        if not chats.is_dir():
            continue
        project = _project_of(folder, roots)
        for path in sorted([*chats.rglob("*.jsonl"), *chats.rglob("*.json")]):
            key = str(path)
            try:
                stat = path.stat()
            except FileNotFoundError:
                continue
            saved = files.get(key)
            if saved and saved["size"] == stat.st_size and saved["mtime"] == stat.st_mtime:
                continue
            try:
                daily = read_gemini_file(path, project)
            except (SourceFormatError, OSError, ValueError) as e:
                errors.append(str(e))
                continue
            files[key] = {"size": stat.st_size, "mtime": stat.st_mtime, "daily": daily}
    source_state["error"] = errors[0] if errors else None
    return source_state


def gemini_daily(source_state):
    return merge_daily([f["daily"] for f in source_state.get("files", {}).values()])


def gemini_total(source_state):
    return sum(
        sum(parts.values())
        for f in source_state.get("files", {}).values()
        for bucket in f["daily"].values()
        for parts in bucket["models"].values()
    )
