import Foundation

/// Check for Updates: list the GitHub releases newer than this copy, and
/// install the newest one over it if the user says so.
///
/// The app runs straight from this git clone, so updating is a fast-forward
/// to the release's tag, then rebuilding the app bundle. Settings and totals
/// (state.json, friends.json) are gitignored, so they stay as they are.
///
/// It won't update a copy that has local code changes or is on a branch other
/// than master, so nobody's own work is ever overwritten. Nor will it update
/// when this Mac can't build the new version (no Swift, or older than 5.9):
/// that's checked before anything is merged.
///
/// Kept free of AppKit so it can be unit-tested.
public enum Updater {
    public static let releasesURL = "https://api.github.com/repos/raymondtian30/claude-tracker/releases?per_page=30"
    public static let updateBranches: Set<String> = ["master", "main"]
    /// The oldest Swift that builds the app (Package.swift's tools version).
    public static let minimumSwift = (5, 9)

    /// Why this copy wasn't updated, in words for the user.
    public struct UpdateError: Error, LocalizedError, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
        public var errorDescription: String? { description }
    }

    /// A published release: its tag and its notes (GitHub Markdown).
    public struct Release: Equatable {
        public let tag: String
        public let notes: String

        public init(tag: String, notes: String) {
            self.tag = tag
            self.notes = notes
        }
    }

    /// Fetches a URL's JSON.
    public typealias Get = (_ url: String) throws -> Any

    // MARK: - Versions

    /// "v2.1.0" or "2.1.0" -> (2, 1, 0); nil if it isn't one.
    public static func parseVersion(_ text: String?) -> (Int, Int, Int)? {
        var rest = Substring((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.hasPrefix("v") {
            rest = rest.dropFirst()
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        return (numbers[0], numbers[1], numbers[2])
    }

    public static func isNewer(_ tag: String?, current: String = Version.version) -> Bool {
        guard let latest = parseVersion(tag), let installed = parseVersion(current) else { return false }
        return latest > installed
    }

    // MARK: - Releases

    public static func httpGetJSON(_ url: String, send: HTTP.Send = HTTP.send) throws -> Any {
        guard let parsed = URL(string: url) else {
            throw HTTP.RefusedURL(description: "not a URL: \(url)")
        }
        var request = URLRequest(url: parsed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeTracker/\(Version.version)", forHTTPHeaderField: "User-Agent")
        return try HTTP.json(send(request, true))
    }

    /// Every published release newer than `current`, newest first. Drafts
    /// and pre-releases are skipped. Throws UpdateError if GitHub can't be
    /// reached or answers oddly.
    public static func newerReleases(get: Get = { try httpGetJSON($0) },
                                     current: String = Version.version) throws -> [Release] {
        let listed: Any
        do {
            listed = try get(releasesURL)
        } catch {  // offline, rate limited, bad JSON...
            throw UpdateError("Couldn't reach GitHub to check for updates.")
        }
        guard let list = listed as? [Any] else {
            throw UpdateError("GitHub sent an unexpected answer.")
        }
        let releases = list.compactMap { item -> Release? in
            guard let release = JSON.object(item), !JSON.truthy(release["draft"]),
                  !JSON.truthy(release["prerelease"]),
                  let tag = release.string("tag_name"), isNewer(tag, current: current)
            else { return nil }
            let notes = (release["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Release(tag: tag, notes: notes)
        }
        // Newest first; equal versions keep GitHub's order, as Python's stable sort does.
        return releases.enumerated().sorted { a, b in
            let first = parseVersion(a.element.tag)!
            let second = parseVersion(b.element.tag)!
            return first != second ? first > second : a.offset < b.offset
        }.map(\.element)
    }

    /// Release notes (GitHub Markdown) as plain lines for a dialog.
    static func plain(_ notes: String) -> [String] {
        var lines: [String] = []
        for raw in notes.split(whereSeparator: { $0.isNewline }) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#") {
                line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            lines.append(line)
        }
        return lines
    }

    /// What's new in each of `releases`, newest first, for the update dialog.
    public static func describeReleases(_ releases: [Release]) -> String {
        releases.map { release in
            let version = String(release.tag.drop(while: { $0 == "v" }))
            let notes = plain(release.notes)
            return (["Version \(version)"] + (notes.isEmpty ? ["No notes."] : notes)).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - Installing

    private static func git(_ run: Subprocess.Runner, _ projectDir: String,
                            _ args: String...) -> Subprocess.Result {
        run(["git", "-C", projectDir] + args, nil)
    }

    /// The Swift version `swift --version` reports, e.g. (6, 1); nil if it
    /// doesn't say.
    static func swiftVersion(_ output: String) -> (Int, Int)? {
        guard let range = output.range(of: "Swift version ") else { return nil }
        let numbers = output[range.upperBound...].prefix { $0.isNumber || $0 == "." }
            .split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    /// Checks this Mac can build the new version before anything is merged:
    /// `swift` must run and be 5.9 or newer. Throws UpdateError otherwise.
    public static func preflight(run: Subprocess.Runner = Subprocess.run) throws {
        let result = run(["swift", "--version"], nil)
        guard result.status == 0 else {
            throw UpdateError("Updating needs Swift 5.9 or newer, from Xcode's Command Line Tools, "
                              + "so the app wasn't updated. Run xcode-select --install in Terminal, "
                              + "then try again.")
        }
        guard let version = swiftVersion(result.stdout + "\n" + result.stderr) else {
            throw UpdateError("Couldn't tell which Swift version this Mac has, so the app wasn't updated. "
                              + "Run ./install.sh to update.")
        }
        if version < minimumSwift {
            throw UpdateError("Updating needs Swift 5.9 or newer, but this Mac has Swift "
                              + "\(version.0).\(version.1), so the app wasn't updated. "
                              + "Update Xcode's Command Line Tools in Software Update, then try again.")
        }
    }

    /// Fast-forward this clone to `tag`. Throws UpdateError, leaving the
    /// code as it was, if that isn't safe or doesn't work.
    public static func installRelease(_ tag: String, run: Subprocess.Runner = Subprocess.run,
                                      projectDir: String,
                                      repoURL: String = "\(Version.repoURL).git") throws {
        let status = git(run, projectDir, "status", "--porcelain", "--untracked-files=no")
        if status.status != 0 {
            throw UpdateError("This copy of the app isn't a git clone, so it can't update itself. "
                              + "Download it again from GitHub.")
        }
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw UpdateError("The app's code has local changes, so it wasn't updated.")
        }
        let branch = git(run, projectDir, "rev-parse", "--abbrev-ref", "HEAD")
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !updateBranches.contains(branch) {
            throw UpdateError("This copy is on the branch \"\(branch)\", so it wasn't updated. "
                              + "Switch to master to get updates.")
        }
        // Before downloading or merging anything: a release this Mac can't
        // build would leave the code updated and the app not.
        try preflight(run: run)
        let fetched = git(run, projectDir, "fetch", "--quiet", "--no-tags", repoURL,
                          "+refs/tags/\(tag):refs/tags/\(tag)")
        if fetched.status != 0 {
            throw UpdateError("Couldn't download the update from GitHub.")
        }
        let merged = git(run, projectDir, "merge", "--ff-only", "--quiet", tag)
        if merged.status != 0 {
            throw UpdateError("This copy has commits that aren't in \(tag), so it wasn't updated.")
        }
    }

    /// Rebuild "Claude Tracker.app" from the updated code, where it is now:
    /// `<project>/build.sh --dest <bundleDir>`.
    public static func rebuildBundle(_ bundleDir: String, run: Subprocess.Runner = Subprocess.run,
                                     projectDir: String) throws {
        let script = URL(fileURLWithPath: projectDir).appendingPathComponent("build.sh").path
        let built = run([script, "--dest", bundleDir], nil)
        if built.status != 0 {
            throw UpdateError("The update was downloaded, but rebuilding the app failed. "
                              + "Run ./install.sh to finish.")
        }
    }

    /// A shell command that waits for `pid` to quit, then starts the app
    /// again: through its LaunchAgent if it has one, else by opening it.
    public static func restartCommand(_ pid: Int, _ bundle: String, _ serviceTarget: String) -> String {
        "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; "
            + "launchctl kickstart \(shellQuote(serviceTarget)) 2>/dev/null || open \(shellQuote(bundle))"
    }

    /// Python's `shlex.quote`.
    static func shellQuote(_ text: String) -> String {
        if text.isEmpty {
            return "''"
        }
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-".utf8)
        if text.utf8.allSatisfy({ safe.contains($0) }) {
            return text
        }
        return "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
