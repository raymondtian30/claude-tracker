from datetime import date, datetime

from stats_tabs import (
    TAG_LINE_CHARS,
    TAG_SPACE,
    _sessions_tab,
    build_panel as _build_panel,
    format_ago,
    tag_lines,
    leaderboard_enabled,
    tool_choices,
    welcome_tab,
    format_interval,
    format_long_date,
    format_short_date,
    model_display_name,
    percent,
    settings_tab,
)
from tools import tool_view
from usage_stats import add_usage, record_entry


def build_panel(state, sessions, friends, today=None, view=None, show_leaderboard=None):
    """Old call shape for these tests: Claude Code's view of `state`."""
    return _build_panel(
        view or tool_view(state, "claude_code"), state, sessions, friends,
        leaderboard_enabled(state) if show_leaderboard is None else show_leaderboard,
        today=today,
    )

ITEM_LENGTHS = {
    "tiles": 2, "chart": 3, "bar": 4, "row": 3, "note": 2, "buttons": 2,
    "segmented": 5, "popup": 5, "switch": 4, "alert": 3, "tags": 2, "choices": 5,
}


def entry(ts, model="claude-opus-5-5", cwd="/x/proj", **usage):
    return {
        "type": "assistant",
        "timestamp": ts,
        "cwd": cwd,
        "message": {"model": model, "usage": usage},
    }


def assert_well_formed(tab):
    assert {"key", "title", "short", "icon", "cards"} <= tab.keys()
    for card in tab["cards"]:
        assert card["items"], tab["key"]
        for item in card["items"]:
            assert len(item) == ITEM_LENGTHS[item[0]], item
            if item[0] == "bar":
                assert 0.0 <= item[3] <= 1.0


def alert_text(tab):
    """The warning at the top of a tab, as one string, or None."""
    first = tab["cards"][0]["items"] if tab["cards"] else []
    lines = [item[1] for item in first if item[0] == "alert"]
    return " ".join(lines) or None


def items_of(tab):
    return [item for card in tab["cards"] for item in card["items"]]


def test_formatters():
    assert model_display_name("claude-opus-5-5") == "Opus 5.5"
    assert model_display_name("claude-haiku-4-5-20251001") == "Haiku 4.5"
    assert model_display_name("<synthetic>") == "<synthetic>"
    assert percent(1, 1000) == "<1%"
    assert percent(50, 100) == "50%"
    assert percent(5, 0) == "0%"
    assert format_long_date("2026-11-03") == "November 3rd, 2026"
    assert format_short_date(date(2026, 11, 12)) == "Nov 12th"
    assert format_interval(15) == "15 seconds"
    assert format_interval(60) == "1 minute"


def test_build_panel_with_data():
    daily = {}
    record_entry(daily, entry("2026-07-29T12:00:00.000Z", input_tokens=10, output_tokens=5))
    state = {"grand_total": 115, "daily": daily, "leaderboard_view": "total",
             "leaderboard_enabled": True}
    sessions = [{"label": "~/proj", "tokens": 1500}]
    friends = [{"name": "Ann", "total_tokens": 200, "yesterday_tokens": 1},
               {"name": "Bo", "total_tokens": 100, "yesterday_tokens": 2}]

    tabs = build_panel(state, sessions, friends, today=date(2026, 7, 29))

    assert [t["key"] for t in tabs] == [
        "overview", "breakdown", "models", "projects", "cost", "limits", "sessions", "leaderboard",
    ]
    for tab in tabs:
        assert_well_formed(tab)
    tabs = {t["key"]: t for t in tabs}
    assert ("tiles", [("Today", "15", "sun.max"), ("Lifetime", "115", "infinity")]) in items_of(tabs["overview"])
    chart = next(i for i in items_of(tabs["overview"]) if i[0] == "chart")
    assert len(chart[1]) == 14 and chart[1][-1] == 15
    assert ("bar", "Older, no detail", "100 · 87%", 100 / 115) in items_of(tabs["breakdown"])
    assert ("bar", "Opus 5.5", "15 · 100%", 1.0) in items_of(tabs["models"])
    assert ("bar", "/x/proj", "15 · 100%", 1.0) in items_of(tabs["projects"])
    assert tabs["sessions"]["cards"][0]["title"] == "Sessions (1)"
    assert ("bar", "1. Ann", "200", 1.0) in items_of(tabs["leaderboard"])
    assert ("bar", "2. Bo", "100", 0.5) in items_of(tabs["leaderboard"])


def test_build_panel_with_no_data():
    tabs = {t["key"]: t for t in build_panel({"grand_total": 0, "leaderboard_enabled": True}, [], [],
                                             today=date(2026, 7, 29))}
    for tab in tabs.values():
        assert_well_formed(tab)
    assert ("note", "No Claude Code sessions running") in items_of(tabs["sessions"])
    assert ("note", "No friends added yet") in items_of(tabs["leaderboard"])
    buttons = [i for i in items_of(tabs["leaderboard"]) if i[0] == "buttons"]
    assert buttons[0][1][0][2] == "leaderboard_setup"


def test_leaderboard_buttons_after_setup():
    tabs = {t["key"]: t for t in build_panel({"grand_total": 0, "my_gist_id": "abc"}, [], [],
                                             today=date(2026, 7, 29))}
    actions = [b[2] for i in items_of(tabs["leaderboard"]) if i[0] == "buttons" for b in i[1]]
    assert actions == ["leaderboard_share", "leaderboard_push", "leaderboard_add", "leaderboard_pull"]


def test_settings_tab_reflects_state():
    tab = settings_tab(
        {"title_mode": "icon", "scan_interval_seconds": 60, "start_at_login": False},
        interval_choices=[5, 15, 30, 60, 300],
        detected=["claude_code"],
    )
    assert_well_formed(tab)
    items = items_of({**tab, "cards": [c for c in tab["cards"] if c["title"] not in ("AI tools", "AI providers")]})
    assert ("segmented", "Shows", ["Lifetime", "Today", "Icon only"], 2, "title_mode") in items
    assert next(i for i in items if i[-1] == "menu_bar_font_size") == ("popup", "Text size", ["10 pt", "11 pt", "12 pt", "13 pt", "14 pt"], 2,
                        "menu_bar_font_size")  # 12 pt by default
    assert next(i for i in items if i[-1] == "scan_interval")[3] == 3  # 60 seconds selected
    assert not [i for i in items if i[-1] == "pause"]
    assert ("switch", "Start at login", False, "login") in items


def test_leaderboard_tab_hidden_unless_enabled():
    def keys(state):
        return [t["key"] for t in build_panel(state, [], [], today=date(2026, 7, 29))]

    assert "leaderboard" not in keys({"grand_total": 0})
    assert "leaderboard" in keys({"grand_total": 0, "leaderboard_enabled": True})
    # Existing leaderboard users keep the tab by default.
    assert "leaderboard" in keys({"grand_total": 0, "my_gist_id": "abc"})
    assert "leaderboard" not in keys({"grand_total": 0, "my_gist_id": "abc", "leaderboard_enabled": False})


def test_settings_about_card_shows_version_and_credits():
    from version import __version__

    tab = settings_tab({}, interval_choices=[15], detected=["claude_code"])
    about = next(c for c in tab["cards"] if c["title"] == "About")
    assert ("row", "Version", __version__) in about["items"]
    assert ("row", "Original app by", "BrodyKretz") in about["items"]
    assert ("row", "Redesign & new features by", "Raymond Tian") in about["items"]


PARTS = {"input": 0, "output": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0}


def view_of(daily, name="Codex", key="codex", total=None, error=None):
    if total is None:
        total = sum(sum(p.values()) for b in daily.values() for p in b["models"].values())
    return {"key": key, "name": name, "daily": daily, "grand_total": total, "error": error}


def test_overview_shows_new_input_plus_output():
    daily = {}
    add_usage(daily, date(2026, 7, 29), "gpt-x", "~/p", {**PARTS, "input": 30, "output": 5, "cache_read": 900})

    tabs = {t["key"]: t for t in build_panel({}, [], [], today=date(2026, 7, 29), view=view_of(daily))}

    assert ("row", "New input + output", "35") in items_of(tabs["overview"])


def test_error_note_shown():
    tabs = {t["key"]: t for t in build_panel({}, [], [], today=date(2026, 7, 29),
                                             view=view_of({}, error="bad file"))}

    assert alert_text(tabs["overview"]) == "Codex data couldn't be read: bad file"


def test_cost_uses_recorded_cost():
    daily = {}
    add_usage(daily, date(2026, 7, 29), "gemini-4-argon", "~/p", {**PARTS, "input": 10}, cost=1.25)

    tabs = {t["key"]: t for t in build_panel({}, [], [], today=date(2026, 7, 29),
                                             view=view_of(daily, "opencode", "opencode"))}

    assert ("Today", "$1.25", "sun.max") in tabs["cost"]["cards"][0]["items"][0][1]


def test_sessions_empty_message_names_tool():
    tabs = {t["key"]: t for t in build_panel({}, [], [], today=date(2026, 7, 29), view=view_of({}))}

    assert ("note", "No Codex sessions running") in items_of(tabs["sessions"])


def test_sessions_without_token_counts_show_running():
    tabs = {t["key"]: t for t in build_panel({}, [{"label": "~/p", "tokens": None}], [],
                                             today=date(2026, 7, 29), view=view_of({}))}

    assert ("row", "~/p", "running") in items_of(tabs["sessions"])


def test_leaderboard_only_when_requested():
    state = {"grand_total": 0, "leaderboard_enabled": True}
    keys = [t["key"] for t in build_panel(state, [], [], today=date(2026, 7, 29), show_leaderboard=False)]
    assert "leaderboard" not in keys


def test_settings_lists_detected_tools_only():
    state = {"enabled_tools": ["claude_code"]}

    tab = settings_tab(state, interval_choices=[15], detected=["claude_code", "opencode"])

    tools_card = next(c for c in tab["cards"] if c["title"] == "AI tools")
    tools = [i for i in tools_card["items"] if i[-1].startswith("tool:")]
    assert tools == [
        ("switch", "Claude Code", True, "tool:claude_code"),
        ("switch", "opencode", False, "tool:opencode"),
    ]


def test_welcome_lists_detected_tools():
    tab = welcome_tab(["claude_code", "codex"], chosen=["codex"])

    assert tab["key"] == "welcome"
    items = items_of(tab)
    assert ("switch", "Claude Code", False, "welcome_tool:claude_code") in items
    assert ("switch", "Codex", True, "welcome_tool:codex") in items
    assert ("buttons", [("Continue", "arrow.right.circle", "welcome_done")]) in items


def test_welcome_with_no_tools_detected():
    items = items_of(welcome_tab([], chosen=[]))

    assert ("note", "No supported AI tools found on this Mac yet.") in items
    assert ("buttons", [("Continue", "arrow.right.circle", "welcome_done")]) in items


def test_tool_choices_are_enabled_tools_detected_or_with_history():
    state = {"enabled_tools": ["claude_code", "codex", "opencode"],
             "sources": {"opencode": {"daily": {"2026-07-29": {"models": {}, "projects": {}}}}}}

    assert tool_choices(state, detected=["claude_code"]) == [
        ("claude_code", "Claude Code"), ("opencode", "opencode"),
    ]


def test_settings_keeps_enabled_tool_whose_data_disappeared():
    state = {"enabled_tools": ["claude_code", "codex"]}

    tab = settings_tab(state, interval_choices=[15], detected=["claude_code"])

    tools_card = next(c for c in tab["cards"] if c["title"] == "AI tools")
    assert ("switch", "Codex", True, "tool:codex") in tools_card["items"]


def test_combined_cost_prices_each_tool_separately():
    from tools import combined_view

    claude_daily, opencode_daily = {}, {}
    add_usage(claude_daily, date(2026, 7, 29), "claude-opus-5-5", "~/p", {**PARTS, "input": 1_000_000})
    add_usage(opencode_daily, date(2026, 7, 29), "claude-opus-5-5", "~/p", {**PARTS, "input": 10}, cost=0.5)
    state = {"grand_total": 1_000_000, "daily": claude_daily,
             "sources": {"opencode": {"daily": opencode_daily}}}

    view = combined_view(state, ["claude_code", "opencode"])
    tabs = {t["key"]: t for t in build_panel(state, [], [], today=date(2026, 7, 29), view=view)}

    # Claude Code: 1M input at $4/M; opencode: its recorded $0.50.
    assert ("Today", "$4.50", "sun.max") in tabs["cost"]["cards"][0]["items"][0][1]


# --- providers ------------------------------------------------------------

def _provider_view(key="openai", name="OpenAI"):
    daily = {}
    add_usage(daily, date(2026, 11, 8), "gpt-5", "~/a", {"input": 5})
    return {"key": key, "name": name, "daily": daily, "grand_total": 5, "error": None,
            "views": []}


def _card(tabs, tab_key, title):
    tab = next(t for t in tabs if t["key"] == tab_key)
    return next(c for c in tab["cards"] if c["title"] == title)


def test_tool_choices_add_enabled_providers_after_tools():
    state = {"enabled_tools": ["claude_code"], "enabled_providers": ["kimi", "openai"]}

    assert tool_choices(state, detected=["claude_code"]) == [
        ("claude_code", "Claude Code"), ("openai", "OpenAI"), ("kimi", "Kimi"),
    ]


def test_provider_view_has_no_live_sessions_tab():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8), view=_provider_view())

    assert "sessions" not in [t["key"] for t in tabs]


def test_without_a_key_the_optional_account_card_sits_at_the_bottom():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8), view=_provider_view())

    cards = tabs[0]["cards"]
    assert cards[-1]["title"] == "Whole account (optional)"
    items = cards[-1]["items"]
    assert items[-1] == ("buttons", [("Add API Key", "key", "provider_key:openai")])
    assert not any(c["title"] == "OpenAI account" for c in cards)


def test_provider_account_card_with_fetched_numbers():
    account_daily = {}
    add_usage(account_daily, date(2026, 11, 8), "gpt-5", "Account", {"input": 1000})
    add_usage(account_daily, date(2026, 11, 1), "gpt-5", "Account", {"input": 2000})
    add_usage(account_daily, date(2026, 10, 15), "gpt-5", "Account", {"input": 4000})
    state = {"provider_keys": ["openai"], "accounts": {"openai": {
        "daily": account_daily, "cost": {"2026-11-08": 1.5, "2026-10-15": 2.0},
        "rows": [["Balance", "$3.00"]], "notes": ["Hello"], "error": "boom",
        "fetched_at": "2026-11-08T09:05:00", "attempted_at": "2026-11-08T09:20:00",
    }}}

    tabs = build_panel(state, [], [], today=date(2026, 11, 8), view=_provider_view())

    items = _card(tabs, "overview", "OpenAI account")["items"]
    assert ("row", "Today", "1.0K") in items
    assert ("row", "Last 7 days", "1.0K") in items
    assert ("row", "Last 30 days", "7.0K") in items
    assert ("row", "Billed, last 30 days", "$3.50") in items
    assert ("row", "Balance", "$3.00") in items
    notes = [i[1] for i in items if i[0] == "note"]
    assert "Hello" in notes
    assert not any("boom" in n for n in notes)  # shown as the warning instead
    assert alert_text(tabs[0]) == "Couldn't connect to OpenAI: boom"
    assert "Updated 9:05 AM" in notes
    assert items[-1] == ("buttons", [("Replace Key", "key", "provider_key:openai"),
                                     ("Remove Key", "trash", "provider_key_remove:openai")])


def test_provider_account_card_before_first_fetch():
    state = {"provider_keys": ["kimi"], "accounts": {}}

    tabs = build_panel(state, [], [], today=date(2026, 11, 8), view=_provider_view("kimi", "Kimi"))

    assert ("note", "Fetching account numbers…") in _card(tabs, "overview", "Kimi account")["items"]


def test_tool_views_have_no_account_card():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8))

    titles = [c["title"] for c in tabs[0]["cards"]]
    assert not any(t and t.endswith("account") for t in titles)


def test_settings_only_switches_providers_on_and_off():
    state = {"enabled_tools": [], "enabled_providers": ["openai", "kimi"],
             "provider_keys": ["kimi"]}

    tab = settings_tab(state, interval_choices=[15], detected=[])

    assert "AI providers" not in [c["title"] for c in tab["cards"]]
    items = next(c for c in tab["cards"] if c["title"] == "AI tools")["items"]
    assert ("switch", "OpenAI", True, "provider:openai") in items
    assert ("switch", "DeepSeek", False, "provider:deepseek") in items
    # Turning a provider on asks for nothing: no key buttons or notes here.
    assert all(i[0] == "switch" for i in items)


def test_long_notes_are_split_into_lines():
    from stats_tabs import note_lines
    text = "the API key was rejected (HTTP 401) and some more words to make it long"

    lines = note_lines(text)

    assert len(lines) > 1
    assert all(item[0] == "note" and len(item[1]) <= 46 for item in lines)
    assert " ".join(item[1] for item in lines) == text


def test_dropdown_offers_all_ais_first_once_two_tools_are_on():
    from stats_tabs import view_choices
    state = {"enabled_tools": ["claude_code", "opencode"], "enabled_providers": ["kimi"]}

    assert view_choices(state, ["claude_code", "opencode"]) == [
        ("all", "All AIs"), ("claude_code", "Claude Code"), ("opencode", "opencode"), ("kimi", "Kimi"),
    ]


def test_dropdown_has_no_all_ais_with_a_single_tool():
    from stats_tabs import view_choices
    state = {"enabled_tools": ["claude_code"], "enabled_providers": ["kimi"]}

    assert view_choices(state, ["claude_code"]) == tool_choices(state, ["claude_code"])


def test_settings_only_picks_which_ais_are_used():
    state = {"enabled_tools": ["claude_code"], "enabled_providers": ["kimi"]}

    tab = settings_tab(state, interval_choices=[15], detected=["claude_code", "codex"])

    items = next(c for c in tab["cards"] if c["title"] == "AI tools")["items"]
    switches = [i[1] for i in items if i[0] == "switch"]
    assert switches == ["Claude Code", "Codex", "OpenAI", "DeepSeek", "Kimi", "Google",
                        "Anthropic", "xAI", "Mistral", "Qwen", "Z.ai (GLM)", "MiniMax"]


# --- warnings when an AI's usage can't be seen ----------------------------

def _empty_provider(key, name):
    return {"key": key, "name": name, "daily": {}, "grand_total": 0, "error": None, "views": []}


def test_provider_with_no_usage_warns_on_every_tab():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8), view=_empty_provider("kimi", "Kimi"))

    for tab in tabs:
        assert_well_formed(tab)
        assert alert_text(tab).startswith("No Kimi usage found on this Mac."), tab["key"]
    assert tabs[0]["cards"][0]["items"][0][2] is True  # icon on the first line only
    assert "add an API key at the bottom of Home" in alert_text(tabs[0])


def test_deepseek_without_usage_explains_a_key_wont_show_it():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8),
                       view=_empty_provider("deepseek", "DeepSeek"))

    assert "doesn't share usage history" in alert_text(tabs[0])


def test_key_that_only_gives_a_balance_is_explained():
    state = {"provider_keys": ["kimi"], "accounts": {"kimi": {
        "daily": {}, "cost": {}, "rows": [["Balance", "$1.00"]], "notes": [], "error": None,
        "has_usage": False, "fetched_at": "2026-11-08T09:00:00"}}}

    tabs = build_panel(state, [], [], today=date(2026, 11, 8), view=_empty_provider("kimi", "Kimi"))

    assert "only shows your balance" in alert_text(tabs[0])


def test_account_connection_error_is_a_warning():
    state = {"provider_keys": ["openai"], "accounts": {"openai": {
        "daily": {}, "cost": {}, "rows": [], "notes": [], "error": "the API key was rejected (HTTP 401)",
        "fetched_at": None, "attempted_at": "2026-11-08T09:00:00"}}}

    tabs = build_panel(state, [], [], today=date(2026, 11, 8), view=_provider_view())

    assert alert_text(tabs[0]) == "Couldn't connect to OpenAI: the API key was rejected (HTTP 401)"
    assert alert_text(tabs[2]) == alert_text(tabs[0])


def test_no_warning_when_usage_is_visible():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8), view=_provider_view())

    assert all(alert_text(t) is None for t in tabs)


def test_no_warning_while_waiting_for_first_fetch():
    state = {"provider_keys": ["kimi"], "accounts": {}}

    tabs = build_panel(state, [], [], today=date(2026, 11, 8), view=_empty_provider("kimi", "Kimi"))

    assert alert_text(tabs[0]) is None


def test_settings_has_the_panel_animation_speed():
    tab = settings_tab({}, interval_choices=[15], detected=[])
    items = next(c for c in tab["cards"] if c["title"] == "Menu bar")["items"]

    assert ("popup", "Animation", ["Off", "Fast", "Normal", "Slow"], 2, "panel_animation") in items

    tab = settings_tab({"panel_animation": "off"}, interval_choices=[15], detected=[])
    items = next(c for c in tab["cards"] if c["title"] == "Menu bar")["items"]
    assert ("popup", "Animation", ["Off", "Fast", "Normal", "Slow"], 0, "panel_animation") in items


def test_providers_without_key_support_offer_no_key():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8), view=_empty_provider("google", "Google"))

    assert not any(c["title"] == "Whole account (optional)" for c in tabs[0]["cards"])
    warning = alert_text(tabs[0])
    assert warning == "No Google usage found on this Mac. None of your tools have used Google models yet."


def test_tool_with_no_usage_yet_warns():
    view = {"key": "gemini_cli", "name": "Gemini CLI", "daily": {}, "grand_total": 0, "error": None}

    tabs = build_panel({}, [], [], today=date(2026, 11, 8), view=view)

    assert alert_text(tabs[0]) == "No Gemini CLI usage found on this Mac yet."


# --- limits ---------------------------------------------------------------

LIMITS_NOW = datetime(2026, 11, 8, 12, 0, 0).timestamp()


def _limits_tab(state, view, now=LIMITS_NOW):
    tabs = _build_panel(view, state, [], [], False, today=date(2026, 11, 8), now=now)
    return next(t for t in tabs if t["key"] == "limits")


def _codex_limits_state(used):
    limits = {"at": "2026-11-08T11:00:00Z", "rate_limits": {
        "primary": {"used_percent": used, "window_minutes": 300,
                    "resets_at": datetime(2026, 11, 8, 15, 30).timestamp()},
        "secondary": None}}
    return {"sources": {"codex": {"files": {"f": {"size": 1, "mtime": 1, "daily": {},
                                                  "limits": limits}}}}}


def _projects_view(count):
    daily = {}
    for i in range(count):  # project 0 used the most
        add_usage(daily, date(2026, 11, 8), "m", f"/p/proj{i}", {"input": 1000 - i})
    return {"key": "opencode", "name": "opencode", "daily": daily, "grand_total": 1,
            "error": None}


def _projects_items(count, expanded=False):
    tabs = _build_panel(_projects_view(count), {}, [], [], False, today=date(2026, 11, 8),
                        projects_expanded=expanded)
    tab = next(t for t in tabs if t["key"] == "projects")
    return next(c for c in tab["cards"] if c["title"])["items"]


def test_projects_shows_the_top_5_then_a_show_more_button():
    items = _projects_items(8)

    assert [i[1] for i in items if i[0] == "bar"] == [f"/p/proj{i}" for i in range(5)]
    assert items[-1] == ("buttons", [("Show 3 more", "chevron.down", "projects_expand")])


def test_projects_show_more_lists_every_project():
    items = _projects_items(8, expanded=True)

    assert [i[1] for i in items if i[0] == "bar"] == [f"/p/proj{i}" for i in range(8)]
    assert items[-1] == ("buttons", [("Show less", "chevron.up", "projects_expand")])


def test_projects_without_more_than_5_has_no_button():
    items = _projects_items(5)

    assert len([i for i in items if i[0] == "bar"]) == 5
    assert not [i for i in items if i[0] == "buttons"]


def test_limits_tab_sits_after_cost():
    tabs = build_panel({}, [], [], today=date(2026, 11, 8))

    keys = [t["key"] for t in tabs]
    assert keys.index("limits") == keys.index("cost") + 1


def test_limits_tab_shows_codex_plan_limits():
    state = _codex_limits_state(83.0)

    tab = _limits_tab(state, tool_view(state, "codex"))

    plan = next(c for c in tab["cards"] if c["title"] == "Plan limits")
    assert plan["items"] == [("bar", "5-hour · resets 3:30 PM", "83%", 0.83)]


def test_limits_tab_shows_a_reached_claude_limit():
    state = {"claude_usage_enabled": False,
             "claude_limit_hits": {"five_hour": datetime(2026, 11, 8, 15, 30).timestamp()}}

    tab = _limits_tab(state, tool_view(state, "claude_code"))

    plan = next(c for c in tab["cards"] if c["title"] == "Plan limits")
    assert plan["items"][0] == ("bar", "5-hour · resets 3:30 PM", "Reached", 1.0)


def test_limits_tab_explains_claude_records_limits_only_when_reached():
    state = {"claude_usage_enabled": False}

    tab = _limits_tab(state, tool_view(state, "claude_code"))

    plan = next(c for c in tab["cards"] if c["title"] == "Plan limits")
    assert "only records a limit once it's reached" in " ".join(
        i[1] for i in plan["items"] if i[0] == "note")
    assert "Turn on Percentages from Anthropic in Settings" in " ".join(
        i[1] for i in plan["items"] if i[0] == "note")
    assert not [i for i in plan["items"] if i[0] == "switch"]


def _claude_usage_state(**usage):
    reset = datetime(2026, 11, 8, 15, 30).timestamp()
    limits = [{"kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 23.0,
               "resets_at": reset},
              {"kind": "weekly", "window": "weekly", "label": "Weekly", "percent": 41.4,
               "resets_at": None}]
    return {"claude_usage": {"limits": limits, "error": None, "fetched_at": 1, **usage}}


def test_limits_tab_shows_claudes_percentages():
    state = _claude_usage_state()

    tab = _limits_tab(state, tool_view(state, "claude_code"))

    plan = next(c for c in tab["cards"] if c["title"] == "Plan limits")["items"]
    assert plan[:2] == [("bar", "5-hour · resets 3:30 PM", "23%", 0.23),
                        ("bar", "Weekly", "41%", 0.414)]


def test_limits_tab_says_when_claudes_percentages_are_unavailable():
    state = _claude_usage_state(limits=[], error="Couldn't reach server. Percentage unavailable.")

    tab = _limits_tab(state, tool_view(state, "claude_code"))

    plan = next(c for c in tab["cards"] if c["title"] == "Plan limits")["items"]
    assert not [i for i in plan if i[0] == "bar"]
    assert "Couldn't reach server. Percentage unavailable." in " ".join(
        i[1] for i in plan if i[0] == "note")


def test_limits_tab_notifications_card_lists_only_the_windows_the_tool_has():
    claude = _limits_tab({}, tool_view({}, "claude_code"))
    free_codex = _codex_limits_state(88.0)
    free_codex["sources"]["codex"]["files"]["f"]["limits"]["rate_limits"]["primary"][
        "window_minutes"] = 43200
    codex = _limits_tab(free_codex, tool_view(free_codex, "codex"))

    def window_switches(tab):
        card = next(c for c in tab["cards"] if c["title"] == "Notifications")
        return [i[1] for i in card["items"] if i[0] == "switch" and i[3].startswith("alert_window")]

    assert window_switches(claude) == ["5-hour limit", "Weekly limit"]
    assert window_switches(codex) == ["Monthly limit"]


def test_limits_tab_notifications_card():
    tab = _limits_tab({}, tool_view({}, "claude_code"))

    items = next(c for c in tab["cards"] if c["title"] == "Notifications")["items"]
    assert ("switch", "Notify me", True, "alerts_enabled") in items
    assert ("choices", "When usage reaches", ["50%", "60%", "70%", "75%", "80%", "90%", "95%"], [3],
            "alert_thresholds") in items


def test_notifications_card_shows_every_chosen_threshold():
    tab = _limits_tab({"alert_thresholds": [75, 90]}, tool_view({}, "claude_code"))

    items = next(c for c in tab["cards"] if c["title"] == "Notifications")["items"]
    choices = next(i for i in items if i[0] == "choices")
    assert choices[3] == [3, 5]
    assert ("buttons", [("Send Test Alert", "bell", "alert_test")]) in items


def test_limits_tab_has_no_notifications_card_without_plan_limits():
    view = {"key": "opencode", "name": "opencode", "daily": {}, "grand_total": 0, "error": None}

    tab = _limits_tab({}, view)

    assert [c["title"] for c in tab["cards"] if c["title"]] == ["Plan limits"]


def test_settings_has_the_percentages_from_anthropic_switch_when_tracking_claude():
    def general(state):
        tab = settings_tab(state, interval_choices=[15], detected=[])
        return next(c for c in tab["cards"] if c["title"] == "General")["items"]

    on = general({"enabled_tools": ["claude_code"]})
    off = general({"enabled_tools": ["claude_code"], "claude_usage_enabled": False})

    assert ("switch", "Percentages from Anthropic", True, "claude_usage_enabled") in on
    assert ("switch", "Percentages from Anthropic", False, "claude_usage_enabled") in off
    assert not [i for i in general({"enabled_tools": ["codex"]})
                if i[-1] == "claude_usage_enabled"]


def test_settings_has_no_usage_alerts_card():
    tab = settings_tab({}, interval_choices=[15], detected=[])

    assert "Usage alerts" not in [c["title"] for c in tab["cards"]]


def test_limits_tab_gives_the_date_for_a_reset_after_today():
    state = _codex_limits_state(83.0)
    record = state["sources"]["codex"]["files"]["f"]["limits"]["rate_limits"]["primary"]
    record.update(window_minutes=43200, resets_at=datetime(2026, 11, 20, 18, 46).timestamp())

    tab = _limits_tab(state, tool_view(state, "codex"))

    plan = next(c for c in tab["cards"] if c["title"] == "Plan limits")
    assert plan["items"] == [("bar", "Monthly · resets Nov 20", "83%", 0.83)]


def test_settings_has_light_dark_auto_appearance():
    def appearance(state):
        tab = settings_tab(state, interval_choices=[15], detected=[])
        card = next(c for c in tab["cards"] if c["title"] == "Appearance")
        return card["items"][0]

    assert appearance({}) == ("segmented", "Mode", ["Auto", "Light", "Dark"], 0, "appearance")
    assert appearance({"appearance": "dark"})[3] == 2
    assert appearance({"appearance": "bogus"})[3] == 0


def test_live_tab_shows_plugin_tags_and_plugin_activity():
    sessions = [{"label": "~/proj", "tokens": 1500, "plugins": [("superpowers", True), ("caveman", False)]}]
    plugin_rows = [
        {"label": "superpowers", "sessions": 1, "latest": {"text": "Ran tdd skill", "at": 1000.0},
         "today": {"skill": 2, "hook": 1}},
        {"label": "caveman", "sessions": 0, "latest": None, "today": {}},
    ]

    tab = _sessions_tab(tool_view({}, "claude_code"), sessions, plugin_rows, now=1000.0 + 125)

    assert_well_formed(tab)
    sessions_card, plugins_card = tab["cards"]
    assert sessions_card["title"] == "Sessions (1)"
    assert sessions_card["items"] == [
        ("row", "~/proj", "1.5K"),
        ("tags", [("superpowers", True), ("caveman", False)]),
    ]
    assert plugins_card["title"] == "Plugins (2 enabled)"
    assert plugins_card["items"] == [
        ("row", "superpowers", "1 session"),
        ("note", "Ran tdd skill · 2 min ago"),
        ("note", "Today: 2 skills, 1 hook"),
        ("row", "caveman", "0 sessions"),
        ("note", "Enabled, not used yet"),
    ]


def test_live_tab_without_plugin_info_has_only_sessions():
    tab = _sessions_tab(tool_view({}, "codex"), [{"label": "~/g", "tokens": None}], None, now=0)

    assert [c["title"] for c in tab["cards"]] == ["Sessions (1)"]
    assert tab["cards"][0]["items"] == [("row", "~/g", "running")]


def test_live_tab_with_no_plugins_says_so():
    tab = _sessions_tab(tool_view({}, "claude_code"), [], [], now=0)

    assert tab["cards"][1] == {"title": "Plugins (0 enabled)", "items": [("note", "No plugins enabled")]}


def test_tag_lines_wrap_long_plugin_lists():
    tags = [(f"plugin-number-{i}", True) for i in range(6)]

    lines = tag_lines(tags)

    assert len(lines) > 1
    assert [t for line in lines for t in line] == tags
    assert all(sum(len(text) + TAG_SPACE for text, _ in line) <= TAG_LINE_CHARS for line in lines)


def test_format_ago():
    assert format_ago(100, 130) == "just now"
    assert format_ago(0, 5 * 60) == "5 min ago"
    assert format_ago(0, 3 * 3600) == "3 hr ago"
    assert format_ago(0, 86400) == "1 day ago"
    assert format_ago(0, 3 * 86400) == "3 days ago"
