// Ported from tests/test_gist_sync.py, test for test.
//
// The Python tests monkeypatched subprocess.run and urllib.request.urlopen;
// here the fakes are passed in as `run` and `send`.
//
// One deliberate change: Python passed the GitHub token to `security` as an
// argument. The Swift app writes it through `security -i` on stdin, as
// Accounts does with API keys, so setGithubTokenCallsSecurityAddGenericPassword
// checks the same command arrives on stdin and the token isn't in the
// arguments.

import Foundation
import Testing
@testable import TrackerCore

@Test func getGithubTokenReturnsNilWhenNotSet() {
    #expect(GistSync.getGithubToken(run: { _, _ in Subprocess.Result(status: 1, stdout: "") }) == nil)
}

@Test func getGithubTokenReturnsStoredValue() {
    #expect(GistSync.getGithubToken(run: { _, _ in Subprocess.Result(status: 0, stdout: "ghp_abc123\n") })
        == "ghp_abc123")
}

@Test func setGithubTokenCallsSecurityAddGenericPassword() throws {
    var calls: [([String], String?)] = []
    let run: Subprocess.Runner = { args, input in
        calls.append((args, input))
        return Subprocess.Result(status: 0, stdout: args[1] == "find-generic-password" ? "ghp_xyz\n" : "")
    }

    try GistSync.setGithubToken("ghp_xyz", run: run)

    #expect(calls.first?.0 == ["security", "-i"])
    #expect(calls.first?.1 == [
        "add-generic-password",
        "-s",
        GistSync.keychainService,
        "-a",
        GistSync.keychainService,
        "-w",
        "ghp_xyz",
        "-U",
    ].joined(separator: " ") + "\n")
    #expect(!calls.flatMap(\.0).contains("ghp_xyz"))
    // Then it reads the token back to check the Keychain kept it.
    #expect(calls.dropFirst().map(\.0) == [
        ["security", "find-generic-password", "-s", GistSync.keychainService, "-w"],
    ])
}

// Not in the Python tests: what replaces check=True, and a token that could
// add a command to the `security -i` line.
@Test func setGithubTokenFailsIfKeychainDidNotStoreItOrTokenIsMalformed() {
    #expect(throws: GistSync.KeychainError.self) {
        try GistSync.setGithubToken("ghp_xyz", run: { _, _ in Subprocess.Result(status: 44) })
    }
    #expect(throws: GistSync.KeychainError.self) {
        try GistSync.setGithubToken("ghp_x\ndelete-generic-password -s x", run: { _, _ in
            Issue.record("ran")
            return Subprocess.Result()
        })
    }
}

/// A fake `send` that records each request and answers `payload` as JSON.
private final class FakeSend {
    var requests: [URLRequest] = []
    var followRedirects: [Bool] = []
    let payload: Any

    init(_ payload: Any) {
        self.payload = payload
    }

    func send(_ request: URLRequest, _ follow: Bool) throws -> Data {
        requests.append(request)
        followRedirects.append(follow)
        return try JSON.encode(payload)
    }
}

@Test func createGistReturnsID() throws {
    let fake = FakeSend(["id": "abc123"])

    let gistID = try GistSync.createGist("token123", ["name": "Alice", "total_tokens": 5] as JSONObject,
                                         send: fake.send)

    let request = try #require(fake.requests.first)
    #expect(gistID == "abc123")
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "\(GistSync.apiBase)/gists")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token123")
    let body = JSON.parseObject(request.httpBody ?? Data()) ?? [:]
    #expect(body.bool("public") == false)
    let storedContent = JSON.parse(Data((dig(body, "files", GistSync.gistFilename, "content") as? String
        ?? "").utf8))
    #expect(jsonEqual(storedContent, ["name": "Alice", "total_tokens": 5]))
}

@Test func updateGistPatchesCorrectURL() throws {
    let fake = FakeSend(JSONObject())

    try GistSync.updateGist("token123", "abc123", ["name": "Alice"] as JSONObject, send: fake.send)

    let request = try #require(fake.requests.first)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.absoluteString == "\(GistSync.apiBase)/gists/abc123")
}

@Test func fetchGistParsesFileContentWithoutAuth() throws {
    let fake = FakeSend([
        "files": [
            GistSync.gistFilename: [
                "content": String(decoding: try JSON.encode(["name": "Bob", "total_tokens": 9]),
                                  as: UTF8.self)
            ]
        ]
    ])

    let content = try GistSync.fetchGist("abc123", send: fake.send)

    #expect(jsonEqual(content, ["name": "Bob", "total_tokens": 9]))
    #expect(fake.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
}

// Not in the Python tests: urlopen's timeout and the Accept header.
@Test func gistRequestsUseGitHubsJSONTypeAndATenSecondTimeout() throws {
    let fake = FakeSend(["id": "abc123"])

    _ = try GistSync.createGist("token123", ["name": "Alice"] as JSONObject, send: fake.send)

    let request = try #require(fake.requests.first)
    #expect(request.timeoutInterval == 10)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
}
