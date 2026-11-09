import os
import plistlib
import subprocess
import time
from pathlib import Path

import build_app
from version import APP_NAME, __version__


def test_build_creates_menu_bar_only_bundle(tmp_path):
    project = tmp_path / "my project"  # a space, to check quoting
    project.mkdir()

    bundle = build_app.build(tmp_path / "Apps", "/usr/bin/python3", project_dir=project, icon=False)

    assert bundle == tmp_path / "Apps" / f"{APP_NAME}.app"
    with open(bundle / "Contents" / "Info.plist", "rb") as f:
        info = plistlib.load(f)
    assert info["CFBundleExecutable"] == build_app.EXECUTABLE_NAME
    assert info["CFBundleShortVersionString"] == __version__
    assert info["LSUIElement"] is True
    executable = bundle / "Contents" / "MacOS" / build_app.EXECUTABLE_NAME
    assert os.access(executable, os.X_OK)
    script = executable.read_text()
    assert f"cd '{project}'" in script
    assert f"""exec "$PYTHON" '{project / 'app.py'}'""" in script
    assert f"""nohup "$PYTHON" '{project / 'app.py'}'""" in script
    assert "PYTHON=/usr/bin/python3" in script  # if the bundled copy can't run


def test_build_puts_a_copy_of_pythons_interpreter_in_the_bundle(tmp_path):
    import sys

    bundle = build_app.build(tmp_path, sys.executable, project_dir=tmp_path, icon=False)

    interpreter = bundle / "Contents" / "MacOS" / build_app.INTERPRETER_NAME
    expected = build_app.interpreter_binary(sys.executable)
    if expected is None:  # not a framework build: nothing to copy
        assert not interpreter.exists()
        return
    assert os.access(interpreter, os.X_OK)  # re-signed, so not byte-for-byte the same
    signature = subprocess.run(["codesign", "-dv", str(interpreter)],
                               capture_output=True, text=True).stderr
    # macOS refuses notifications unless this matches the bundle's identifier.
    assert f"Identifier={build_app.BUNDLE_ID}\n" in signature
    assert subprocess.run(["codesign", "--verify", str(bundle)]).returncode == 0
    result = subprocess.run([str(interpreter), "-c", "from Foundation import NSBundle;"
                             "print(NSBundle.mainBundle().bundleIdentifier())"],
                            capture_output=True, text=True)
    assert result.stdout.strip() == build_app.BUNDLE_ID


def test_interpreter_binary_is_none_for_a_python_that_cant_run(tmp_path):
    assert build_app.interpreter_binary(str(tmp_path / "missing-python")) is None


def _fake_project(tmp_path):
    project = tmp_path / "proj"
    project.mkdir()
    # Records its working directory and parent pid, then exits.
    (project / "app.py").write_text(
        "import os; open('ran.txt', 'w').write(os.getcwd() + '\\n' + str(os.getppid()))\n"
    )
    bundle = build_app.build(tmp_path, "/usr/bin/python3", project_dir=project, icon=False)
    return project, bundle / "Contents" / "MacOS" / build_app.EXECUTABLE_NAME


def _wait_for(path, seconds=5):
    deadline = time.monotonic() + seconds
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    return path.read_text().split("\n")


def test_launcher_foreground_runs_app_in_its_own_process(tmp_path):
    project, launcher = _fake_project(tmp_path)

    launcher_proc = subprocess.Popen([str(launcher), "--foreground"])
    launcher_proc.wait(timeout=5)
    cwd, parent = _wait_for(project / "ran.txt")

    assert Path(cwd).resolve() == project.resolve()
    # exec: app.py replaced the launcher, so its parent is this test.
    assert int(parent) == os.getpid()


def test_launcher_from_finder_starts_app_in_background_and_exits(tmp_path):
    project, launcher = _fake_project(tmp_path)

    result = subprocess.run([str(launcher)], timeout=5)
    cwd, parent = _wait_for(project / "ran.txt")

    assert result.returncode == 0
    assert Path(cwd).resolve() == project.resolve()
    assert int(parent) != os.getpid()


def test_build_replaces_existing_bundle_and_makes_icon(tmp_path):
    stale = tmp_path / f"{APP_NAME}.app" / "Contents" / "stale.txt"
    stale.parent.mkdir(parents=True)
    stale.write_text("old")

    bundle = build_app.build(tmp_path, "/usr/bin/python3", project_dir=tmp_path)

    assert not stale.exists()
    icon = bundle / "Contents" / "Resources" / f"{build_app.ICON_NAME}.icns"
    assert icon.stat().st_size > 10_000


def test_building_keeps_python_out_of_the_dock():
    """Drawing the icon uses AppKit; without this, Python.app's rocket
    shows in the Dock while ./install.sh or an update runs."""
    from AppKit import NSApplication, NSApplicationActivationPolicyProhibited

    build_app.stay_out_of_the_dock()

    assert (NSApplication.sharedApplication().activationPolicy()
            == NSApplicationActivationPolicyProhibited)


def test_install_checks_for_rumps_without_importing_it():
    script = (Path(build_app.__file__).parent / "install.sh").read_text()

    assert '-c "import rumps"' not in script  # importing it loads AppKit
    assert "find_spec('rumps')" in script
    assert subprocess.run(["bash", "-n", str(Path(build_app.__file__).parent / "install.sh")]
                          ).returncode == 0
