import Foundation

/// The Leaderboard's friends list, kept in friends.json in the project folder.
public enum Leaderboard {
    /// BETA: friend syncing isn't implemented yet -- this just reads a local
    /// JSON file of {"name", "total_tokens", "yesterday_tokens"} entries that
    /// something else will need to populate later.
    public static func loadFriends(_ friendsFile: URL) throws -> [JSONObject] {
        guard let value = try JSON.read(friendsFile) else { return [] }
        guard let friends = value as? [JSONObject] else {
            throw JSON.InvalidValue(description: "\(friendsFile.path) doesn't hold a list of friends")
        }
        return friends
    }

    public static func saveFriends(_ friends: [JSONObject], _ friendsFile: URL) throws {
        try JSON.write(friends, to: friendsFile)
    }

    /// `by` is "total" or "day" -- sorts highest usage first. Friends with
    /// equal numbers keep their order, as Python's stable sort does.
    public static func sortedFriends(_ friends: [JSONObject], by: String = "total") -> [JSONObject] {
        let key = by == "total" ? "total_tokens" : "yesterday_tokens"
        return friends.enumerated().sorted { a, b in
            let first = a.element.double(key) ?? 0
            let second = b.element.double(key) ?? 0
            return first != second ? first > second : a.offset < b.offset
        }.map(\.element)
    }
}
