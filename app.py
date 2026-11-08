import os
import subprocess
import sys
import threading
import time
import urllib.error
import webbrowser
from datetime import date, datetime, timedelta
from pathlib import Path

import rumps
from PyObjCTools import AppHelper
from AppKit import (
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSAttributedString,
    NSFont,
    NSFontAttributeName,
    NSImageLeft,
)

from accounts import KEY_HELP, account_due, delete_key, fetch_account, load_key, save_key, store_result
from active_sessions import active_sessions, running_tool_sessions
from claude_usage import fetch_usage, usage_due
from gist_sync import (
    NEW_TOKEN_URL,
    create_gist,
    fetch_gist,
    get_github_token,
    set_github_token,
    update_gist,
)
from leaderboard import load_friends, save_friends, sorted_friends
from notifications import SETTINGS_URL, Notifier
from panel_speeds import (
    ANIMATION_SPEEDS,
    APPEARANCES,
    DEFAULT_ANIMATION,
    DEFAULT_APPEARANCE,
    animation_seconds,
)
from plugins import live_plugins
from panel_view import Panel, SettingsWindow, apply_appearance, confirm_with_details
from single_instance import acquire_lock, observe_show_requests, request_show_panel
from stats_tabs import (
    DEFAULT_MENU_BAR_FONT_SIZE,
    LEADERBOARD_VIEWS,
    MENU_BAR_FONT_SIZES,
    TITLE_MODES,
    build_panel,
    format_long_date,
    leaderboard_enabled,
    settings_tab,
    view_choices,
    welcome_tab,
)
from limits import (
    ALERT_THRESHOLDS,
    WINDOWS,
    alerts_to_send,
    levels_for_alerts,
    migrate_alert_state,
)
from updater import (
    UpdateError,
    describe_releases,
    install_release,
    newer_releases,
    rebuild_bundle,
    restart_command,
)
from token_math import (
    backfill_daily,
    backfill_limits,
    format_count,
    load_state,
    save_state,
    sum_usage_for_today,
)
from tool_icons import icon_image, menu_bar_image
from providers import PROVIDER_NAMES, PROVIDERS, provider_view, tools_to_scan
from tools import TOOLS, combined_view, detect_tools, scan_tools, tool_view
from usage_stats import total_in_range
from version import APP_NAME, REPO_URL, __version__

STATE_FILE = Path(__file__).resolve().parent / "state.json"
LOCK_FILE = Path(__file__).resolve().parent / ".claude-tracker.lock"
REFRESH_SECONDS = 15
HEADER_ICON_SIZE = 28
SCAN_INTERVAL_CHOICES = [5, 15, 30, 60, 300]
LABEL = "com.claudetokencounter.menubar"


def init_tool_state(state, fresh_install):
    """Add the multi-tool settings to `state` without touching anything
    already there. Existing installs keep tracking just Claude Code and skip
    the welcome picker; fresh installs track nothing until a tool is chosen."""
    state.setdefault("enabled_tools", [] if fresh_install else ["claude_code"])
    # "Combine all tools" used to be a Settings switch; it's now "All AIs" in
    # the panel's dropdown, so someone who had it on lands there.
    if state.pop("combine_tools", False):
        state["selected_tool"] = "all"
    state.setdefault(
        "selected_tool", state["enabled_tools"][0] if state["enabled_tools"] else "claude_code"
    )
    state.setdefault("onboarding_done", not fresh_install)


def init_provider_state(state):
    """Provider tracking starts off; nothing already in `state` changes."""
    state.setdefault("enabled_providers", [])
    state.setdefault("provider_keys", [])  # which providers have a key in the Keychain


def menu_bar_label(view_key, count_text, has_icon):
    """(text, show_icon) for the menu bar. A single tool shows its own icon
    when one was found; the combined view (or a missing icon) shows the coin.
    `count_text` is None in icon-only mode."""
    use_icon = view_key != "all" and has_icon
    if use_icon:
        return (f" {count_text}" if count_text else ""), True
    return (f"🪙 {count_text}" if count_text else "🪙"), False


def _service_target():
    return f"gui/{os.getuid()}/{LABEL}"


def set_start_at_login(enabled):
    """Enable/disable this LaunchAgent starting at login via launchctl overrides.

    Does not touch the currently running process -- only affects whether
    launchd starts it again on the next login.
    """
    action = "enable" if enabled else "disable"
    subprocess.run(
        ["launchctl", action, _service_target()],
        check=True,
        capture_output=True,
        text=True,
    )


class TokenCounterApp(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, quit_button=None)
        fresh_install = not STATE_FILE.exists()
        self.state = load_state(STATE_FILE)
        init_tool_state(self.state, fresh_install)
        init_provider_state(self.state)
        self._fetching = set()  # providers with an account fetch in flight
        self._fetching_claude = False
        self.update_status = None  # shown in Settings > About while checking
        self.projects_expanded = False  # the Projects tab's "Show more"
        self.notifier = Notifier(APP_NAME, fallback=_fallback_notification)
        self.notifier.request_permission()
        self._fetched = []  # (provider, result) waiting to be saved on the main thread
        self.welcome_choice = []
        self.state.setdefault("first_seen_at", None)
        self.state.setdefault("start_at_login", True)
        self.state.setdefault("scan_interval_seconds", REFRESH_SECONDS)
        self.state.setdefault("leaderboard_view", "total")
        self.state.setdefault("my_gist_id", None)
        self.state.setdefault("leaderboard_name", None)
        self.state.setdefault("last_leaderboard_sync_date", None)
        self.state.setdefault("title_mode", "lifetime")
        self.state.setdefault("menu_bar_font_size", DEFAULT_MENU_BAR_FONT_SIZE)
        self.state.setdefault("panel_animation", DEFAULT_ANIMATION)
        self.state.setdefault("appearance", DEFAULT_APPEARANCE)
        apply_appearance(self.state["appearance"])
        self.state.setdefault("alerts_enabled", True)
        migrate_alert_state(self.state)
        self.state.setdefault("alert_windows", [w for w, _ in WINDOWS])
        self.state.setdefault("claude_usage_enabled", True)
        self.state.pop("budgets", None)  # token budgets, since removed
        self.state.pop("stats_tab", None)  # from the earlier in-menu tabs
        self.state.pop("panel_tab", None)  # the panel always opens on Home now
        if self.state["first_seen_at"] is None:
            self.state["first_seen_at"] = date.today().isoformat()
        # Backfill must run before the first refresh: it re-reads each file
        # only up to the offsets saved by the previous run.
        backfill_daily(self.state)
        backfill_limits(self.state)
        self._scan()
        save_state(self.state, STATE_FILE)
        self._fetch_accounts()
        self._fetch_claude_usage()
        if self.state.pop("updated_to", None):
            save_state(self.state, STATE_FILE)
            self.notifier.send(f"Updated to {__version__}. Your settings are unchanged.")

        self.panel = Panel(on_action=self.handle_action)
        self.panel.animation_seconds = animation_seconds(self.state["panel_animation"])
        self.settings_window = SettingsWindow(on_action=self.handle_action)
        self._render_panel()
        self._update_title()
        # rumps creates the status item inside run(); swap its menu for the
        # panel once it exists.
        rumps.events.before_start.register(self._attach_panel)

        self.timer = rumps.Timer(self.refresh, self.state["scan_interval_seconds"])
        self.timer.start()

    def _attach_panel(self):
        self.panel.attach(self._nsapp.nsstatusitem)
        # Opening the app again (e.g. from Finder) asks this copy to show its panel.
        self._show_observer = observe_show_requests(self.panel.show)
        self._update_title()
        if not self.state["onboarding_done"]:
            self.panel.show()  # first run: ask which tools to track

    def _scan(self, detected=None):
        scan_tools(self.state, tools_to_scan(self.state, detected or detect_tools()))

    def _current_view(self, detected=None):
        """The view the panel and menu bar show: the selected tool or
        provider, or every enabled tool combined."""
        enabled = self.state["enabled_tools"]
        choices = [key for key, _ in view_choices(self.state, detected or detect_tools())]
        if not choices:
            return combined_view(self.state, enabled)
        selected = self.state["selected_tool"]
        # Fall back to the first tool, not "All AIs", as before it existed.
        key = selected if selected in choices else next(k for k in choices if k != "all")
        if key == "all":
            return combined_view(self.state, enabled)
        if key in PROVIDER_NAMES:
            return provider_view(self.state, key)
        return tool_view(self.state, key)

    def _sessions_for(self, view):
        if view["key"] in PROVIDER_NAMES:
            return []
        keys = [view["key"]] if view["key"] != "all" else self.state["enabled_tools"]
        sessions = []
        for key in keys:
            sessions += active_sessions() if key == "claude_code" else running_tool_sessions(key)
        return sessions

    def _plugins_for(self, view, sessions):
        """Plugin rows for the Live tab (tagging `sessions` with the plugins
        each runs), or None where plugins don't apply: only Claude Code has
        them."""
        if view["key"] == "claude_code" or (
            view["key"] == "all" and "claude_code" in self.state["enabled_tools"]
        ):
            return live_plugins(sessions)
        return None

    def _update_title(self):
        view = self._current_view()
        mode = self.state["title_mode"]
        if mode == "today":
            today = date.today()
            count = format_count(total_in_range(view["daily"], today, today))
        elif mode == "icon":
            count = None
        else:
            count = format_count(view["grand_total"])
        image = menu_bar_image(view["key"]) if view["key"] != "all" else None
        title, show_icon = menu_bar_label(view["key"], count, image is not None)
        self.title = title
        # Redraw it at the size picked in Settings, with even-width digits so
        # the item doesn't jiggle as the count changes.
        status_item = getattr(getattr(self, "_nsapp", None), "nsstatusitem", None)
        if status_item is not None:
            font = NSFont.monospacedDigitSystemFontOfSize_weight_(
                self.state["menu_bar_font_size"], 0.0
            )
            button = status_item.button()
            button.setAttributedTitle_(
                NSAttributedString.alloc().initWithString_attributes_(
                    title, {NSFontAttributeName: font}
                )
            )
            button.setImage_(image if show_icon else None)
            button.setImagePosition_(NSImageLeft)

    def _render_panel(self):
        detected = detect_tools()
        view = self._current_view(detected)
        choices = view_choices(self.state, detected)
        friends = sorted_friends(load_friends(), by=self.state["leaderboard_view"])
        sessions = self._sessions_for(view)
        self.panel.render(
            build_panel(
                view, self.state, sessions, friends,
                leaderboard_enabled(self.state) and view["key"] == "claude_code",
                projects_expanded=self.projects_expanded,
                plugins=self._plugins_for(view, sessions),
            ),
            f"Tracking since {format_long_date(self.state['first_seen_at'])}",
            tool_choices=choices,
            selected_tool=view["key"],
            welcome=None if self.state["onboarding_done"]
            else welcome_tab(detected, self.welcome_choice),
            subtitle="All AIs" if view["key"] == "all" else f"for {view['name']}",
            # Same rule as the menu bar: the AI's logo, the coin when combined.
            logo=icon_image(view["key"], HEADER_ICON_SIZE) if view["key"] != "all" else None,
        )
        self.settings_window.render(
            settings_tab(self.state, SCAN_INTERVAL_CHOICES, detected,
                         update_status=self.update_status)
        )

    def handle_action(self, action, value):
        """Called by the panel when a button, switch or picker is used."""
        dialogs = {
            "leaderboard_setup": self.start_leaderboard_setup,
            "leaderboard_share": self.share_friend_code,
            "leaderboard_add": self.add_friend_by_code,
        }
        provider_dialogs = {
            "provider_key": self.add_api_key,
            "provider_key_remove": self.remove_api_key,
        }
        name, _, argument = action.partition(":")
        if action == "quit":
            rumps.quit_application()
            return
        if action == "open_settings":
            self.panel.close()
            self.settings_window.show()
        elif action in dialogs:
            # Dialogs can't sit on top of the popover, so close it first.
            self.panel.close()
            dialogs[action]()
        elif name in provider_dialogs and argument in KEY_HELP:
            self.panel.close()
            provider_dialogs[name](argument)
        elif name == "provider" and argument in PROVIDER_NAMES:
            self.set_provider_enabled(argument, value)
        elif action == "leaderboard_push":
            self.push_leaderboard_update()
        elif action == "leaderboard_pull":
            self.pull_leaderboard_updates()
        elif action == "leaderboard_view":
            self.state["leaderboard_view"] = LEADERBOARD_VIEWS[value][0]
            save_state(self.state, STATE_FILE)
        elif action == "title_mode":
            self.state["title_mode"] = TITLE_MODES[value][0]
            save_state(self.state, STATE_FILE)
            self._update_title()
        elif action == "menu_bar_font_size":
            self.state["menu_bar_font_size"] = MENU_BAR_FONT_SIZES[value]
            save_state(self.state, STATE_FILE)
            self._update_title()
        elif action == "appearance":
            self.state["appearance"] = APPEARANCES[value][0]
            apply_appearance(self.state["appearance"])
            save_state(self.state, STATE_FILE)
        elif action == "panel_animation":
            self.state["panel_animation"] = ANIMATION_SPEEDS[value][0]
            self.panel.animation_seconds = animation_seconds(self.state["panel_animation"])
            save_state(self.state, STATE_FILE)
        elif action == "alerts_enabled":
            self.state["alerts_enabled"] = value
            save_state(self.state, STATE_FILE)
        elif action == "alert_thresholds":
            # Keep at least one: "Notify me" is the way to turn alerts off.
            if value:
                self.state["alert_thresholds"] = [ALERT_THRESHOLDS[i] for i in value]
                save_state(self.state, STATE_FILE)
        elif name == "alert_window":
            windows = set(self.state["alert_windows"]) - {argument} | ({argument} if value else set())
            self.state["alert_windows"] = [w for w, _ in WINDOWS if w in windows]
            save_state(self.state, STATE_FILE)
        elif action == "alert_test":
            self.send_test_alert()
        elif action == "claude_usage_enabled":
            self.state["claude_usage_enabled"] = value
            if not value:
                self.state.pop("claude_usage", None)
            save_state(self.state, STATE_FILE)
            self._fetch_claude_usage()
        elif action == "scan_interval":
            self.set_scan_interval(SCAN_INTERVAL_CHOICES[value])
        elif action == "login":
            self.set_start_at_login(value)
        elif action == "leaderboard_enabled":
            self.state["leaderboard_enabled"] = value
            save_state(self.state, STATE_FILE)
        elif action == "projects_expand":
            self.projects_expanded = not self.projects_expanded
        elif action == "check_updates":
            self.check_for_updates()
        elif action == "open_repo":
            self.panel.close()
            webbrowser.open(REPO_URL)
        elif action == "select_tool":
            choices = view_choices(self.state, detect_tools())
            self.state["selected_tool"] = choices[value][0]
            save_state(self.state, STATE_FILE)
            self._update_title()
        elif action.startswith("welcome_tool:"):
            key = action.split(":", 1)[1]
            self.welcome_choice = [k for k in self.welcome_choice if k != key] + ([key] if value else [])
        elif action == "welcome_done":
            self.finish_welcome()
        elif action.startswith("tool:"):
            self.set_tool_enabled(action.split(":", 1)[1], value)
        self._render_panel()

    def finish_welcome(self):
        order = [key for key, _ in TOOLS]
        self.state["enabled_tools"] = sorted(self.welcome_choice, key=order.index)
        if self.state["enabled_tools"]:
            self.state["selected_tool"] = self.state["enabled_tools"][0]
        self.state["onboarding_done"] = True
        self._scan()
        save_state(self.state, STATE_FILE)
        self._update_title()

    def set_tool_enabled(self, key, enabled):
        order = [k for k, _ in TOOLS]
        tools = set(self.state["enabled_tools"])
        tools = tools | {key} if enabled else tools - {key}
        self.state["enabled_tools"] = sorted(tools, key=order.index)
        if enabled:
            scan_tools(self.state, [key])
        save_state(self.state, STATE_FILE)
        self._update_title()

    def set_provider_enabled(self, key, enabled):
        order = [k for k, _ in PROVIDERS]
        providers = set(self.state["enabled_providers"])
        providers = providers | {key} if enabled else providers - {key}
        self.state["enabled_providers"] = sorted(providers, key=order.index)
        if enabled:
            self._scan()  # a provider's models may be in tools not enabled yet
            self._fetch_accounts()
        save_state(self.state, STATE_FILE)
        self._update_title()

    def add_api_key(self, provider):
        name = PROVIDER_NAMES[provider]
        response = rumps.Window(
            message=(f"Paste your {name} API key. It's stored only in this Mac's "
                     f"Keychain and sent only to {name}.\n\n{KEY_HELP[provider]}."),
            title=f"{name} API Key",
            ok="Save",
            cancel="Cancel",
            secure=True,
        ).run()
        if not response.clicked or not response.text.strip():
            return
        try:
            save_key(provider, response.text)
        except (ValueError, OSError) as e:
            rumps.alert("Key Not Saved", str(e))
            return
        keys = set(self.state["provider_keys"]) | {provider}
        self.state["provider_keys"] = [k for k, _ in PROVIDERS if k in keys]
        self.state.get("accounts", {}).pop(provider, None)  # numbers from an older key
        save_state(self.state, STATE_FILE)
        self._fetch_accounts(force=provider)

    def remove_api_key(self, provider):
        name = PROVIDER_NAMES[provider]
        confirmed = rumps.alert(
            f"Remove {name} API Key?",
            f"This deletes the key from this Mac's Keychain. To see {name} account "
            "numbers again you'll need to paste it again.",
            ok="Remove",
            cancel="Cancel",
        )
        if not confirmed:
            return
        delete_key(provider)
        self.state["provider_keys"] = [k for k in self.state["provider_keys"] if k != provider]
        self.state.get("accounts", {}).pop(provider, None)
        save_state(self.state, STATE_FILE)
        self._render_panel()

    def _fetch_accounts(self, force=None):
        """Start a background fetch for each enabled provider with a key whose
        numbers are due (every 15 minutes) or `force`d."""
        saved = self.state.get("accounts", {})
        for key in self.state["enabled_providers"]:
            if key not in self.state["provider_keys"] or key in self._fetching:
                continue
            if key != force and not account_due(saved.get(key)):
                continue
            self._fetching.add(key)
            threading.Thread(target=self._fetch_account, args=(key,), daemon=True).start()

    def _fetch_account(self, provider):
        """Runs on a background thread; the result is saved on the main thread."""
        try:
            api_key = load_key(provider)
            if api_key:
                result = fetch_account(provider, api_key)
            else:
                result = {"error": "the key is no longer in the Keychain"}
        except Exception as e:  # keep the fetch from being stuck "in flight"
            result = {"error": f"unexpected problem ({type(e).__name__})"}
        if result["error"] and "fetched_at" not in result:
            result = {"daily": {}, "cost": {}, "rows": [], "notes": [], **result,
                      "fetched_at": datetime.now().isoformat(timespec="seconds")}
        self._fetched.append((provider, result))
        AppHelper.callAfter(self._show_fetched_accounts)

    def _show_fetched_accounts(self):
        self._save_fetched_accounts()
        save_state(self.state, STATE_FILE)
        self._render_panel()

    def _save_fetched_accounts(self):
        while self._fetched:
            provider, result = self._fetched.pop(0)
            self._fetching.discard(provider)
            if provider in self.state["provider_keys"]:  # not removed meanwhile
                store_result(self.state, provider, result)

    def _leaderboard_payload(self):
        yesterday = date.today() - timedelta(days=1)
        return {
            "name": self.state.get("leaderboard_name") or "Anonymous",
            "total_tokens": self.state["grand_total"],
            "yesterday_tokens": sum_usage_for_today(today=yesterday),
            "updated_at": date.today().isoformat(),
        }

    def start_leaderboard_setup(self):
        proceed = rumps.alert(
            "Set Up Leaderboard (Beta)",
            "This opens GitHub in your browser to create a personal access "
            "token scoped only to 'gist'. Generate it, then come back here "
            "and paste it in.",
            ok="Open GitHub",
            cancel="Cancel",
        )
        if not proceed:
            return
        webbrowser.open(NEW_TOKEN_URL)

        token_response = rumps.Window(
            message="Paste your GitHub token here:",
            title="GitHub Token",
            ok="Continue",
            cancel="Cancel",
            secure=True,
        ).run()
        if not token_response.clicked or not token_response.text.strip():
            return
        token = token_response.text.strip()

        name_response = rumps.Window(
            message="What name should show on the leaderboard?",
            title="Your Leaderboard Name",
            default_text=os.environ.get("USER", ""),
            ok="Continue",
            cancel="Cancel",
        ).run()
        if not name_response.clicked or not name_response.text.strip():
            return
        self.state["leaderboard_name"] = name_response.text.strip()

        try:
            set_github_token(token)
            gist_id = create_gist(token, self._leaderboard_payload())
        except (subprocess.CalledProcessError, urllib.error.URLError, KeyError) as e:
            rumps.alert("Setup Failed", str(e))
            return

        self.state["my_gist_id"] = gist_id
        save_state(self.state, STATE_FILE)
        self._render_panel()
        rumps.alert("All Set", f"Your friend code is:\n\n{gist_id}")

    def share_friend_code(self):
        rumps.alert("Your Friend Code", self.state.get("my_gist_id", ""))

    def push_leaderboard_update(self):
        gist_id = self.state.get("my_gist_id")
        if not gist_id:
            return
        token = get_github_token()
        if not token:
            rumps.alert(
                "Leaderboard", "No GitHub token found -- run Get Set Up again."
            )
            return
        try:
            update_gist(token, gist_id, self._leaderboard_payload())
        except urllib.error.URLError as e:
            rumps.alert("Push Failed", str(e))

    def add_friend_by_code(self):
        response = rumps.Window(
            message="Paste your friend's Gist ID (their friend code):",
            title="Add Friend",
            ok="Add",
            cancel="Cancel",
        ).run()
        if not response.clicked or not response.text.strip():
            return
        gist_id = response.text.strip()
        friends = load_friends()
        if any(f.get("gist_id") == gist_id for f in friends):
            return
        friends.append(
            {"gist_id": gist_id, "name": gist_id, "total_tokens": 0, "yesterday_tokens": 0}
        )
        save_friends(friends)
        self.pull_leaderboard_updates()

    def pull_leaderboard_updates(self):
        friends = load_friends()
        updated = []
        for friend in friends:
            try:
                data = fetch_gist(friend["gist_id"])
            except (urllib.error.URLError, KeyError):
                updated.append(friend)
                continue
            updated.append(
                {
                    "gist_id": friend["gist_id"],
                    "name": data.get("name", friend.get("name", "Friend")),
                    "total_tokens": data.get("total_tokens", 0),
                    "yesterday_tokens": data.get("yesterday_tokens", 0),
                }
            )
        save_friends(updated)

    def _maybe_run_daily_leaderboard_sync(self):
        today = date.today().isoformat()
        if not leaderboard_enabled(self.state):
            return
        if self.state.get("last_leaderboard_sync_date") == today:
            return
        self.push_leaderboard_update()
        self.pull_leaderboard_updates()
        self.state["last_leaderboard_sync_date"] = today
        save_state(self.state, STATE_FILE)

    def _fetch_claude_usage(self):
        """Start a background fetch of Claude Code's limit percentages, every
        5 minutes while Claude Code is tracked and the switch is on."""
        if (self._fetching_claude or not self.state["claude_usage_enabled"]
                or "claude_code" not in self.state["enabled_tools"]
                or not usage_due(self.state.get("claude_usage"))):
            return
        self._fetching_claude = True
        threading.Thread(target=self._fetch_claude_usage_now, daemon=True).start()

    def _fetch_claude_usage_now(self):
        """Runs on a background thread; the result is saved on the main thread."""
        try:
            result = fetch_usage()
        except Exception as e:  # keep the fetch from being stuck "in flight"
            result = {"limits": [], "error": f"Unexpected problem ({type(e).__name__}). "
                                             "Percentage unavailable.", "fetched_at": time.time()}
        AppHelper.callAfter(self._show_claude_usage, result)

    def _show_claude_usage(self, result):
        self._fetching_claude = False
        if not self.state["claude_usage_enabled"]:
            return  # turned off meanwhile
        self.state["claude_usage"] = result
        save_state(self.state, STATE_FILE)
        self._check_alerts()
        self._render_panel()

    def check_for_updates(self):
        """List the newer releases and ask whether to install the newest."""
        if self.update_status:
            return  # already checking or updating
        self._show_update_status("Checking…")
        threading.Thread(target=self._find_updates, daemon=True).start()

    def _find_updates(self):
        """Runs on a background thread; the answer is shown on the main thread."""
        try:
            outcome = ("found", newer_releases())
        except UpdateError as e:
            outcome = ("error", str(e))
        except Exception as e:  # keep the check from being stuck "in flight"
            outcome = ("error", f"Unexpected problem ({type(e).__name__}).")
        AppHelper.callAfter(self._offer_updates, outcome)

    def _offer_updates(self, outcome):
        kind, releases = outcome
        if kind == "error" or not releases:
            self._finish_update(outcome if kind == "error" else ("current", None))
            return
        self.update_status = None
        self._render_panel()
        newest = releases[0]["tag"].lstrip("v")
        count = len(releases)
        self.panel.close()
        wanted = confirm_with_details(
            f"{count} Updates Available" if count > 1 else "Update Available",
            f"{APP_NAME} {newest} is available (you have {__version__}). Updating keeps "
            "your settings and totals, and restarts the app.",
            describe_releases(releases), ok=f"Update to {newest}", cancel="Not Now",
        )
        if not wanted:
            return
        self._show_update_status(f"Updating to {newest}…")
        threading.Thread(target=self._install_update, args=(releases[0]["tag"],),
                         daemon=True).start()

    def _install_update(self, tag):
        """Runs on a background thread; the outcome is shown on the main thread."""
        try:
            install_release(tag)
            rebuild_bundle(_build_python(), _bundle_path().parent)
            outcome = ("updated", tag)
        except UpdateError as e:
            outcome = ("error", str(e))
        except Exception as e:  # keep the check from being stuck "in flight"
            outcome = ("error", f"Unexpected problem ({type(e).__name__}).")
        AppHelper.callAfter(self._finish_update, outcome)

    def _show_update_status(self, status):
        self.update_status = status
        self._render_panel()

    def _finish_update(self, outcome):
        kind, detail = outcome
        self.update_status = None
        self._render_panel()
        if kind == "updated":
            self.state["updated_to"] = detail
            save_state(self.state, STATE_FILE)
            subprocess.Popen(["/bin/sh", "-c", restart_command(os.getpid(), _bundle_path(),
                                                               _service_target())],
                             start_new_session=True)
            rumps.quit_application()
        elif kind == "current":
            rumps.alert("You're Up to Date", f"{APP_NAME} {__version__} is the newest version.")
        else:
            rumps.alert("Couldn't Update", detail)

    def send_test_alert(self):
        self.notifier.send_checked("Test alert: this is how usage alerts look.",
                                   on_blocked=self._notifications_blocked,
                                   on_no_banners=self._banners_off)

    def _notifications_blocked(self):
        self._point_to_notification_settings(
            "Notifications Are Off",
            f"macOS isn't letting {APP_NAME} show notifications. Turn them on for "
            f"{APP_NAME} in System Settings > Notifications.",
        )

    def _banners_off(self):
        self._point_to_notification_settings(
            "Alerts Won't Pop Up",
            f"The test alert was sent, but {APP_NAME}'s alert style is set to None, so macOS "
            "puts alerts only in Notification Center. To see them on screen, choose Temporary "
            f"or Persistent for {APP_NAME} in System Settings > Notifications.",
        )

    def _point_to_notification_settings(self, title, message):
        self.panel.close()
        answer = rumps.alert(title, message, ok="Open Settings", cancel="Not Now")
        if answer == 1:
            subprocess.run(["open", SETTINGS_URL], capture_output=True)

    def _check_alerts(self):
        """Notify about limits that just reached the threshold."""
        if not self.state["alerts_enabled"]:
            return
        levels = levels_for_alerts(self.state, time.time())
        messages, above = alerts_to_send(
            levels, self.state["alert_thresholds"], self.state["alert_windows"],
            self.state["alerts_above"], now=time.time(),
        )
        if above != self.state["alerts_above"]:
            self.state["alerts_above"] = above
            save_state(self.state, STATE_FILE)
        for message in messages:
            self.notifier.send(message)

    def refresh(self, _):
        self._scan()
        self._save_fetched_accounts()
        save_state(self.state, STATE_FILE)
        self._check_alerts()
        self._fetch_accounts()
        self._fetch_claude_usage()
        self._update_title()
        self._maybe_run_daily_leaderboard_sync()
        self._render_panel()

    def set_scan_interval(self, seconds):
        self.state["scan_interval_seconds"] = seconds
        save_state(self.state, STATE_FILE)

        # Timer.interval's setter silently no-ops if the current interval
        # hasn't elapsed yet, so swap in a fresh Timer instead of relying on it.
        was_alive = self.timer.is_alive()
        if was_alive:
            self.timer.stop()
        self.timer = rumps.Timer(self.refresh, seconds)
        if was_alive:
            self.timer.start()

    def set_start_at_login(self, enabled):
        try:
            set_start_at_login(enabled)
        except subprocess.CalledProcessError as e:
            self.panel.close()
            rumps.alert("Couldn't update login setting", str(e))
            return
        self.state["start_at_login"] = enabled
        save_state(self.state, STATE_FILE)


def _bundle_path():
    """The "Claude Tracker.app" this is running from, or where install.sh
    puts it when run as plain `python3 app.py`."""
    from build_app import default_dest

    executable = Path(sys.executable)
    if executable.parent.name == "MacOS" and executable.parents[2].suffix == ".app":
        return executable.parents[2]
    return default_dest() / f"{APP_NAME}.app"


def _build_python():
    """The Python the bundle was built with (the launcher passes it on)."""
    return os.environ.get("CLAUDE_TRACKER_PYTHON") or sys.executable


def _fallback_notification(title, message):
    """For when the app isn't running from its bundle (e.g. `python3 app.py`):
    AppleScript's notification, shown as Script Editor's."""
    subprocess.run(["osascript", "-e", "on run argv", "-e",
                    "display notification (item 1 of argv) with title (item 2 of argv)",
                    "-e", "end run", message, title], capture_output=True)


def hide_dock_icon():
    # Accessory policy = menu-bar only: no Dock icon, no app menu, not in Cmd-Tab.
    NSApplication.sharedApplication().setActivationPolicy_(
        NSApplicationActivationPolicyAccessory
    )


if __name__ == "__main__":
    instance_lock = acquire_lock(LOCK_FILE)
    if instance_lock is None:
        # Already running (e.g. started at login): show that copy's panel.
        request_show_panel()
        sys.exit(0)
    hide_dock_icon()
    TokenCounterApp().run()
