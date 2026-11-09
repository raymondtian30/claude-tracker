import Foundation

/// The Leaderboard's friend codes: each player's numbers live in a secret
/// GitHub Gist, written with their own GitHub token and read by ID.
///
/// The token is kept only in the macOS Keychain. It's written through
/// `security -i` on stdin, so it never appears in a process list.
public enum GistSync {
    public static let keychainService = "com.claudetokencounter.github"
    public static let gistFilename = "claude-token-leaderboard.json"
    public static let apiBase = "https://api.github.com"
    public static let newTokenURL =
        "https://github.com/settings/tokens/new?scopes=gist"
        + "&description=Claude+Token+Counter+Leaderboard"

    /// The token couldn't be stored (Python's CalledProcessError).
    public struct KeychainError: Error, LocalizedError, CustomStringConvertible {
        public let description: String
        public var errorDescription: String? { description }
    }

    /// Read the GitHub token from the macOS Keychain, or nil if never set.
    public static func getGithubToken(run: Subprocess.Runner = Subprocess.run) -> String? {
        let result = run(["security", "find-generic-password", "-s", keychainService, "-w"], nil)
        if result.status != 0 {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Letters, digits, "_", "-" and ".": what GitHub tokens are made of,
    /// and nothing that could add a command to the `security -i` line.
    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// Store the GitHub token in the macOS Keychain, overwriting any existing one.
    ///
    /// The Python app passed the token to `security add-generic-password` as
    /// an argument, where any process list could see it. This sends the same
    /// command on `security -i`'s stdin instead, as Accounts does with API
    /// keys, and checks the Keychain kept it (`security -i` doesn't fail when
    /// one of its commands does).
    public static func setGithubToken(_ token: String, run: Subprocess.Runner = Subprocess.run) throws {
        guard validToken(token) else {
            throw KeychainError(description: "That doesn't look like a GitHub token.")
        }
        _ = run(["security", "-i"],
                "add-generic-password -s \(keychainService) -a \(keychainService) -w \(token) -U\n")
        if getGithubToken(run: run) != token {
            throw KeychainError(description: "The token couldn't be saved to the Keychain.")
        }
    }

    static func apiRequest(_ method: String, _ url: String, token: String? = nil,
                           payload: Any? = nil, send: HTTP.Send) throws -> Any {
        guard let parsed = URL(string: url) else {
            throw HTTP.RefusedURL(description: "not a URL: \(url)")
        }
        var request = URLRequest(url: parsed, timeoutInterval: 10)
        request.httpMethod = method
        if let payload = payload {
            request.httpBody = try JSON.encode(payload)
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try HTTP.json(send(request, true))
    }

    /// `content` as the text stored in the gist's file.
    private static func fileText(_ content: Any) throws -> String {
        String(decoding: try JSON.encode(content), as: UTF8.self)
    }

    /// Create a new secret Gist holding `content`, returning its ID (the friend code).
    public static func createGist(_ token: String, _ content: Any,
                                  send: HTTP.Send = HTTP.send) throws -> String {
        let payload: JSONObject = [
            "description": "Claude Tracker leaderboard entry",
            "public": false,
            "files": [gistFilename: ["content": try fileText(content)]],
        ]
        let result = try apiRequest("POST", "\(apiBase)/gists", token: token, payload: payload, send: send)
        guard let id = JSON.object(result)?.string("id") else {
            throw HTTP.UnexpectedAnswer(description: "no gist id in the answer")
        }
        return id
    }

    /// Overwrite the leaderboard file in an existing Gist you own.
    public static func updateGist(_ token: String, _ gistID: String, _ content: Any,
                                  send: HTTP.Send = HTTP.send) throws {
        let payload: JSONObject = ["files": [gistFilename: ["content": try fileText(content)]]]
        _ = try apiRequest("PATCH", "\(apiBase)/gists/\(gistID)", token: token, payload: payload, send: send)
    }

    /// Read a friend's leaderboard entry. No token needed -- gists are readable by ID.
    public static func fetchGist(_ gistID: String, send: HTTP.Send = HTTP.send) throws -> Any {
        let result = try apiRequest("GET", "\(apiBase)/gists/\(gistID)", send: send)
        guard let rawContent = JSON.object(result)?.object("files")?.object(gistFilename)?.string("content")
        else { throw HTTP.UnexpectedAnswer(description: "no leaderboard file in the gist") }
        return try HTTP.json(Data(rawContent.utf8))
    }
}
