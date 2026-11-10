import Foundation

/// Finds the app's project folder (the git clone with state.json in it)
/// wherever it is. The app's build writes the folder it was built in into its
/// Info.plist, which is wrong as soon as someone moves or renames the folder;
/// this finds it again so saving and updating keep working.
///
/// Order: the folder the app was built in; the place remembered from the last
/// launch; a copy of the project found by searching this Mac; else a folder
/// of the app's own in Application Support.
///
/// Kept free of AppKit so it can be unit-tested.
public enum ProjectLocator {
    public enum Source: Equatable {
        case configured, remembered, found, privateFolder
    }

    public struct Resolution: Equatable {
        public let dir: URL
        public let source: Source
    }

    /// ~/Library/Application Support/Claude Tracker: the pointer file, the
    /// app's own data folder and its own clone live here.
    public static func supportDirectory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Claude Tracker", isDirectory: true)
    }

    private static let pointerName = "project-dir"

    /// Whether `dir` is a copy of this project: the files its build needs.
    public static func isProject(_ dir: String, fileExists: (String) -> Bool) -> Bool {
        ["Package.swift", "build.sh", "Sources/ClaudeTracker/main.swift"].allSatisfy {
            fileExists(dir + "/" + $0)
        }
    }

    /// The folder to use. `search` lists the places the project might be, most
    /// likely first (see `searchMac`). A configured folder that has the
    /// project, or at least a state.json (the totals), is used as it is.
    public static func resolve(configured: URL, pointer: String?, home: String,
                               fileExists: (String) -> Bool,
                               search: (String) -> [String]) -> Resolution {
        let dir = configured.path
        if isProject(dir, fileExists: fileExists) || fileExists(dir + "/state.json") {
            return Resolution(dir: configured, source: .configured)
        }
        if let pointer = pointer, isProject(pointer, fileExists: fileExists) {
            return Resolution(dir: URL(fileURLWithPath: pointer, isDirectory: true), source: .remembered)
        }
        if let found = search(home).first(where: { isProject($0, fileExists: fileExists) }) {
            return Resolution(dir: URL(fileURLWithPath: found, isDirectory: true), source: .found)
        }
        return Resolution(dir: supportDirectory(home: home), source: .privateFolder)
    }

    /// `resolve` for the running app: looks at the real disk, remembers where
    /// it ended up, and makes the app's own folder if it has to use it.
    public static func resolve(configured: URL, home: String = UsageStats.homeDirectory) -> Resolution {
        let result = resolve(configured: configured, pointer: remembered(home: home), home: home,
                             fileExists: { FileManager.default.fileExists(atPath: $0) },
                             search: { searchMac(home: $0) })
        if result.source == .privateFolder {
            try? FileManager.default.createDirectory(at: result.dir, withIntermediateDirectories: true)
        } else {
            remember(result.dir, home: home)
        }
        return result
    }

    // MARK: - The remembered place

    public static func remembered(home: String) -> String? {
        let file = supportDirectory(home: home).appendingPathComponent(pointerName)
        let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Writes where the project is, unless that's what is already there.
    public static func remember(_ dir: URL, home: String) {
        guard remembered(home: home) != dir.path else { return }
        let support = supportDirectory(home: home)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? dir.path.write(to: support.appendingPathComponent(pointerName), atomically: true, encoding: .utf8)
    }

    // MARK: - Searching

    /// Copies of the project on this Mac, most likely first: Spotlight's
    /// `build.sh` files, then the usual places people keep code.
    public static func searchMac(home: String, run: Subprocess.Runner = Subprocess.run) -> [String] {
        var candidates = [String]()
        let spotlight = run(["mdfind", "kMDItemFSName == 'build.sh'"], nil)
        if spotlight.status == 0 {
            for line in spotlight.stdout.split(whereSeparator: \.isNewline) {
                let path = String(line)
                if !path.contains("/.Trash/"), !path.contains("/.build/") {
                    candidates.append(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                }
            }
        }
        candidates += projectsInCommonFolders(home: home)
        return ordered(candidates) { FileManager.default.fileExists(atPath: $0) }
    }

    /// Copies of the project in the folders people keep code in: one level
    /// down in the home folder, and two levels down in the usual places.
    public static func projectsInCommonFolders(home: String) -> [String] {
        let manager = FileManager.default
        func children(_ dir: String) -> [String] {
            ((try? manager.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .map { dir + "/" + $0 }
        }
        func isProject(_ dir: String) -> Bool {
            self.isProject(dir) { manager.fileExists(atPath: $0) }
        }
        var found = [String]()
        found += children(home).filter(isProject)
        for place in ["Desktop", "Documents", "Downloads", "Developer", "Projects", "Code", "GitHub", "Sites"] {
            for child in children(home + "/" + place) {
                if isProject(child) {
                    found.append(child)
                } else {
                    found += children(child).filter(isProject)
                }
            }
        }
        return found
    }

    /// The copies of the project among `paths`, each once: clones before
    /// downloads (only a clone can update itself), newest first.
    public static func ordered(_ paths: [String], fileExists: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        let projects = paths.filter { isProject($0, fileExists: fileExists) && seen.insert($0).inserted }
        func modified(_ dir: String) -> Date {
            let attributes = try? FileManager.default.attributesOfItem(atPath: dir + "/build.sh")
            return (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        return projects.enumerated().sorted { a, b in
            let (aGit, bGit) = (fileExists(a.element + "/.git"), fileExists(b.element + "/.git"))
            if aGit != bGit { return aGit }
            let (aDate, bDate) = (modified(a.element), modified(b.element))
            return aDate != bDate ? aDate > bDate : a.offset < b.offset
        }.map(\.element)
    }
}
