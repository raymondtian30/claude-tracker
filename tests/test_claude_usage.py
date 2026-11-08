import json
import subprocess
import urllib.error
from datetime import datetime, timezone

import pytest

import claude_usage
from claude_usage import EXPIRED, OFFLINE, SIGNED_OUT, fetch_usage, load_token, parse_usage, usage_due

NOW = datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc).timestamp()


def keychain(payload, returncode=0):
    """A fake `security` run that returns `payload` as the stored item."""
    calls = []

    def run(args, **kwargs):
        calls.append(args)
        stdout = payload if isinstance(payload, str) else json.dumps(payload)
        return subprocess.CompletedProcess(args, returncode, stdout=stdout, stderr="")

    run.calls = calls
    return run


def signed_in(expires_in=3600):
    return keychain({"claudeAiOauth": {"accessToken": "tok", "refreshToken": "never-used",
                                       "expiresAt": (NOW + expires_in) * 1000}})


ANSWER = {
    "five_hour": {"utilization": 23.0, "resets_at": "2026-11-08T15:30:00.000000+00:00"},
    "seven_day": {"utilization": 41.5, "resets_at": "2026-11-12T09:00:00Z"},
    "seven_day_opus": None,
    "seven_day_sonnet": {"utilization": 3, "resets_at": None},
}


def test_load_token_reads_claude_codes_keychain_item():
    run = signed_in()

    assert load_token(run=run, now=NOW) == ("tok", None)
    assert run.calls == [["security", "find-generic-password", "-s", "Claude Code-credentials",
                          "-w"]]


def test_load_token_when_signed_out_or_expired():
    assert load_token(run=keychain("", returncode=44), now=NOW) == (None, SIGNED_OUT)
    assert load_token(run=keychain("not json"), now=NOW) == (None, SIGNED_OUT)
    assert load_token(run=signed_in(expires_in=-1), now=NOW) == (None, EXPIRED)


def test_parse_usage():
    assert parse_usage(ANSWER) == [
        {"kind": "five_hour", "window": "five_hour", "label": "5-hour", "percent": 23.0,
         "resets_at": datetime(2026, 11, 8, 15, 30, tzinfo=timezone.utc).timestamp()},
        {"kind": "weekly", "window": "weekly", "label": "Weekly", "percent": 41.5,
         "resets_at": datetime(2026, 11, 12, 9, 0, tzinfo=timezone.utc).timestamp()},
        {"kind": "weekly_sonnet", "window": "weekly", "label": "Weekly · Sonnet", "percent": 3.0,
         "resets_at": None},
    ]


def test_parse_usage_rejects_an_answer_without_limits():
    with pytest.raises(ValueError):
        parse_usage({"something": "else"})


def test_fetch_usage_sends_the_token_to_the_usage_endpoint():
    seen = []

    def get(url, token):
        seen.append((url, token))
        return ANSWER

    result = fetch_usage(get=get, run=signed_in(), now=NOW)

    assert seen == [("https://api.anthropic.com/api/oauth/usage", "tok")]
    assert result["error"] is None and result["fetched_at"] == NOW
    assert [l["percent"] for l in result["limits"]] == [23.0, 41.5, 3.0]


@pytest.mark.parametrize("error, message", [
    (urllib.error.URLError("offline"), OFFLINE),
    (TimeoutError("timed out"), OFFLINE),
    (urllib.error.HTTPError("u", 401, "no", {}, None), EXPIRED),
    (urllib.error.HTTPError("u", 500, "no", {}, None),
     "Anthropic answered HTTP 500. Percentage unavailable."),
    (ValueError("bad"), "Anthropic sent an unexpected answer. Percentage unavailable."),
])
def test_fetch_usage_without_a_connection_says_percentage_unavailable(error, message):
    def get(url, token):
        raise error

    result = fetch_usage(get=get, run=signed_in(), now=NOW)

    assert result == {"limits": [], "error": message, "fetched_at": NOW}


def test_fetch_usage_never_calls_out_with_an_expired_sign_in():
    def get(url, token):
        raise AssertionError("shouldn't be called")

    assert fetch_usage(get=get, run=signed_in(expires_in=-1), now=NOW)["error"] == EXPIRED


def test_the_token_only_goes_to_anthropic():
    with pytest.raises(ValueError):
        claude_usage.http_get_json("https://example.com/api/oauth/usage", "tok")
    with pytest.raises(ValueError):
        claude_usage.http_get_json("http://api.anthropic.com/api/oauth/usage", "tok")


def test_usage_due_every_five_minutes():
    assert usage_due(None, now=NOW)
    assert not usage_due({"fetched_at": NOW - 299}, now=NOW)
    assert usage_due({"fetched_at": NOW - 300}, now=NOW)
