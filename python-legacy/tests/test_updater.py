import subprocess

import pytest

import updater
from updater import UpdateError, install_release, is_newer, parse_version


def test_parse_version():
    assert parse_version("v2.1.0") == (2, 1, 0)
    assert parse_version("2.10.3") == (2, 10, 3)
    assert parse_version("nightly") is None
    assert parse_version(None) is None


def test_is_newer_compares_numbers_not_text():
    assert is_newer("v2.10.0", current="2.9.0")
    assert not is_newer("v2.1.0", current="2.1.0")
    assert not is_newer("v2.0.5", current="2.1.0")
    assert not is_newer("garbage", current="2.1.0")


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


@pytest.fixture
def clone(tmp_path):
    """A 'GitHub' repo with a v2.2.0 release one commit ahead, and a clone
    of it still at the older commit, with settings in a gitignored file."""
    remote = tmp_path / "remote"
    remote.mkdir()
    git(remote, "init", "-q", "-b", "master")
    git(remote, "config", "user.email", "t@example.com")
    git(remote, "config", "user.name", "t")
    (remote / ".gitignore").write_text("state.json\n")
    (remote / "version.py").write_text('__version__ = "2.1.0"\n')
    git(remote, "add", ".")
    git(remote, "commit", "-q", "-m", "2.1.0")
    local = tmp_path / "local"
    git(tmp_path, "clone", "-q", str(remote), str(local))
    (remote / "version.py").write_text('__version__ = "2.2.0"\n')
    git(remote, "commit", "-q", "-am", "2.2.0")
    git(remote, "tag", "v2.2.0")
    (local / "state.json").write_text('{"title_mode": "today"}')
    return remote, local


def test_install_release_fast_forwards_and_keeps_settings(clone):
    remote, local = clone

    install_release("v2.2.0", project_dir=local, repo_url=str(remote))

    assert (local / "version.py").read_text() == '__version__ = "2.2.0"\n'
    assert (local / "state.json").read_text() == '{"title_mode": "today"}'


def test_install_release_leaves_local_changes_alone(clone):
    remote, local = clone
    (local / "version.py").write_text("# my edit\n")

    with pytest.raises(UpdateError, match="local changes"):
        install_release("v2.2.0", project_dir=local, repo_url=str(remote))

    assert (local / "version.py").read_text() == "# my edit\n"


def test_install_release_only_from_master(clone):
    remote, local = clone
    git(local, "checkout", "-q", "-b", "my-feature")

    with pytest.raises(UpdateError, match='branch "my-feature"'):
        install_release("v2.2.0", project_dir=local, repo_url=str(remote))


def test_install_release_wont_drop_local_commits(clone):
    remote, local = clone
    git(local, "config", "user.email", "t@example.com")
    git(local, "config", "user.name", "t")
    (local / "mine.txt").write_text("x")
    git(local, "add", "mine.txt")
    git(local, "commit", "-q", "-m", "mine")

    with pytest.raises(UpdateError, match="commits that aren't in v2.2.0"):
        install_release("v2.2.0", project_dir=local, repo_url=str(remote))

    assert (local / "mine.txt").exists()


def test_install_release_outside_a_git_clone(tmp_path):
    with pytest.raises(UpdateError, match="isn't a git clone"):
        install_release("v2.2.0", project_dir=tmp_path, repo_url="unused")


def test_install_release_fetches_from_this_apps_repo():
    calls = []

    def run(args, **kwargs):
        calls.append(args)
        stdout = "master\n" if "rev-parse" in args else ""
        return subprocess.CompletedProcess(args, 0, stdout=stdout, stderr="")

    install_release("v2.2.0", run=run, project_dir="/p")

    fetch = next(c for c in calls if "fetch" in c)
    assert "https://github.com/raymondtian30/claude-tracker.git" in fetch
    assert "+refs/tags/v2.2.0:refs/tags/v2.2.0" in fetch


def test_restart_waits_for_the_app_to_quit_then_starts_it():
    command = updater.restart_command(123, "/Applications/Claude Tracker.app", "gui/501/x")

    assert command.startswith("while kill -0 123 ")
    assert "launchctl kickstart gui/501/x" in command
    assert "open '/Applications/Claude Tracker.app'" in command


def test_about_has_check_for_updates():
    from stats_tabs import settings_tab

    tab = settings_tab({}, interval_choices=[15], detected=[],
                       update_status="Checking…")

    about = next(c for c in tab["cards"] if c["title"] == "About")["items"]
    assert ("row", "Updates", "Checking…") in about
    buttons = next(i for i in about if i[0] == "buttons")[1]
    assert ("Check for Updates", "arrow.down.circle", "check_updates") in buttons


RELEASES = [  # as GitHub lists them: newest first
    {"tag_name": "v2.3.0", "name": "Claude Tracker 2.3.0", "draft": False, "prerelease": False,
     "body": "## New\n\n- **Update dialog.** Lists what's new.\n"},
    {"tag_name": "v2.4.0-beta", "name": "beta", "draft": False, "prerelease": True, "body": "x"},
    {"tag_name": "v2.2.2", "name": "Claude Tracker 2.2.2", "draft": False, "prerelease": False,
     "body": "## Fixed\n\n- Notifications show."},
    {"tag_name": "v9.0.0", "name": "draft", "draft": True, "prerelease": False, "body": "x"},
    {"tag_name": "v2.2.1", "name": "Claude Tracker 2.2.1", "draft": False, "prerelease": False,
     "body": "old"},
]


def test_newer_releases_lists_every_published_release_after_this_one():
    from updater import RELEASES_URL, newer_releases

    seen = []

    def get(url):
        seen.append(url)
        return RELEASES

    releases = newer_releases(get=get, current="2.2.1")

    assert seen == [RELEASES_URL]
    assert [r["tag"] for r in releases] == ["v2.3.0", "v2.2.2"]  # newest first
    assert releases[0]["notes"] == "## New\n\n- **Update dialog.** Lists what's new."


def test_newer_releases_when_up_to_date_or_offline():
    from updater import newer_releases

    assert newer_releases(get=lambda url: RELEASES, current="2.3.0") == []

    def offline(url):
        raise OSError("no network")

    with pytest.raises(UpdateError, match="Couldn't reach GitHub"):
        newer_releases(get=offline)


def test_release_notes_read_as_plain_text():
    from updater import describe_releases

    text = describe_releases([
        {"tag": "v2.3.0", "notes": "## New\n\n- **Update dialog.** Lists what's new.\n"},
        {"tag": "v2.2.2", "notes": ""},
    ])

    assert text == ("Version 2.3.0\nNew\n• Update dialog. Lists what's new.\n\n"
                    "Version 2.2.2\nNo notes.")
