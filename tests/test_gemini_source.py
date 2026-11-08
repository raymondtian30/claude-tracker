import json
import os

import pytest

from gemini_source import gemini_daily, gemini_total, read_gemini_file, scan_gemini

TS = "2026-07-29T12:00:00.000Z"


def meta():
    return {"sessionId": "s1", "projectHash": "abc", "startTime": TS, "lastUpdated": TS}


def reply(id="m2", model="gemini-2.5-pro", input=100, output=20, cached=60, thoughts=5, tool=3,
          total=128):
    return {"id": id, "timestamp": TS, "type": "gemini", "content": "...", "model": model,
            "tokens": {"input": input, "output": output, "cached": cached, "thoughts": thoughts,
                       "tool": tool, "total": total}}


def write_jsonl(path, records, trailing=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records) + trailing)
    return path


def project(tmp_path, slug="myproj", root="/Users/me/myproj"):
    folder = tmp_path / "tmp" / slug
    folder.mkdir(parents=True, exist_ok=True)
    (folder / ".project_root").write_text(root)
    return folder


def test_reply_tokens_split_into_the_apps_categories(tmp_path):
    folder = project(tmp_path)
    path = write_jsonl(folder / "chats" / "session-2026-07-29T12-00-s1.jsonl", [
        meta(),
        {"id": "m1", "timestamp": TS, "type": "user", "content": "hi"},
        reply(),
    ])

    daily = read_gemini_file(path, "/Users/me/myproj")

    bucket = next(iter(daily.values()))
    parts = bucket["models"]["gemini-2.5-pro"]
    # input counts cached tokens, so they're split out; tool-use prompt
    # tokens are input; thinking tokens are output. All of it adds to total.
    assert parts["input"] == 100 - 60 + 3
    assert parts["cache_read"] == 60
    assert parts["output"] == 20 + 5
    assert sum(parts.values()) == 128
    assert list(bucket["projects"]) == ["/Users/me/myproj"]


def test_a_reply_updated_later_counts_once_with_its_latest_tokens(tmp_path):
    path = write_jsonl(tmp_path / "s.jsonl", [
        meta(),
        reply(input=10, output=1, cached=0, thoughts=0, tool=0, total=11),
        {"$set": {"lastUpdated": TS}},
        reply(input=10, output=7, cached=0, thoughts=0, tool=0, total=17),
    ])

    daily = read_gemini_file(path, "p")

    assert sum(next(iter(daily.values()))["models"]["gemini-2.5-pro"].values()) == 17


def test_half_written_last_line_waits(tmp_path):
    path = write_jsonl(tmp_path / "s.jsonl", [meta(), reply()], trailing='{"id": "m3", "type": "gem')

    daily = read_gemini_file(path, "p")

    assert sum(next(iter(daily.values()))["models"]["gemini-2.5-pro"].values()) == 128


def test_legacy_json_session(tmp_path):
    path = tmp_path / "session-old.json"
    path.write_text(json.dumps({**meta(), "messages": [reply(id="a"), reply(id="b")]}))

    daily = read_gemini_file(path, "p")

    assert sum(next(iter(daily.values()))["models"]["gemini-2.5-pro"].values()) == 256


def test_not_a_gemini_session_is_an_error(tmp_path):
    path = write_jsonl(tmp_path / "s.jsonl", [{"hello": "world"}])

    with pytest.raises(Exception, match="doesn't look like a Gemini CLI session"):
        read_gemini_file(path, "p")


def test_scan_finds_sessions_and_subagents_and_labels_projects(tmp_path):
    folder = project(tmp_path)
    write_jsonl(folder / "chats" / "session-a.jsonl", [meta(), reply()])
    write_jsonl(folder / "chats" / "s1" / "sub.jsonl", [meta(), reply(id="x")])
    # A folder without .project_root falls back to projects.json.
    other = tmp_path / "tmp" / "other"
    write_jsonl(other / "chats" / "session-b.jsonl", [meta(), reply(id="y")])
    (tmp_path / "projects.json").write_text(json.dumps({"projects": {"/Users/me/other": "other"}}))

    state = scan_gemini({}, tmp_path)

    assert state["error"] is None
    assert gemini_total(state) == 3 * 128
    projects = set()
    for bucket in gemini_daily(state).values():
        projects |= set(bucket["projects"])
    assert projects == {"/Users/me/myproj", "/Users/me/other"}


def test_scan_rereads_only_changed_files_and_keeps_deleted_ones(tmp_path):
    folder = project(tmp_path)
    path = write_jsonl(folder / "chats" / "session-a.jsonl", [meta(), reply()])
    state = scan_gemini({}, tmp_path)

    os.remove(path)
    scan_gemini(state, tmp_path)

    assert gemini_total(state) == 128


def test_scan_with_nothing_there(tmp_path):
    state = scan_gemini({}, tmp_path / "missing")

    assert gemini_total(state) == 0
    assert state["error"] is None
