import Foundation

/// Which expandable rows are open, by row id. The value says whether the
/// row's folder exists (so the detail can offer "Show in Finder"). Kept
/// apart from the views so the rules can be tested.
public enum OpenRows {
    /// Opens a closed row, closes an open one. `fileExists` is injected so
    /// tests need no disk; a row without a path is open with no folder.
    public static func toggle(_ open: inout [String: Bool], id: String, path: String?,
                              fileExists: (String) -> Bool) {
        if open[id] != nil {
            open.removeValue(forKey: id)
            return
        }
        open[id] = path.map(fileExists) ?? false
    }

    /// Forgets rows that are no longer on screen.
    public static func prune(_ open: inout [String: Bool], present: Set<String>) {
        open = open.filter { present.contains($0.key) }
    }
}
