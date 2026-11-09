// Test helpers shared by every suite: temporary folders (pytest's
// tmp_path), JSONL fixtures, file times, and comparing JSON values the way
// Python's == does.

import Foundation
@testable import TrackerCore

/// A fresh folder for one test, like pytest's `tmp_path`.
///
/// It isn't removed when the test ends: Swift may release a local as soon
/// as its last use, which would delete files a test still reads. Instead
/// each run's folders live under one parent, and parents left by runs more
/// than an hour old are removed when the next run starts.
final class TempDir {
    let root: URL

    init() {
        root = TempDir.runRoot.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private static let prefix = "TrackerCoreTests-"

    private static let runRoot: URL = {
        let temp = FileManager.default.temporaryDirectory
        removeOldRuns(in: temp)
        return temp.appendingPathComponent(prefix + UUID().uuidString)
    }()

    private static func removeOldRuns(in temp: URL) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let folder = temp.appendingPathComponent(name)
            let modified = (try? manager.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
            if let modified = modified, modified < Date().addingTimeInterval(-3600) {
                try? manager.removeItem(at: folder)
            }
        }
    }

    var path: String { root.path }

    /// `tmp_path / "a" / "b.jsonl"` as `dir.url("a/b.jsonl")`.
    func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    /// Makes the folder `relative` (and its parents); returns its URL.
    @discardableResult
    func mkdir(_ relative: String) -> URL {
        let folder = url(relative)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// One compact JSON line, newline included, as the fixtures write them.
func jsonLine(_ entry: JSONObject) -> String {
    String(decoding: try! JSON.encode(entry), as: UTF8.self) + "\n"
}

/// Writes `entries` to `url` as JSON lines, replacing the file.
func writeJSONL(_ url: URL, _ entries: [JSONObject]) {
    writeText(url, entries.map(jsonLine).joined())
}

/// Adds JSON lines to the end of `url`.
func appendJSONL(_ url: URL, _ entries: [JSONObject]) {
    appendText(url, entries.map(jsonLine).joined())
}

func writeText(_ url: URL, _ text: String) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

func appendText(_ url: URL, _ text: String) {
    let handle = try! FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data(text.utf8))
}

func fileSize(_ url: URL) -> Int {
    (try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
}

/// Python's `os.utime(path, (t, t))`.
func setModificationTime(_ url: URL, _ timestamp: Double) {
    try! FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: url.path)
}

/// Python's `==` on JSON values (1 == 1.0, dict order ignored).
func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
    JSON.isEqual(a, b)
}

/// `value[k1][k2]...` through nested JSON objects.
func dig(_ value: Any?, _ keys: String...) -> Any? {
    keys.reduce(value) { JSON.object($0)?[$1] }
}
