// Tests for build.sh, install.sh and the build_app.py stand-in, ported from
// tests/test_build_app.py where the behavior still applies. (The Python
// launcher script, the copied interpreter and the icon drawing are gone:
// the bundle's executable is the compiled app and the icon is a file.)
//
// The scripts run for real on temp folders. build.sh's "can this Mac build
// it" checks are tested with a fake `swift` first on PATH, so nothing
// compiles; only buildMakesASignedBundle compiles, so it runs only with
// CT_SLOW_TESTS=1 (./test.sh with that set takes a minute or two longer).
//
// The build_app.py tests act out a 2.5.0 update: a clone at a "Python"
// commit is fast-forwarded to a "Swift" one, then the stand-in runs.

import Foundation
import Testing
@testable import TrackerCore

/// This package's folder (Tests/TrackerCoreTests/ is two levels down).
private let projectDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func makeExecutable(_ url: URL, _ text: String) {
    writeText(url, text)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// Runs `args` (looked up on PATH) and waits for it, with `binDir` (if
/// given) first on PATH, so a fake `swift` there stands in for the real one.
///
/// Output goes to files, not pipes, and the process is started and reaped
/// with posix_spawn and waitpid. Subprocess.run reads stderr on
/// DispatchQueue.global(); with many of these tests blocked at once in
/// parallel, that queue got no thread and every test hung.
private func run(_ args: [String], binDir: URL? = nil) -> Subprocess.Result {
    var environment = ProcessInfo.processInfo.environment
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = binDir.map { "\($0.path):\(path)" } ?? path

    let tmp = TempDir()
    let out = tmp.url("stdout").path
    let err = tmp.url("stderr").path
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, out, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, err, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Don't hand this process's other open files (other tests' pipes) on.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

    // /usr/bin/env looks the program up on the PATH set here.
    let argv = (["/usr/bin/env"] + args).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }

    var pid = pid_t()
    let spawned = posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, argv, envp)
    guard spawned == 0 else {
        return Subprocess.Result(status: 127, stderr: "posix_spawn failed: \(spawned)")
    }
    var waitStatus: Int32 = 0
    while waitpid(pid, &waitStatus, 0) == -1 && errno == EINTR {}
    let signal = waitStatus & 0x7f
    let status = signal == 0 ? (waitStatus >> 8) & 0xff : -signal
    return Subprocess.Result(status: status, stdout: read(URL(fileURLWithPath: out)),
                             stderr: read(URL(fileURLWithPath: err)))
}

/// A folder holding a `swift` that prints `output` and exits with `status`.
private func fakeSwift(_ tmp: TempDir, output: String, status: Int) -> URL {
    let bin = tmp.mkdir("bin")
    makeExecutable(bin.appendingPathComponent("swift"),
                   "#!/bin/sh\necho '\(output)' >&2\nexit \(status)\n")
    return bin
}

private func git(_ cwd: URL, _ args: String...) -> Subprocess.Result {
    let result = run(["git", "-C", cwd.path] + args)
    #expect(result.status == 0, "git \(args.joined(separator: " ")): \(result.stderr)")
    return result
}

private func head(_ repo: URL) -> String {
    git(repo, "rev-parse", "HEAD").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private let noSwift = "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)"

// MARK: - build.sh

@Test func scriptsAreValidBash() {
    for name in ["build.sh", "install.sh", "uninstall.sh"] {
        let result = run(["bash", "-n", projectDir.appendingPathComponent(name).path])
        #expect(result.status == 0, "\(name): \(result.stderr)")
    }
}

@Test func buildExplainsMissingSwift() {
    let tmp = TempDir()
    let bin = fakeSwift(tmp, output: noSwift, status: 1)

    let result = run(["/bin/bash", projectDir.appendingPathComponent("build.sh").path,
                      "--dest", tmp.url("Apps").path], binDir: bin)

    #expect(result.status != 0)
    #expect(result.stderr.contains("Swift not found: run xcode-select --install"))
    #expect(!FileManager.default.fileExists(atPath: tmp.url("Apps/Claude Tracker.app").path))
}

@Test func buildRefusesSwiftOlderThan5_9() {
    let tmp = TempDir()
    let bin = fakeSwift(tmp, output: "Apple Swift version 5.8.1 (swiftlang-5.8.0.124.5 clang-1403.0.22.11.100)",
                        status: 0)

    let result = run(["/bin/bash", projectDir.appendingPathComponent("build.sh").path,
                      "--dest", tmp.url("Apps").path], binDir: bin)

    #expect(result.status != 0)
    #expect(result.stderr.contains("needs Swift 5.9 or newer, but this Mac has Swift 5.8"))
}

@Test func buildRejectsUnknownOptions() {
    let result = run(["/bin/bash", projectDir.appendingPathComponent("build.sh").path,
                                 "--python", "/usr/bin/python3"])

    #expect(result.status == 2)
    #expect(result.stderr.contains("Unknown option: --python"))
}

/// Copies what build.sh needs into a temp folder, so the test compiles
/// there: `swift test` holds this package's .build folder while it runs.
private func copyOfPackage(_ tmp: TempDir) -> URL {
    let copy = tmp.mkdir("my project")  // a space, to check quoting
    for name in ["Package.swift", "Sources", "Tests", "Resources", "build.sh"] {
        try! FileManager.default.copyItem(at: projectDir.appendingPathComponent(name),
                                          to: copy.appendingPathComponent(name))
    }
    return copy
}

/// True if `path` and `url` name the same file (build.sh writes paths
/// with symlinks resolved: /private/var/... for /var/...).
private func samePath(_ path: String, _ url: URL) -> Bool {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_SLOW_TESTS"] == "1"))
func buildMakesASignedBundle() throws {
    let tmp = TempDir()
    let project = copyOfPackage(tmp)
    let apps = tmp.url("Apps")
    let bundle = apps.appendingPathComponent("Claude Tracker.app")
    let stale = bundle.appendingPathComponent("Contents/stale.txt")
    writeText(stale, "old")

    let result = run(["/bin/bash", project.appendingPathComponent("build.sh").path,
                                 "--dest", apps.path])

    #expect(result.status == 0, "\(result.stderr)")
    let executable = bundle.appendingPathComponent("Contents/MacOS/claude-tracker")
    let lastLine = result.stdout.split(separator: "\n").last.map(String.init) ?? ""
    #expect(samePath(lastLine, executable))
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    #expect(!FileManager.default.fileExists(atPath: stale.path))  // replaced, not merged
    // Nothing left of the temporary folder it was built in.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: apps.path)
    #expect(leftovers == ["Claude Tracker.app"])

    let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil)
                            as? [String: Any])
    #expect(info["CFBundleIdentifier"] as? String == "com.raymondtian.claudetracker")
    #expect(info["CFBundleExecutable"] as? String == "claude-tracker")
    #expect(info["CFBundleName"] as? String == Version.appName)
    #expect(info["CFBundleShortVersionString"] as? String == Version.version)
    #expect(info["CFBundleVersion"] as? String == Version.version)
    #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    #expect(info["CFBundlePackageType"] as? String == "APPL")
    #expect(info["LSMinimumSystemVersion"] as? String == "13.0")
    #expect(info["LSUIElement"] as? Bool == true)
    #expect(info["NSHighResolutionCapable"] as? Bool == true)
    #expect(info["NSHumanReadableCopyright"] as? String
            == "Original app by \(Version.originalAuthor). Redesign and new features by \(Version.forkAuthor).")
    #expect(samePath(info["ClaudeTrackerProjectDir"] as? String ?? "", project))

    let icon = bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")
    #expect(fileSize(icon) > 10_000)

    // macOS refuses notifications unless this matches the bundle's identifier.
    let signature = run(["codesign", "-dv", bundle.path]).stderr
    #expect(signature.contains("Identifier=com.raymondtian.claudetracker\n"))
    #expect(signature.contains("Signature=adhoc"))
    #expect(run(["codesign", "--verify", "--strict", bundle.path]).status == 0)
}

// MARK: - install.sh

@Test func installChecksForSwiftInsteadOfPython() {
    let script = read(projectDir.appendingPathComponent("install.sh"))

    #expect(script.contains("swift --version"))
    #expect(script.contains("xcode-select --install"))
    #expect(script.contains("build.sh"))
    #expect(!script.contains("rumps"))
    #expect(!script.contains("python"))
}

@Test func installKeepsTheSameLaunchAgentButLogsOutsideTheProject() {
    let script = read(projectDir.appendingPathComponent("install.sh"))

    #expect(script.contains("LABEL=\"com.claudetokencounter.menubar\""))
    #expect(script.contains("<string>${APP_EXEC}</string>\n        <string>--foreground</string>"))
    // Logs go to ~/Library/Logs, not the project folder: launchd can't open
    // files in a folder macOS protects (Desktop, Documents, Downloads) and
    // then won't start the app at all (exit 78).
    #expect(script.contains("LOG_DIR=\"$HOME/Library/Logs/ClaudeTracker\""))
    #expect(script.contains("mkdir -p \"$LOG_DIR\""))
    #expect(script.contains("<string>${LOG_DIR}/agent.log</string>"))
    #expect(script.contains("<string>${LOG_DIR}/agent.err.log</string>"))
    #expect(!script.contains("${SCRIPT_DIR}/agent"))
    #expect(script.contains("launchctl bootstrap \"gui/$(id -u)\" \"$PLIST_PATH\""))
}

// MARK: - build_app.py (the stand-in 2.5.0's updater runs)

/// A folder with the real build_app.py and a build.sh that prints its
/// arguments and exits with `status`.
private func shimWithStubBuild(_ tmp: TempDir, status: Int) -> URL {
    let project = tmp.mkdir("proj")
    try! FileManager.default.copyItem(at: projectDir.appendingPathComponent("build_app.py"),
                                      to: project.appendingPathComponent("build_app.py"))
    makeExecutable(project.appendingPathComponent("build.sh"),
                   "#!/bin/bash\necho \"Built it\"\necho \"args: $*\"\nexit \(status)\n")
    return project
}

@Test func shimRunsBuildShWithDestAndIgnoresPython() {
    let tmp = TempDir()
    let project = shimWithStubBuild(tmp, status: 0)

    // Exactly what 2.5.0's updater runs.
    let result = run(["python3", project.appendingPathComponent("build_app.py").path,
                      "--python", "/usr/bin/python3", "--dest", "/some/where"])

    #expect(result.status == 0, "\(result.stderr)")
    #expect(result.stdout == "Built it\nargs: --dest /some/where\n")
}

@Test func shimDefaultsToApplications() {
    let tmp = TempDir()
    let project = shimWithStubBuild(tmp, status: 0)
    let expected = FileManager.default.isWritableFile(atPath: "/Applications")
        ? "/Applications" : NSHomeDirectory() + "/Applications"

    let result = run(["python3", project.appendingPathComponent("build_app.py").path])

    #expect(result.stdout.hasSuffix("args: --dest \(expected)\n"))
}

@Test func shimPassesOnBuildShsExitCode() {
    let tmp = TempDir()
    let project = shimWithStubBuild(tmp, status: 3)

    let result = run(["python3", project.appendingPathComponent("build_app.py").path,
                      "--dest", tmp.url("Apps").path])

    #expect(result.status == 3)
}

@Test func shimKeepsDefaultDestFor2_5_0sApp() {
    // 2.5.0's app.py does `from build_app import default_dest` after the
    // update has replaced build_app.py with this one.
    let script = "import sys; sys.path.insert(0, sys.argv[1]); import build_app; print(build_app.default_dest())"

    let result = run(["python3", "-c", script, projectDir.path])

    #expect(result.status == 0, "\(result.stderr)")
    let expected = FileManager.default.isWritableFile(atPath: "/Applications")
        ? "/Applications" : NSHomeDirectory() + "/Applications"
    #expect(result.stdout == expected + "\n")
}

/// A clone at a "Python" commit (app.py, settings in an untracked
/// state.json, an installed old app), fast-forwarded to a "Swift" commit
/// with the real build.sh and build_app.py, as 2.5.0's updater does. With
/// `fromPython` false, both commits are Swift ones.
private func upgradedClone(_ tmp: TempDir, fromPython: Bool = true)
    -> (repo: URL, before: String, apps: URL) {
    let repo = tmp.mkdir("clone")
    _ = git(repo, "-c", "init.defaultBranch=master", "init", "-q")
    _ = git(repo, "config", "user.email", "t@example.com")
    _ = git(repo, "config", "user.name", "t")
    _ = git(repo, "config", "commit.gpgsign", "false")
    writeText(repo.appendingPathComponent(".gitignore"), "state.json\n")
    writeText(repo.appendingPathComponent(fromPython ? "app.py" : "README.md"), "print('2.5.0')\n")
    writeText(repo.appendingPathComponent("build_app.py"), "# 2.5.0's build_app.py\n")
    _ = git(repo, "add", ".")
    _ = git(repo, "commit", "-q", "-m", "2.5.0")
    let before = head(repo)

    _ = git(repo, "checkout", "-q", "-b", "release")
    if fromPython {
        _ = git(repo, "rm", "-q", "app.py")
    }
    for name in ["build.sh", "build_app.py"] {
        try? FileManager.default.removeItem(at: repo.appendingPathComponent(name))
        try! FileManager.default.copyItem(at: projectDir.appendingPathComponent(name),
                                          to: repo.appendingPathComponent(name))
    }
    _ = git(repo, "add", ".")
    _ = git(repo, "commit", "-q", "-m", "3.0.0")
    _ = git(repo, "tag", "v3.0.0")
    _ = git(repo, "checkout", "-q", "master")

    writeText(repo.appendingPathComponent("state.json"), "{\"title_mode\": \"today\"}")
    _ = git(repo, "merge", "--ff-only", "--quiet", "v3.0.0")
    let apps = tmp.mkdir("Apps")
    writeText(apps.appendingPathComponent("Claude Tracker.app/Contents/old.txt"), "2.5.0")
    return (repo, before, apps)
}

@Test func shimMovesTheCloneBackToPythonWhenTheBuildFails() {
    let tmp = TempDir()
    let (repo, before, apps) = upgradedClone(tmp)
    let bin = fakeSwift(tmp, output: noSwift, status: 1)

    let result = run(["python3", repo.appendingPathComponent("build_app.py").path,
                      "--python", "/usr/bin/python3", "--dest", apps.path], binDir: bin)

    #expect(result.status != 0)  // so 2.5.0 says "rebuilding failed" and doesn't restart
    #expect(result.stderr.contains("xcode-select --install"))
    #expect(result.stderr.contains("moved back to the Python version"))
    #expect(head(repo) == before)
    #expect(read(repo.appendingPathComponent("app.py")) == "print('2.5.0')\n")
    #expect(read(repo.appendingPathComponent("build_app.py")) == "# 2.5.0's build_app.py\n")
    #expect(read(repo.appendingPathComponent("state.json")) == "{\"title_mode\": \"today\"}")
    #expect(git(repo, "status", "--porcelain", "--untracked-files=no").stdout.isEmpty)
    // The installed app wasn't touched.
    #expect(read(apps.appendingPathComponent("Claude Tracker.app/Contents/old.txt")) == "2.5.0")
}

@Test func shimLeavesASwiftCloneAloneWhenTheBuildFails() {
    let tmp = TempDir()
    let (repo, _, apps) = upgradedClone(tmp, fromPython: false)
    let after = head(repo)
    let bin = fakeSwift(tmp, output: noSwift, status: 1)

    let result = run(["python3", repo.appendingPathComponent("build_app.py").path,
                      "--dest", apps.path], binDir: bin)

    #expect(result.status != 0)
    #expect(!result.stderr.contains("moved back"))
    #expect(head(repo) == after)
}

@Test func shimLeavesTheCloneAloneWithoutOrigHead() {
    let tmp = TempDir()
    let (repo, _, apps) = upgradedClone(tmp)
    let after = head(repo)
    try? FileManager.default.removeItem(at: repo.appendingPathComponent(".git/ORIG_HEAD"))
    let bin = fakeSwift(tmp, output: noSwift, status: 1)

    let result = run(["python3", repo.appendingPathComponent("build_app.py").path,
                      "--dest", apps.path], binDir: bin)

    #expect(result.status != 0)
    #expect(head(repo) == after)
    #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("app.py").path))
}
