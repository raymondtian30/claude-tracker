"""Usage limits: each tool's real plan limits, and when to send an alert
about them.

- Codex saves its plan's limits in its session logs (percent used, window
  length, reset time), so those are exact. Which windows it has depends on
  the plan: the free plan has one 30-day window, paid plans a 5-hour and a
  weekly one.
- Claude Code's percentages (5-hour and weekly) come from Anthropic (see
  claude_usage.py). Without them, its logs still say when a limit was
  reached, which shows as 100% until the reset.

Kept free of AppKit so it can be unit-tested.
"""

from datetime import datetime

WINDOWS = [("five_hour", "5-hour"), ("weekly", "Weekly"), ("monthly", "Monthly")]
WINDOW_LABELS = dict(WINDOWS)
# Claude Code's plans have a 5-hour and a weekly limit.
CLAUDE_WINDOWS = ["five_hour", "weekly"]

ALERT_THRESHOLDS = [50, 60, 70, 75, 80, 90, 95]
DEFAULT_ALERT_THRESHOLD = 75

# Claude Code's names for its limits -> the app's windows.
CLAUDE_LIMIT_TYPES = {"five_hour": "five_hour", "seven_day": "weekly",
                      "seven_day_opus": "weekly", "seven_day_sonnet": "weekly"}


def window_for_minutes(minutes):
    if minutes <= 12 * 60:
        return "five_hour"
    if minutes <= 14 * 24 * 60:
        return "weekly"
    return "monthly"


def codex_limits(rate_limits, now):
    """Codex's limits from its latest `rate_limits` record. A window whose
    reset time has passed reads 0% until Codex records a new one."""
    limits = []
    for slot in ("primary", "secondary"):
        info = (rate_limits or {}).get(slot)
        if not info or info.get("window_minutes") is None:
            continue
        window = window_for_minutes(info["window_minutes"])
        resets_at = info.get("resets_at")
        reset = resets_at is not None and resets_at <= now
        limits.append({
            "window": window,
            "label": WINDOW_LABELS[window],
            "percent": 0.0 if reset else float(info.get("used_percent") or 0.0),
            "resets_at": None if reset else resets_at,
        })
    return limits


def reached_claude_limits(hits, now):
    """Claude Code's reached limits ({limit type: reset time}) that haven't
    reset yet, at 100%."""
    limits = []
    for kind, resets_at in sorted((hits or {}).items()):
        window = CLAUDE_LIMIT_TYPES.get(kind, "five_hour")
        if resets_at and resets_at > now:
            limits.append({"window": window, "label": WINDOW_LABELS[window], "percent": 100.0,
                           "resets_at": resets_at, "reached": True})
    return limits


def claude_limits(state, now):
    """Claude Code's limits: Anthropic's percentages if the last fetch
    worked, else the reached limits from its logs. A limit whose reset time
    has passed reads 0% until the next fetch."""
    usage = state.get("claude_usage") or {}
    if state.get("claude_usage_enabled", True) and usage.get("limits"):
        limits = []
        for limit in usage["limits"]:
            reset = limit.get("resets_at") is not None and limit["resets_at"] <= now
            limits.append({**limit, "percent": 0.0 if reset else limit["percent"],
                           "resets_at": None if reset else limit.get("resets_at")})
        return limits
    return reached_claude_limits(state.get("claude_limit_hits"), now)


def format_reset(resets_at, now):
    """'3:30 PM' for a reset later today, 'Nov 20' for a later day."""
    reset = datetime.fromtimestamp(resets_at)
    if reset.date() == datetime.fromtimestamp(now).date():
        return reset.strftime("%-I:%M %p")
    return reset.strftime("%b %-d")


def alerts_to_send(levels, thresholds, windows_on, above, now=None):
    """Which alerts to send now. `levels` are {"id", "name", "window",
    "label", "percent", "resets_at"}; `thresholds` are the percents to alert
    at; `above` lists "id@threshold" keys already alerted and still over that
    threshold. Returns (messages, new `above`). A level alerts once when it
    reaches each threshold, and again only after it has dropped back below it
    (e.g. when its window resets). Passing several thresholds at once (75 and
    90 on the way to 95) sends one alert, not one per threshold."""
    messages = []
    new_above = []
    for level in levels:
        if level["window"] not in windows_on:
            continue
        keys = [f"{level['id']}@{t}" for t in sorted(thresholds) if level["percent"] >= t]
        new_above += keys
        if all(key in above for key in keys):
            continue
        message = f"{level['name']}: {level['label']} usage is at {level['percent']:.0f}%."
        if level.get("resets_at"):
            now = now if now is not None else datetime.now().timestamp()
            when = format_reset(level["resets_at"], now)
            message += f" Resets {'at' if when[0].isdigit() else 'on'} {when}."
        messages.append(message)
    return messages, new_above


def migrate_alert_state(state):
    """Before several thresholds could be picked, state had one
    "alert_threshold" and alerted ids without "@threshold": carry both over."""
    if "alert_thresholds" not in state:
        old = state.pop("alert_threshold", DEFAULT_ALERT_THRESHOLD)
        state["alert_thresholds"] = [old]
        state["alerts_above"] = [key if "@" in key else f"{key}@{old}"
                                 for key in state.get("alerts_above", [])]
    state.setdefault("alerts_above", [])


def plan_levels(state, tool_keys, now):
    """The real plan limits recorded for `tool_keys`, as alert levels
    {"id", "name", "window", "label", "percent", "resets_at"}."""
    from codex_source import codex_rate_limits
    from tools import TOOL_NAMES

    levels = []
    for key in tool_keys:
        if key == "claude_code":
            found = claude_limits(state, now)
        elif key == "codex":
            found = codex_limits(codex_rate_limits(state.get("sources", {}).get("codex", {})), now)
        else:
            continue
        levels += [{"id": f"{key}:{limit.get('kind', limit['window'])}",
                    "name": TOOL_NAMES[key], **limit}
                   for limit in found]
    return levels


def limit_windows(state, tool_keys, now):
    """The windows `tool_keys` have limits in, in WINDOWS order: Claude
    Code's two, plus whichever Codex has recorded."""
    windows = {level["window"] for level in plan_levels(state, tool_keys, now)}
    if "claude_code" in tool_keys:
        windows |= set(CLAUDE_WINDOWS)
    return [window for window, _ in WINDOWS if window in windows]


def levels_for_alerts(state, now):
    """Everything an alert can be about: the plan limits of the enabled tools."""
    return plan_levels(state, state.get("enabled_tools", []), now)
