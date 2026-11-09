// Which expandable rows are open, and the toggle rules (3.1 foundation).

import Foundation
import Testing
@testable import TrackerCore

@Test func openRowsToggleUsesInjectedFileExists() {
    var open: [String: Bool] = [:]
    OpenRows.toggle(&open, id: "a", path: "/x/yes", fileExists: { $0 == "/x/yes" })
    #expect(open == ["a": true])
    OpenRows.toggle(&open, id: "a", path: "/x/yes", fileExists: { _ in true })
    #expect(open.isEmpty)

    OpenRows.toggle(&open, id: "b", path: "/x/no", fileExists: { _ in false })
    #expect(open == ["b": false])
    OpenRows.toggle(&open, id: "c", path: nil, fileExists: { _ in true })
    #expect(open["c"] == false)
}

@Test func pruneDropsUnknownIds() {
    var open: [String: Bool] = ["a": true, "b": false, "c": true]
    OpenRows.prune(&open, present: ["a", "c", "z"])
    #expect(open == ["a": true, "c": true])
}
