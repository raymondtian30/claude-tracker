from datetime import datetime

from limits import (
    alerts_to_send,
    migrate_alert_state,
    claude_limits,
    codex_limits,
    limit_windows,
    reached_claude_limits,
    window_for_minutes,
)

NOW = datetime(2026, 11, 8, 12, 0, 0).timestamp()


def test_window_for_minutes():
    assert window_for_minutes(300) == "five_hour"
    assert window_for_minutes(10080) == "weekly"
    assert window_for_minutes(43200) == "monthly"


def test_codex_limits_from_its_rate_limit_record():
    record = {"primary": {"used_percent": 83.0, "window_minutes": 300, "resets_at": NOW + 600},
              "secondary": {"used_percent": 40.5, "window_minutes": 10080, "resets_at": NOW + 9999},
              "plan_type": "plus"}

    assert codex_limits(record, NOW) == [
        {"window": "five_hour", "label": "5-hour", "percent": 83.0, "resets_at": NOW + 600},
        {"window": "weekly", "label": "Weekly", "percent": 40.5, "resets_at": NOW + 9999},
    ]


def test_codex_limit_whose_window_has_reset_reads_zero():
    record = {"primary": {"used_percent": 83.0, "window_minutes": 43200, "resets_at": NOW - 1},
              "secondary": None}

    assert codex_limits(record, NOW) == [
        {"window": "monthly", "label": "Monthly", "percent": 0.0, "resets_at": None},
    ]


def test_codex_limits_without_a_record():
    assert codex_limits(None, NOW) == []


def test_claude_limit_reached_until_it_resets():
    hits = {"five_hour": NOW + 3600, "seven_day": NOW - 10}

    assert reached_claude_limits(hits, NOW) == [
        {"window": "five_hour", "label": "5-hour", "percent": 100.0, "resets_at": NOW + 3600,
         "reached": True},
    ]


def claude_usage(**changes):
    limits = [
        {"kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 23.0,
         "resets_at": NOW + 600},
        {"kind": "weekly", "window": "weekly", "label": "Weekly", "percent": 41.0,
         "resets_at": NOW - 1},
    ]
    return {"limits": limits, "error": None, "fetched_at": NOW, **changes}


def test_claude_limits_use_anthropics_percentages():
    state = {"claude_usage": claude_usage(), "claude_limit_hits": {"five_hour": NOW + 60}}

    assert [(l["kind"], l["percent"], l["resets_at"]) for l in claude_limits(state, NOW)] == [
        ("five_hour", 23.0, NOW + 600),
        ("weekly", 0.0, None),  # its reset time passed: 0% until the next fetch
    ]


def test_claude_limits_fall_back_to_the_logs_without_percentages():
    hits = {"five_hour": NOW + 60}

    for state in ({"claude_usage": claude_usage(limits=[], error="offline")},
                  {"claude_usage": claude_usage(), "claude_usage_enabled": False}):
        state["claude_limit_hits"] = hits
        assert [l["percent"] for l in claude_limits(state, NOW)] == [100.0]


def level(id="codex:five_hour", window="five_hour", percent=80.0, resets_at=None):
    return {"id": id, "name": "Codex", "window": window, "label": "5-hour", "percent": percent,
            "resets_at": resets_at}


def test_alert_once_when_crossing_the_threshold():
    messages, above = alerts_to_send([level()], [75], ["five_hour"], [])

    assert messages == ["Codex: 5-hour usage is at 80%."]
    assert above == ["codex:five_hour@75"]

    messages, above = alerts_to_send([level(percent=90.0)], [75], ["five_hour"], above)
    assert messages == []  # already told

    messages, above = alerts_to_send([level(percent=10.0)], [75], ["five_hour"], above)
    assert above == []  # dropped below (e.g. the window reset): ready to alert again


def test_alert_again_at_each_higher_threshold():
    messages, above = alerts_to_send([level(percent=76.0)], [75, 90], ["five_hour"], [])
    assert messages == ["Codex: 5-hour usage is at 76%."]

    messages, above = alerts_to_send([level(percent=85.0)], [75, 90], ["five_hour"], above)
    assert messages == []

    messages, above = alerts_to_send([level(percent=91.0)], [75, 90], ["five_hour"], above)
    assert messages == ["Codex: 5-hour usage is at 91%."]
    assert sorted(above) == ["codex:five_hour@75", "codex:five_hour@90"]

    messages, above = alerts_to_send([level(percent=80.0)], [75, 90], ["five_hour"], above)
    assert messages == [] and above == ["codex:five_hour@75"]  # 90 can alert again


def test_jumping_past_several_thresholds_sends_one_alert():
    messages, above = alerts_to_send([level(percent=95.0)], [75, 90], ["five_hour"], [])

    assert messages == ["Codex: 5-hour usage is at 95%."]
    assert sorted(above) == ["codex:five_hour@75", "codex:five_hour@90"]


def test_migrate_alert_state_keeps_the_old_single_threshold():
    state = {"alert_threshold": 80, "alerts_above": ["codex:five_hour"]}

    migrate_alert_state(state)

    assert state == {"alert_thresholds": [80], "alerts_above": ["codex:five_hour@80"]}


def test_migrate_alert_state_defaults_and_leaves_new_state_alone():
    state = {}
    migrate_alert_state(state)
    assert state == {"alert_thresholds": [75], "alerts_above": []}

    state = {"alert_thresholds": [75, 90], "alerts_above": ["x@90"]}
    migrate_alert_state(state)
    assert state == {"alert_thresholds": [75, 90], "alerts_above": ["x@90"]}


def test_alerts_only_for_chosen_windows():
    messages, above = alerts_to_send([level(window="weekly")], [75], ["five_hour"], [])

    assert messages == [] and above == []


def test_alert_says_when_it_resets():
    today = datetime(2026, 11, 8, 15, 30).timestamp()
    later = datetime(2026, 11, 20, 18, 46).timestamp()

    messages, _ = alerts_to_send([level(resets_at=today)], [75], ["five_hour"], [], now=NOW)
    assert messages == ["Codex: 5-hour usage is at 80%. Resets at 3:30 PM."]

    messages, _ = alerts_to_send([level(resets_at=later)], [75], ["five_hour"], [], now=NOW)
    assert messages == ["Codex: 5-hour usage is at 80%. Resets on Nov 20."]


def codex_state(used=83.0, resets_at=NOW + 600):
    limits = {"at": "2026-11-08T11:00:00Z", "rate_limits": {
        "primary": {"used_percent": used, "window_minutes": 300, "resets_at": resets_at},
        "secondary": None}}
    return {"sources": {"codex": {"files": {"f": {"size": 1, "mtime": 1, "daily": {},
                                                  "limits": limits}}}}}


def test_plan_levels_for_codex_and_claude():
    from limits import plan_levels

    state = {**codex_state(), "claude_limit_hits": {"five_hour": NOW + 60}}

    levels = plan_levels(state, ["claude_code", "codex", "opencode"], NOW)

    assert [(l["id"], l["name"], l["percent"]) for l in levels] == [
        ("claude_code:five_hour", "Claude Code", 100.0),
        ("codex:five_hour", "Codex", 83.0),
    ]


def test_plan_levels_give_each_claude_limit_its_own_id():
    from limits import plan_levels

    usage = claude_usage()
    usage["limits"].append({"kind": "weekly_opus", "window": "weekly", "label": "Weekly · Opus",
                            "percent": 5.0, "resets_at": None})

    levels = plan_levels({"claude_usage": usage}, ["claude_code"], NOW)

    assert [l["id"] for l in levels] == [
        "claude_code:five_hour", "claude_code:weekly", "claude_code:weekly_opus"]


def test_limit_windows_are_only_the_ones_a_tool_has():
    free_codex = codex_state()
    free_codex["sources"]["codex"]["files"]["f"]["limits"]["rate_limits"]["primary"][
        "window_minutes"] = 43200

    assert limit_windows({}, ["claude_code"], NOW) == ["five_hour", "weekly"]
    assert limit_windows(free_codex, ["codex"], NOW) == ["monthly"]
    assert limit_windows(free_codex, ["claude_code", "codex"], NOW) == [
        "five_hour", "weekly", "monthly"]
    assert limit_windows({}, ["codex", "opencode"], NOW) == []


def test_levels_for_alerts_cover_the_enabled_tools_plan_limits():
    from limits import levels_for_alerts

    state = {**codex_state(), "enabled_tools": ["codex"]}

    levels = levels_for_alerts(state, NOW)

    assert [(l["id"], round(l["percent"])) for l in levels] == [("codex:five_hour", 83)]
