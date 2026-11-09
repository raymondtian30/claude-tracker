// Ported from tests/test_updater.py, test for test.
//
// The clone fixtures run the real git on folders in a temp dir: the
// "GitHub" repo is a local folder, so nothing goes over the network.
// The real-git installs also run the real `swift --version` preflight,
// which passes wherever these tests can run.
//
// test_about_has_check_for_updates tests stats_tabs' settings tab, so it's
// ported with the panel model's tests, not here.

import Foundation
import Testing
@testable import TrackerCore

@Test func parseVersion() {
    #expect(Updater.parseVersion("v2.1.0")! == (2, 1, 0))
    #expect(Updater.parseVersion("2.10.3")! == (2, 10, 3))
    #expect(Updater.parseVersion("nightly") == nil)
    #expect(Updater.parseVersion(nil) == nil)
}

@Test func isNewerComparesNumbersNotText() {
    #expect(Updater.isNewer("v2.10.0", current: "2.9.0"))
    #expect(!Updater.isNewer("v2.1.0", current: "2.1.0"))
    #expect(!Updater.isNewer("v2.0.5", current: "2.1.0"))
    #expect(!Updater.isNewer("garbage", current: "2.1.0"))
}

/// Runs git in `cwd`, failing the test if it fails.
private func git(_ cwd: URL, _ args: String...) {
    let result = Subprocess.run(["git", "-C", cwd.path] + args)
    #expect(result.status == 0, "git \(args.joined(separator: " ")): \(result.stderr)")
}

private func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

/// A 'GitHub' repo with a v2.2.0 release one commit ahead, and a clone
/// of it still at the older commit, with settings in a gitignored file.
private func makeClone() -> (remote: URL, local: URL) {
    let tmp = TempDir()
    let remote = tmp.mkdir("remote")
    git(remote, "init", "-q", "-b", "master")
    git(remote, "config", "user.email", "t@example.com")
    git(remote, "config", "user.name", "t")
    writeText(remote.appendingPathComponent(".gitignore"), "state.json\n")
    writeText(remote.appendingPathComponent("version.py"), "__version__ = \"2.1.0\"\n")
    git(remote, "add", ".")
    git(remote, "commit", "-q", "-m", "2.1.0")
    let local = tmp.url("local")
    git(tmp.root, "clone", "-q", remote.path, local.path)
    writeText(remote.appendingPathComponent("version.py"), "__version__ = \"2.2.0\"\n")
    git(remote, "commit", "-q", "-am", "2.2.0")
    git(remote, "tag", "v2.2.0")
    writeText(local.appendingPathComponent("state.json"), "{\"title_mode\": \"today\"}")
    return (remote, local)
}

@Test func installReleaseFastForwardsAndKeepsSettings() throws {
    let (remote, local) = makeClone()

    try Updater.installRelease("v2.2.0", projectDir: local.path, repoURL: remote.path)

    #expect(read(local.appendingPathComponent("version.py")) == "__version__ = \"2.2.0\"\n")
    #expect(read(local.appendingPathComponent("state.json")) == "{\"title_mode\": \"today\"}")
}

/// Expects `body` to throw an UpdateError whose text contains `match`.
private func expectUpdateError(_ match: String, _ body: () throws -> Void,
                               sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try body()
        Issue.record("no UpdateError", sourceLocation: sourceLocation)
    } catch let error as Updater.UpdateError {
        #expect(error.description.contains(match), "\(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

@Test func installReleaseLeavesLocalChangesAlone() {
    let (remote, local) = makeClone()
    writeText(local.appendingPathComponent("version.py"), "# my edit\n")

    expectUpdateError("local changes") {
        try Updater.installRelease("v2.2.0", projectDir: local.path, repoURL: remote.path)
    }

    #expect(read(local.appendingPathComponent("version.py")) == "# my edit\n")
}

@Test func installReleaseOnlyFromMaster() {
    let (remote, local) = makeClone()
    git(local, "checkout", "-q", "-b", "my-feature")

    expectUpdateError("branch \"my-feature\"") {
        try Updater.installRelease("v2.2.0", projectDir: local.path, repoURL: remote.path)
    }
}

@Test func installReleaseWontDropLocalCommits() {
    let (remote, local) = makeClone()
    git(local, "config", "user.email", "t@example.com")
    git(local, "config", "user.name", "t")
    writeText(local.appendingPathComponent("mine.txt"), "x")
    git(local, "add", "mine.txt")
    git(local, "commit", "-q", "-m", "mine")

    expectUpdateError("commits that aren't in v2.2.0") {
        try Updater.installRelease("v2.2.0", projectDir: local.path, repoURL: remote.path)
    }

    #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("mine.txt").path))
}

@Test func installReleaseOutsideAGitClone() {
    let tmp = TempDir()
    expectUpdateError("isn't a git clone") {
        try Updater.installRelease("v2.2.0", projectDir: tmp.path, repoURL: "unused")
    }
}

/// A fake runner: git succeeds on master; `swift --version` answers `swift`
/// (status, output).
private final class FakeRun {
    var calls: [[String]] = []
    let swift: Subprocess.Result

    init(swift: Subprocess.Result = Subprocess.Result(
        status: 0, stdout: "swift-driver version: 1.120.5 Apple Swift version 6.1 "
            + "(swiftlang-6.1.0.110.21 clang-1700.0.13.3)\nTarget: arm64-apple-macosx15.0\n")) {
        self.swift = swift
    }

    func run(_ args: [String], _ input: String?) -> Subprocess.Result {
        calls.append(args)
        if args.first == "swift" {
            return swift
        }
        return Subprocess.Result(status: 0, stdout: args.contains("rev-parse") ? "master\n" : "")
    }
}

@Test func installReleaseFetchesFromThisAppsRepo() throws {
    let fake = FakeRun()

    try Updater.installRelease("v2.2.0", run: fake.run, projectDir: "/p")

    let fetch = try #require(fake.calls.first { $0.contains("fetch") })
    #expect(fetch.contains("https://github.com/raymondtian30/claude-tracker.git"))
    #expect(fetch.contains("+refs/tags/v2.2.0:refs/tags/v2.2.0"))
}

@Test func restartWaitsForTheAppToQuitThenStartsIt() {
    let command = Updater.restartCommand(123, "/Applications/Claude Tracker.app", "gui/501/x")

    #expect(command.hasPrefix("while kill -0 123 "))
    #expect(command.contains("launchctl kickstart gui/501/x"))
    #expect(command.contains("open '/Applications/Claude Tracker.app'"))
}

private let RELEASES: [JSONObject] = [  // as GitHub lists them: newest first
    ["tag_name": "v2.3.0", "name": "Claude Tracker 2.3.0", "draft": false, "prerelease": false,
     "body": "## New\n\n- **Update dialog.** Lists what's new.\n"],
    ["tag_name": "v2.4.0-beta", "name": "beta", "draft": false, "prerelease": true, "body": "x"],
    ["tag_name": "v2.2.2", "name": "Claude Tracker 2.2.2", "draft": false, "prerelease": false,
     "body": "## Fixed\n\n- Notifications show."],
    ["tag_name": "v9.0.0", "name": "draft", "draft": true, "prerelease": false, "body": "x"],
    ["tag_name": "v2.2.1", "name": "Claude Tracker 2.2.1", "draft": false, "prerelease": false,
     "body": "old"],
]

@Test func newerReleasesListsEveryPublishedReleaseAfterThisOne() throws {
    var seen: [String] = []
    let get: Updater.Get = { url in
        seen.append(url)
        return RELEASES
    }

    let releases = try Updater.newerReleases(get: get, current: "2.2.1")

    #expect(seen == [Updater.releasesURL])
    #expect(releases.map(\.tag) == ["v2.3.0", "v2.2.2"])  // newest first
    #expect(releases[0].notes == "## New\n\n- **Update dialog.** Lists what's new.")
}

@Test func newerReleasesWhenUpToDateOrOffline() throws {
    #expect(try Updater.newerReleases(get: { _ in RELEASES }, current: "2.3.0") == [])

    let offline: Updater.Get = { _ in throw HTTP.ConnectionError(reason: "no network") }

    expectUpdateError("Couldn't reach GitHub") {
        _ = try Updater.newerReleases(get: offline)
    }
}

@Test func releaseNotesReadAsPlainText() {
    let text = Updater.describeReleases([
        Updater.Release(tag: "v2.3.0", notes: "## New\n\n- **Update dialog.** Lists what's new.\n"),
        Updater.Release(tag: "v2.2.2", notes: ""),
    ])

    #expect(text == "Version 2.3.0\nNew\n• Update dialog. Lists what's new.\n\n"
        + "Version 2.2.2\nNo notes.")
}

// MARK: - New in the Swift app: the preflight and build.sh

@Test func preflightFailsWithoutSwiftAndMergesNothing() {
    let fake = FakeRun(swift: Subprocess.Result(status: 127, stderr: "swift: command not found"))

    expectUpdateError("xcode-select --install") {
        try Updater.installRelease("v2.2.0", run: fake.run, projectDir: "/p")
    }

    #expect(!fake.calls.contains { $0.contains("merge") || $0.contains("fetch") })
}

@Test func preflightFailsOnSwiftOlderThan59() {
    let fake = FakeRun(swift: Subprocess.Result(
        status: 0, stdout: "Apple Swift version 5.8.1 (swiftlang-5.8.0.124.5 clang-1403.0.22.11.100)\n"))

    expectUpdateError("this Mac has Swift 5.8") {
        try Updater.installRelease("v2.2.0", run: fake.run, projectDir: "/p")
    }

    #expect(!fake.calls.contains { $0.contains("merge") || $0.contains("fetch") })
    #expect(fake.calls.contains(["swift", "--version"]))
}

@Test func preflightPassesOnSwift59AndNewer() throws {
    for output in ["Apple Swift version 5.9 (swift-5.9-RELEASE)\n",
                   "swift-driver version: 1.87.1 Apple Swift version 5.10 (swiftlang-5.10.0.13)\n",
                   "Apple Swift version 6.3 (swiftlang-6.3.0.1)\n"] {
        try Updater.preflight(run: { _, _ in Subprocess.Result(status: 0, stdout: output) })
    }
    expectUpdateError("Couldn't tell which Swift") {
        try Updater.preflight(run: { _, _ in Subprocess.Result(status: 0, stdout: "something else") })
    }
}

@Test func rebuildRunsBuildShIntoTheBundlesFolder() throws {
    var calls: [[String]] = []

    try Updater.rebuildBundle("/Applications", run: { args, _ in
        calls.append(args)
        return Subprocess.Result(status: 0, stdout: "/Applications/Claude Tracker.app/Contents/MacOS/claude-tracker\n")
    }, projectDir: "/Users/me/claude-tracker")

    #expect(calls == [["/Users/me/claude-tracker/build.sh", "--dest", "/Applications"]])

    expectUpdateError("rebuilding the app failed") {
        try Updater.rebuildBundle("/Applications", run: { _, _ in Subprocess.Result(status: 1) },
                                  projectDir: "/p")
    }
}

// Not in the Python tests: shlex.quote's rules and the releases request.
@Test func shellQuoteMatchesShlex() {
    #expect(Updater.shellQuote("") == "''")
    #expect(Updater.shellQuote("gui/501/com.x") == "gui/501/com.x")
    #expect(Updater.shellQuote("it's here") == "'it'\"'\"'s here'")
}

@Test func releasesRequestHeaders() throws {
    var sent: [(URLRequest, Bool)] = []
    _ = try Updater.httpGetJSON(Updater.releasesURL, send: { request, follow in
        sent.append((request, follow))
        return Data("[]".utf8)
    })

    let (request, followRedirects) = try #require(sent.first)
    #expect(followRedirects)
    #expect(request.timeoutInterval == 20)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeTracker/\(Version.version)")
}
