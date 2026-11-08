"""Claude Code's plan limits as percentages, from Anthropic.

Claude Code only logs a limit once it's reached, so the real percentages
(5-hour and weekly) come from the same endpoint Claude Code's `/usage`
command reads, signed in with Claude Code's own saved sign-in.

Privacy:
- The sign-in is read from the macOS Keychain item Claude Code keeps
  ("Claude Code-credentials") each time and never stored, logged or
  written to state.json.
- It's sent only over HTTPS, only to api.anthropic.com, and redirects are
  not followed.
- The app never renews the sign-in itself: renewing replaces Claude Code's
  saved sign-in, which could sign Claude Code out. Claude Code renews it
  while you use it.
- Only the usage percentages and reset times are requested.

The endpoint isn't documented, so any answer that doesn't look as expected
reads as "unavailable" rather than wrong numbers.

Kept free of AppKit so it can be unit-tested.
"""

import json
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime
from urllib.parse import urlparse

from version import __version__

KEYCHAIN_SERVICE = "Claude Code-credentials"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
ALLOWED_HOST = "api.anthropic.com"
REFRESH_SECONDS = 5 * 60

# Anthropic's names for its limits -> (alert id suffix, app window, label).
LIMITS = [
    ("five_hour", "five_hour", "five_hour", "5-hour"),
    ("seven_day", "weekly", "weekly", "Weekly"),
    ("seven_day_opus", "weekly_opus", "weekly", "Weekly · Opus"),
    ("seven_day_sonnet", "weekly_sonnet", "weekly", "Weekly · Sonnet"),
]

OFFLINE = "Couldn't reach server. Percentage unavailable."
SIGNED_OUT = "Sign in to Claude Code to see percentages."
EXPIRED = "Claude Code's sign-in has expired. Open Claude Code to refresh it."


def load_token(run=subprocess.run, now=None):
    """Claude Code's access token from the Keychain: (token, error)."""
    result = run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                 capture_output=True, text=True)
    if result.returncode != 0:
        return None, SIGNED_OUT
    try:
        oauth = json.loads(result.stdout)["claudeAiOauth"]
        token = oauth["accessToken"]
    except (ValueError, KeyError, TypeError):
        return None, SIGNED_OUT
    expires_at = oauth.get("expiresAt")  # milliseconds
    if expires_at and expires_at / 1000 <= (now or time.time()):
        return None, EXPIRED
    return token, None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # a redirect becomes an HTTPError; the token never follows it


_opener = urllib.request.build_opener(_NoRedirect)


def http_get_json(url, token):
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != ALLOWED_HOST:
        raise ValueError(f"refusing to send Claude Code's sign-in to {parsed.hostname}")
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "Accept": "application/json",
        "User-Agent": f"ClaudeTracker/{__version__}",
    })
    with _opener.open(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def _unix_time(value):
    if isinstance(value, (int, float)):
        return float(value)
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def parse_usage(data):
    """The limits in an answer, as {"kind", "window", "label", "percent",
    "resets_at"}. Raises ValueError if it has none of them."""
    limits = []
    for name, kind, window, label in LIMITS:
        info = data.get(name) if isinstance(data, dict) else None
        if not isinstance(info, dict) or info.get("utilization") is None:
            continue
        resets_at = info.get("resets_at")
        limits.append({
            "kind": kind, "window": window, "label": label,
            "percent": float(info["utilization"]),
            "resets_at": _unix_time(resets_at) if resets_at else None,
        })
    if not limits:
        raise ValueError("no limits in the answer")
    return limits


def _describe(error):
    if isinstance(error, urllib.error.HTTPError):
        if error.code in (401, 403):
            return EXPIRED
        return f"Anthropic answered HTTP {error.code}. Percentage unavailable."
    if isinstance(error, (urllib.error.URLError, OSError)):
        return OFFLINE
    return "Anthropic sent an unexpected answer. Percentage unavailable."


def fetch_usage(get=http_get_json, run=subprocess.run, now=None):
    """{"limits": [...], "error": message or None, "fetched_at": unix time}.
    On an error there are no limits: old percentages could be wrong."""
    now = now or time.time()
    token, error = load_token(run=run, now=now)
    limits = []
    if token:
        try:
            limits = parse_usage(get(USAGE_URL, token))
        except Exception as e:  # noqa: BLE001 -- any failure reads as unavailable
            error = _describe(e)
    return {"limits": limits, "error": error, "fetched_at": now}


def usage_due(saved, now=None):
    if not saved or not saved.get("fetched_at"):
        return True
    return (now or time.time()) - saved["fetched_at"] >= REFRESH_SECONDS
