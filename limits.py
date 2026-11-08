"""Usage limits: the real plan limits tools record on this Mac, budgets the
user sets, and when to send an alert about either.

- Codex saves its plan's limits in its session logs (percent used, window
  length, reset time), so those are exact.
- Claude Code only logs a limit when it's reached (with its reset time), so
  that shows as 100% until the reset.
- Budgets are token amounts the user picks per window; their percent comes
  from the app's own counts.

Kept free of AppKit so it can be unit-tested.
"""

from datetime import datetime, timedelta

from usage_stats import total_in_range

WINDOWS = [("five_hour", "5-hour"), ("weekly", "Weekly"), ("monthly", "Monthly")]
WINDOW_LABELS = dict(WINDOWS)
FIVE_HOURS = 5 * 3600

# Budget amounts offered in the Limits tab (tokens; 0 = off).
BUDGET_CHOICES = [0, 1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000,
                  250_000_000, 500_000_000, 1_000_000_000, 2_500_000_000, 5_000_000_000,
                  10_000_000_000]

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


def claude_limits(hits, now):
    """Claude Code's reached limits ({limit type: reset time}) that haven't
    reset yet, at 100%."""
    limits = []
    for kind, resets_at in sorted((hits or {}).items()):
        window = CLAUDE_LIMIT_TYPES.get(kind, "five_hour")
        if resets_at and resets_at > now:
            limits.append({"window": window, "label": WINDOW_LABELS[window], "percent": 100.0,
                           "resets_at": resets_at})
    return limits


def budget_tokens_used(window, daily, recent, now):
    """Tokens counted against a budget: the last 5 hours (from `recent`, a
    list of [unix time, tokens]), the last 7 days, or this calendar month."""
    if window == "five_hour":
        return sum(tokens for at, tokens in recent or [] if at >= now - FIVE_HOURS)
    today = datetime.fromtimestamp(now).date()
    start = today - timedelta(days=6) if window == "weekly" else today.replace(day=1)
    return total_in_range(daily, start, today)


def format_reset(resets_at, now):
    """'3:30 PM' for a reset later today, 'Nov 20' for a later day."""
    reset = datetime.fromtimestamp(resets_at)
    if reset.date() == datetime.fromtimestamp(now).date():
        return reset.strftime("%-I:%M %p")
    return reset.strftime("%b %-d")


def alerts_to_send(levels, threshold, windows_on, above, now=None):
    """Which alerts to send now. `levels` are {"id", "name", "window",
    "label", "percent", "resets_at"}; `above` lists the ids already alerted
    and still over the threshold. Returns (messages, new `above`). A level
    alerts once when it reaches the threshold, and again only after it has
    dropped back below it (e.g. when its window resets)."""
    messages = []
    new_above = []
    for level in levels:
        if level["window"] not in windows_on or level["percent"] < threshold:
            continue
        new_above.append(level["id"])
        if level["id"] in above:
            continue
        message = f"{level['name']}: {level['label']} usage is at {level['percent']:.0f}%."
        if level.get("resets_at"):
            now = now if now is not None else datetime.now().timestamp()
            when = format_reset(level["resets_at"], now)
            message += f" Resets {'at' if when[0].isdigit() else 'on'} {when}."
        messages.append(message)
    return messages, new_above


def plan_levels(state, tool_keys, now):
    """The real plan limits recorded for `tool_keys`, as alert levels
    {"id", "name", "window", "label", "percent", "resets_at"}."""
    from codex_source import codex_rate_limits
    from tools import TOOL_NAMES

    levels = []
    for key in tool_keys:
        if key == "claude_code":
            found = claude_limits(state.get("claude_limit_hits"), now)
        elif key == "codex":
            found = codex_limits(codex_rate_limits(state.get("sources", {}).get("codex", {})), now)
        else:
            continue
        levels += [{"id": f"{key}:{limit['window']}", "name": TOOL_NAMES[key], **limit}
                   for limit in found]
    return levels


def budget_windows(view_key):
    """Windows a budget can be set for. Only Claude Code's replies are kept
    with exact times, which a 5-hour window needs."""
    if view_key == "claude_code":
        return ["five_hour", "weekly", "monthly"]
    return ["weekly", "monthly"]


def budget_levels(view, state, now):
    """The budgets set for `view`, as alert levels with "budget" and "used"."""
    budgets = state.get("budgets", {}).get(view["key"], {})
    recent = state.get("claude_recent", []) if view["key"] == "claude_code" else []
    levels = []
    for window in budget_windows(view["key"]):
        budget = budgets.get(window)
        if not budget:
            continue
        used = budget_tokens_used(window, view["daily"], recent, now)
        levels.append({
            "id": f"budget:{view['key']}:{window}", "name": view["name"], "window": window,
            "label": f"{WINDOW_LABELS[window]} budget", "budget": budget, "used": used,
            "percent": used / budget * 100, "resets_at": None,
        })
    return levels


def levels_for_alerts(state, view_for, now):
    """Everything an alert can be about: the plan limits of the enabled
    tools, then each view's budgets. `view_for(key)` builds a view."""
    levels = plan_levels(state, state.get("enabled_tools", []), now)
    for key, budgets in state.get("budgets", {}).items():
        if any(budgets.values()):
            levels += budget_levels(view_for(key), state, now)
    return levels
