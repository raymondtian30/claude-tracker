from datetime import date, datetime

from limits import (
    BUDGET_CHOICES,
    alerts_to_send,
    budget_tokens_used,
    claude_limits,
    codex_limits,
    window_for_minutes,
)
from usage_stats import add_usage

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

    assert claude_limits(hits, NOW) == [
        {"window": "five_hour", "label": "5-hour", "percent": 100.0, "resets_at": NOW + 3600},
    ]


def test_budget_tokens_used_per_window():
    daily = {}
    add_usage(daily, date(2026, 11, 8), "m", "p", {"input": 100})
    add_usage(daily, date(2026, 11, 2), "m", "p", {"input": 20})   # 7th day back
    add_usage(daily, date(2026, 11, 1), "m", "p", {"input": 3})    # outside the week, in the month
    add_usage(daily, date(2026, 10, 31), "m", "p", {"input": 5000})  # last month
    recent = [[NOW - 4 * 3600, 7], [NOW - 6 * 3600, 900]]

    assert budget_tokens_used("weekly", daily, recent, NOW) == 120
    assert budget_tokens_used("monthly", daily, recent, NOW) == 123
    assert budget_tokens_used("five_hour", daily, recent, NOW) == 7


def test_budget_choices_start_with_off():
    assert BUDGET_CHOICES[0] == 0
    assert BUDGET_CHOICES == sorted(BUDGET_CHOICES)


def level(id="codex:five_hour", window="five_hour", percent=80.0, resets_at=None):
    return {"id": id, "name": "Codex", "window": window, "label": "5-hour", "percent": percent,
            "resets_at": resets_at}


def test_alert_once_when_crossing_the_threshold():
    messages, above = alerts_to_send([level()], 75, ["five_hour"], [])

    assert messages == ["Codex: 5-hour usage is at 80%."]
    assert above == ["codex:five_hour"]

    messages, above = alerts_to_send([level(percent=90.0)], 75, ["five_hour"], above)
    assert messages == []  # already told

    messages, above = alerts_to_send([level(percent=10.0)], 75, ["five_hour"], above)
    assert above == []  # dropped below (e.g. the window reset): ready to alert again


def test_alerts_only_for_chosen_windows():
    messages, above = alerts_to_send([level(window="weekly")], 75, ["five_hour"], [])

    assert messages == [] and above == []


def test_alert_says_when_it_resets():
    today = datetime(2026, 11, 8, 15, 30).timestamp()
    later = datetime(2026, 11, 20, 18, 46).timestamp()

    messages, _ = alerts_to_send([level(resets_at=today)], 75, ["five_hour"], [], now=NOW)
    assert messages == ["Codex: 5-hour usage is at 80%. Resets at 3:30 PM."]

    messages, _ = alerts_to_send([level(resets_at=later)], 75, ["five_hour"], [], now=NOW)
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


def test_budget_windows_and_levels():
    from limits import budget_levels, budget_windows

    assert budget_windows("claude_code") == ["five_hour", "weekly", "monthly"]
    assert budget_windows("opencode") == ["weekly", "monthly"]

    daily = {}
    add_usage(daily, date(2026, 11, 8), "m", "p", {"input": 30_000_000})
    view = {"key": "opencode", "name": "opencode", "daily": daily}
    state = {"budgets": {"opencode": {"weekly": 40_000_000}}}

    assert budget_levels(view, state, NOW) == [{
        "id": "budget:opencode:weekly", "name": "opencode", "window": "weekly",
        "label": "Weekly budget", "budget": 40_000_000, "used": 30_000_000, "percent": 75.0,
        "resets_at": None,
    }]


def test_levels_for_alerts_cover_plan_limits_and_every_budget():
    from limits import levels_for_alerts

    daily = {}
    add_usage(daily, date(2026, 11, 8), "m", "p", {"input": 80})
    state = {**codex_state(), "enabled_tools": ["codex"],
             "budgets": {"all": {"weekly": 100}, "kimi": {"monthly": 0}}}
    views = {"all": {"key": "all", "name": "All AIs", "daily": daily},
             "kimi": {"key": "kimi", "name": "Kimi", "daily": {}}}

    levels = levels_for_alerts(state, views.__getitem__, NOW)

    assert [(l["id"], round(l["percent"])) for l in levels] == [
        ("codex:five_hour", 83), ("budget:all:weekly", 80),
    ]
