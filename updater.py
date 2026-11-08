"""Check for Updates: install the newest GitHub release over this copy.

The app runs straight from this git clone, so updating is a fast-forward
to the release's tag, then rebuilding the app bundle. Settings and totals
(state.json, friends.json) are gitignored, so they stay as they are.

It won't update a copy that has local code changes or is on a branch other
than master, so nobody's own work is ever overwritten.

Kept free of AppKit so it can be unit-tested.
"""

import json
import re
import subprocess
import urllib.request
from pathlib import Path

from version import REPO_URL, __version__

PROJECT_DIR = Path(__file__).resolve().parent
LATEST_URL = "https://api.github.com/repos/raymondtian30/claude-tracker/releases/latest"
UPDATE_BRANCHES = {"master", "main"}
TAG_PATTERN = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


class UpdateError(Exception):
    """Why this copy wasn't updated, in words for the user."""


def parse_version(text):
    """'v2.1.0' or '2.1.0' -> (2, 1, 0); None if it isn't one."""
    match = TAG_PATTERN.match((text or "").strip())
    return tuple(int(part) for part in match.groups()) if match else None


def is_newer(tag, current=__version__):
    latest = parse_version(tag)
    return latest is not None and latest > parse_version(current)


def http_get_json(url):
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": f"ClaudeTracker/{__version__}",
    })
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def latest_release(get=http_get_json):
    """The newest release's tag, e.g. 'v2.2.0'. Raises UpdateError if
    GitHub can't be reached or answers oddly."""
    try:
        tag = get(LATEST_URL).get("tag_name")
    except Exception as e:  # noqa: BLE001 -- offline, rate limited, bad JSON...
        raise UpdateError("Couldn't reach GitHub to check for updates.") from e
    if not parse_version(tag):
        raise UpdateError("GitHub's latest release doesn't have a version number.")
    return tag


def _git(run, project_dir, *args):
    return run(["git", "-C", str(project_dir), *args], capture_output=True, text=True)


def install_release(tag, run=subprocess.run, project_dir=PROJECT_DIR, repo_url=f"{REPO_URL}.git"):
    """Fast-forward this clone to `tag`. Raises UpdateError, leaving the
    code as it was, if that isn't safe or doesn't work."""
    status = _git(run, project_dir, "status", "--porcelain", "--untracked-files=no")
    if status.returncode != 0:
        raise UpdateError("This copy of the app isn't a git clone, so it can't update itself. "
                          "Download it again from GitHub.")
    if status.stdout.strip():
        raise UpdateError("The app's code has local changes, so it wasn't updated.")
    branch = _git(run, project_dir, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if branch not in UPDATE_BRANCHES:
        raise UpdateError(f"This copy is on the branch \"{branch}\", so it wasn't updated. "
                          "Switch to master to get updates.")
    fetched = _git(run, project_dir, "fetch", "--quiet", "--no-tags", repo_url,
                   f"+refs/tags/{tag}:refs/tags/{tag}")
    if fetched.returncode != 0:
        raise UpdateError("Couldn't download the update from GitHub.")
    merged = _git(run, project_dir, "merge", "--ff-only", "--quiet", tag)
    if merged.returncode != 0:
        raise UpdateError(f"This copy has commits that aren't in {tag}, so it wasn't updated.")


def rebuild_bundle(python, bundle_dir, run=subprocess.run, project_dir=PROJECT_DIR):
    """Rebuild "Claude Tracker.app" from the updated code, where it is now."""
    built = run([python, str(project_dir / "build_app.py"), "--python", python,
                 "--dest", str(bundle_dir)], capture_output=True, text=True)
    if built.returncode != 0:
        raise UpdateError("The update was downloaded, but rebuilding the app failed. "
                          "Run ./install.sh to finish.")


def restart_command(pid, bundle, service_target):
    """A shell command that waits for `pid` to quit, then starts the app
    again: through its LaunchAgent if it has one, else by opening it."""
    from shlex import quote

    return (f"while kill -0 {int(pid)} 2>/dev/null; do sleep 0.2; done; "
            f"launchctl kickstart {quote(service_target)} 2>/dev/null || open {quote(str(bundle))}")
