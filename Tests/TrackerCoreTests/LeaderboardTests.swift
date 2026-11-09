// Ported from tests/test_leaderboard.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

@Test func loadFriendsReturnsEmptyListWhenFileMissing() throws {
    let dir = TempDir()
    #expect(try Leaderboard.loadFriends(dir.url("friends.json")).isEmpty)
}

@Test func saveThenLoadFriendsRoundTrips() throws {
    let friendsFile = TempDir().url("friends.json")
    let friends: [JSONObject] = [["name": "Alice", "total_tokens": 10, "yesterday_tokens": 1]]

    try Leaderboard.saveFriends(friends, friendsFile)

    #expect(jsonEqual(try Leaderboard.loadFriends(friendsFile), friends))
    #expect(jsonEqual(JSON.parse(try Data(contentsOf: friendsFile)), friends))
}

private let FRIENDS: [JSONObject] = [
    ["name": "Alice", "total_tokens": 10, "yesterday_tokens": 100],
    ["name": "Bob", "total_tokens": 50, "yesterday_tokens": 1],
]

@Test func sortedFriendsByTotalDescending() {
    let result = Leaderboard.sortedFriends(FRIENDS, by: "total")

    #expect(result.map { $0.string("name") } == ["Bob", "Alice"])
}

@Test func sortedFriendsByDayDescending() {
    let result = Leaderboard.sortedFriends(FRIENDS, by: "day")

    #expect(result.map { $0.string("name") } == ["Alice", "Bob"])
}

@Test func sortedFriendsMissingMetricDefaultsToZero() {
    let friends: [JSONObject] = [["name": "Alice"], ["name": "Bob", "total_tokens": 5]]

    let result = Leaderboard.sortedFriends(friends, by: "total")

    #expect(result.map { $0.string("name") } == ["Bob", "Alice"])
}
