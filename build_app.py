"""Build "Claude Tracker.app": a stand-in that runs ./build.sh.

Claude Tracker is a Swift app now, built by build.sh. This file stays for
one reason: updating from 2.5.0 (the last Python version). 2.5.0's Check
for Updates fast-forwards this clone to the new release, then runs

    <python> build_app.py --python <python> --dest <folder>

and restarts the app only if that exits with 0. So this script accepts
those arguments (--python is ignored: nothing here needs it), runs
`./build.sh --dest <folder>`, and passes on its output and exit code. It
uses only Python's standard library, since the update may run it with any
Python 3. Delete it once nobody can still be on 2.5.0.

If the build fails (no Command Line Tools, Swift older than 5.9, macOS
older than 13), the clone has already been moved to the Swift release and
the Python files are gone, but the old app is still installed: build.sh
only replaces it once a build has worked. Left like that, the next launch
would run a Python app whose code no longer exists. So, only when this
looks like that exact situation, this script moves the clone back with
`git reset --keep ORIG_HEAD` (the commit before the fast-forward). That
brings the Python files back, keeps any local changes and never touches
untracked files such as state.json and friends.json. 2.5.0 then shows
"rebuilding failed" and keeps running as before.

"That exact situation" means: ORIG_HEAD exists, it's an ancestor of HEAD
(a fast-forward), its tree has app.py and HEAD's doesn't. Anything else
(e.g. a Swift-to-Swift build that failed) is left alone.

Usage:
    python3 build_app.py [--python /path/to/python3] [--dest /Applications]

Prints the path of the bundle's executable as its last line, as before.
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent


def default_dest():
    """Where the app goes by default (build.sh's default too). 2.5.0's
    app.py imports this after the update has fast-forwarded the clone, so
    it has to stay."""
    system = Path("/Applications")
    if os.access(system, os.W_OK):
        return system
    return Path.home() / "Applications"


def _git(project_dir, *args):
    return subprocess.run(["git", "-C", str(project_dir), *args],
                          capture_output=True, text=True)


def came_from_python(project_dir=PROJECT_DIR):
    """True if HEAD was just fast-forwarded from a Python version (ORIG_HEAD
    has app.py) to one without it."""
    if _git(project_dir, "rev-parse", "--verify", "--quiet", "ORIG_HEAD^{commit}").returncode != 0:
        return False
    if _git(project_dir, "merge-base", "--is-ancestor", "ORIG_HEAD", "HEAD").returncode != 0:
        return False
    had_python = _git(project_dir, "cat-file", "-e", "ORIG_HEAD:app.py").returncode == 0
    has_python = _git(project_dir, "cat-file", "-e", "HEAD:app.py").returncode == 0
    return had_python and not has_python


def roll_back(project_dir=PROJECT_DIR):
    """Move the clone back to ORIG_HEAD. True if that worked."""
    result = _git(project_dir, "reset", "--keep", "ORIG_HEAD")
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
    return result.returncode == 0


def main(argv=None, project_dir=PROJECT_DIR):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--python", help="ignored (kept for updates from 2.5.0)")
    parser.add_argument("--dest", default=str(default_dest()))
    args = parser.parse_args(argv)

    built = subprocess.run(["/bin/bash", str(Path(project_dir) / "build.sh"), "--dest", args.dest])
    if built.returncode == 0:
        return 0

    if came_from_python(project_dir):
        if roll_back(project_dir):
            print("Building the Swift version failed, so this folder was moved back to the "
                  "Python version you had (git reset --keep ORIG_HEAD). The installed app "
                  "wasn't changed. Install Swift with xcode-select --install, then run "
                  "./install.sh or Check for Updates again.", file=sys.stderr)
        else:
            print("Building the Swift version failed, and moving this folder back to the "
                  "Python version didn't work either. Run `git reset --keep ORIG_HEAD` in "
                  f"{project_dir}, or ./install.sh once Swift is installed.", file=sys.stderr)
    return built.returncode


if __name__ == "__main__":
    sys.exit(main())
