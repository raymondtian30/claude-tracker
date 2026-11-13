import Foundation

/// Claude Code's plan limits as percentages, from Anthropic.
///
/// Claude Code only logs a limit once it's reached, so the real percentages
/// (5-hour and weekly) come from the same endpoint Claude Code's `/usage`
/// command reads, signed in with Claude Code's own saved sign-in.
///
/// Privacy:
/// - The sign-in is read from the macOS Keychain item Claude Code keeps
///   ("Claude Code-credentials") each time and never stored, logged or
///   written to state.json.
/// - It's sent only over HTTPS, only to api.anthropic.com, and redirects are
///   not followed.
/// - The app never renews the sign-in itself: renewing replaces Claude Code's
///   saved sign-in, which could sign Claude Code out. Claude Code renews it
///   while you use it.
/// - Only the usage percentages and reset times are requested.
///
/// The endpoint isn't documented, so any answer that doesn't look as expected
/// reads as "unavailable" rather than wrong numbers.
///
/// Kept free of AppKit so it can be unit-tested.
public enum ClaudeUsage {
    public static let keychainService = "Claude Code-credentials"
    public static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    public static let allowedHost = "api.anthropic.com"
    public static let refreshSeconds = 5.0 * 60

    /// One of Anthropic's limits, as the app names and shows it.
    struct LimitName {
        let name: String    // Anthropic's name in the answer
        let kind: String    // alert id suffix
        let window: String  // app window
        let label: String
    }

    // Anthropic's names for its limits -> (alert id suffix, app window, label).
    static let limits = [
        LimitName(name: "five_hour", kind: "five_hour", window: "five_hour", label: "5-hour"),
        LimitName(name: "seven_day", kind: "weekly", window: "weekly", label: "Weekly"),
        LimitName(name: "seven_day_opus", kind: "weekly_opus", window: "weekly", label: "Weekly · Opus"),
        LimitName(name: "seven_day_sonnet", kind: "weekly_sonnet", window: "weekly",
                  label: "Weekly · Sonnet"),
    ]

    public static let offline = "Couldn't reach server. Percentage unavailable."
    public static let signedOut = "Sign in to Claude Code to see percentages."
    public static let expired = "Claude Code's sign-in has expired. Open Claude Code to refresh it."

    /// Fetches the usage answer for a URL, sending `token`.
    public typealias Get = (_ url: String, _ token: String) throws -> Any

    /// Claude Code's access token from the Keychain: (token, error).
    public static func loadToken(run: Subprocess.Runner = Subprocess.run,
                                 now: Double? = nil) -> (token: String?, error: String?) {
        let result = run(["security", "find-generic-password", "-s", keychainService, "-w"], nil)
        if result.status != 0 {
            return (nil, signedOut)
        }
        guard let stored = JSON.parseObject(Data(result.stdout.utf8)),
              let oauth = stored.object("claudeAiOauth"),
              let token = oauth.string("accessToken")
        else { return (nil, signedOut) }
        let expiresAt = oauth.double("expiresAt") ?? 0  // milliseconds
        if expiresAt != 0 && expiresAt / 1000 <= (now ?? Date().timeIntervalSince1970) {
            return (nil, expired)
        }
        return (token, nil)
    }

    /// GETs `url` with Claude Code's sign-in. Refuses (before sending
    /// anything) unless it's HTTPS to api.anthropic.com.
    public static func httpGetJSON(_ url: String, token: String,
                                   send: HTTP.Send = HTTP.send) throws -> Any {
        let parsed = URL(string: url)
        let host = parsed.flatMap { HTTP.host(of: $0) }
        guard let parsed = parsed, parsed.scheme?.lowercased() == "https", host == allowedHost else {
            throw HTTP.RefusedURL(description: "refusing to send Claude Code's sign-in to \(host ?? "None")")
        }
        var request = URLRequest(url: parsed, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeTracker/\(Version.version)", forHTTPHeaderField: "User-Agent")
        // A redirect becomes an HTTP error; the token never follows it.
        return try HTTP.json(send(request, false))
    }

    private static func unixTime(_ value: Any) throws -> Double {
        if let number = JSON.double(value) {
            return number
        }
        guard let text = value as? String, let time = LocalTime.parseISO(text) else {
            throw HTTP.UnexpectedAnswer(description: "not a time: \(value)")
        }
        return time
    }

    /// The limits in an answer, as {"kind", "window", "label", "percent",
    /// "resets_at"}. Throws if it has none of them.
    public static func parseUsage(_ data: Any) throws -> [JSONObject] {
        var parsed: [JSONObject] = []
        for limit in limits {
            guard let info = JSON.object(data)?.object(limit.name),
                  !JSON.isNull(info["utilization"])
            else { continue }
            guard let percent = JSON.double(info["utilization"])
                    ?? (info["utilization"] as? String).flatMap({ Double($0) })
            else { throw HTTP.UnexpectedAnswer(description: "utilization isn't a number") }
            let resetsAt = info["resets_at"]
            parsed.append([
                "kind": limit.kind, "window": limit.window, "label": limit.label,
                "percent": percent,
                "resets_at": JSON.truthy(resetsAt) ? try unixTime(resetsAt!) : NSNull(),
            ])
        }
        parsed += newLimits(JSON.object(data) ?? [:], found: parsed)
        if parsed.isEmpty {
            throw HTTP.UnexpectedAnswer(description: "no limits in the answer")
        }
        return parsed
    }

    /// The longest name kept from Anthropic's answer for a new limit.
    static let longestNewName = 24

    /// Limits in the answer that the fixed `limits` table doesn't name: how
    /// the app notices a limit Anthropic adds (Fable came this way) with no
    /// update. They come from the answer's `limits` list and from extra
    /// `seven_day_<name>` keys. Anything that doesn't look as expected is
    /// skipped, never an error, so a change in this undocumented answer can't
    /// blank the limits that parsed fine. `found` holds the limits from the
    /// fixed table; a kind already taken is not repeated.
    static func newLimits(_ answer: JSONObject, found: [JSONObject]) -> [JSONObject] {
        var taken = Set(found.compactMap { $0.string("kind") })
        var new: [JSONObject] = []
        func add(kind: String, window: String, label: String, percent: Double, resetsAt: Any) {
            guard taken.insert(kind).inserted else { return }
            new.append(["kind": kind, "window": window, "label": label, "percent": percent,
                        "resets_at": resetsAt])
        }
        for case let item as JSONObject in answer.array("limits") ?? [] {
            guard let kind = item.string("kind"), let percent = JSON.double(item["percent"]),
                  let resetsAt = isoTimeOrNull(item["resets_at"])
            else { continue }
            // These two repeat the fixed keys; they only stand in for one that's missing.
            if kind == "session" || kind == "weekly_all" {
                let window = kind == "session" ? "five_hour" : "weekly"
                add(kind: window, window: window, label: Limits.windowLabels[window] ?? window,
                    percent: percent, resetsAt: resetsAt)
                continue
            }
            let group = item.string("group").map(kindSuffix(_:)).flatMap { $0.isEmpty ? nil : $0 }
                ?? kindSuffix(String(kind.split(separator: "_").first ?? ""))
            let window = ["session": "five_hour"][group] ?? group
            guard !window.isEmpty else { continue }
            let scope = item.object("scope")
            var name = [scope?.object("model")?.string("display_name"), scope?.string("surface")]
                .compactMap { $0 }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if name == nil {
                // The kind without its group word ("weekly_cowork" -> "cowork");
                // "weekly_scoped" only says it has a scope, so it names nothing.
                let rest = kind.hasPrefix(group + "_") ? String(kind.dropFirst(group.count + 1)) : kind
                name = rest == "scoped" ? nil : words(rest)
            }
            guard let named = name.map({ String($0.prefix(longestNewName)) }) else { continue }
            let slug = kindSuffix(named)
            guard !slug.isEmpty else { continue }
            add(kind: window + "_" + slug, window: window, label: windowTitle(window) + " · " + named,
                percent: percent, resetsAt: resetsAt)
        }
        let fixed = Set(limits.map(\.name))
        for key in answer.keys.sorted() where key.hasPrefix("seven_day_") && !fixed.contains(key) {
            guard let info = answer.object(key), let percent = JSON.double(info["utilization"]),
                  let resetsAt = isoTimeOrNull(info["resets_at"])
            else { continue }
            let named = String(words(String(key.dropFirst("seven_day_".count))).prefix(longestNewName))
            let slug = kindSuffix(named)
            guard !slug.isEmpty else { continue }
            add(kind: "weekly_" + slug, window: "weekly", label: "Weekly · " + named,
                percent: percent, resetsAt: resetsAt)
        }
        return new
    }

    /// null (or missing) as NSNull, an ISO time as seconds; anything else, a
    /// number included, as nil: a stray huge number would break formatting
    /// the reset time later.
    private static func isoTimeOrNull(_ value: Any?) -> Any? {
        if JSON.isNull(value) {
            return NSNull()
        }
        return (value as? String).flatMap { LocalTime.parseISO($0) }
    }

    /// "oauth_apps" -> "Oauth apps".
    private static func words(_ text: String) -> String {
        let text = text.split(separator: "_").joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A window's name for a label: "Weekly", or "Daily" for a window the app
    /// doesn't know.
    private static func windowTitle(_ window: String) -> String {
        Limits.windowLabels[window] ?? (window.prefix(1).uppercased() + window.dropFirst())
    }

    /// "GPT-5 Pro" -> "gpt_5_pro": lowercase letters and digits (any script),
    /// each run of anything else as one underscore, none at either end.
    private static func kindSuffix(_ name: String) -> String {
        var text = ""
        var broken = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                if broken && !text.isEmpty {
                    text.append("_")
                }
                broken = false
                text.append(character)
            } else {
                broken = true
            }
        }
        return text
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? HTTP.StatusError {
            if error.code == 401 || error.code == 403 {
                return expired
            }
            return "Anthropic answered HTTP \(error.code). Percentage unavailable."
        }
        if error is HTTP.ConnectionError {
            return offline
        }
        return "Anthropic sent an unexpected answer. Percentage unavailable."
    }

    /// {"limits": [...], "error": message or null, "fetched_at": unix time}.
    /// On an error there are no limits: old percentages could be wrong
    /// (`merged` keeps them aside, marked as old).
    public static func fetchUsage(get: Get = { try httpGetJSON($0, token: $1) },
                                  run: Subprocess.Runner = Subprocess.run,
                                  now: Double? = nil) -> JSONObject {
        let now = now ?? Date().timeIntervalSince1970
        var (token, error) = loadToken(run: run, now: now)
        var limits: [JSONObject] = []
        if let token = token, !token.isEmpty {
            do {
                limits = try parseUsage(get(usageURL, token))
            } catch let failure {  // any failure reads as unavailable
                error = describe(failure)
            }
        }
        return ["limits": limits, "error": error.map { $0 as Any } ?? NSNull(), "fetched_at": now]
    }

    /// What to save after a fetch: `fetched` as it is, plus `last_good`
    /// ({"limits", "fetched_at"}), the newest answer that had percentages.
    /// A failed fetch keeps the previous `last_good`, so the Limits tab can
    /// still show those numbers, marked as old (an expired sign-in too: it
    /// expires overnight while Claude Code is closed). Signing out drops it,
    /// and so does another `account` (Claude Code's email) than the one it
    /// was fetched for: those numbers would be someone else's. Alerts and the
    /// Live tab never read `last_good` (see `Limits.claudeLimits`).
    public static func merged(previous: JSONObject?, fetched: JSONObject, account: String? = nil) -> JSONObject {
        var result = fetched
        if let limits = fetched.array("limits"), !limits.isEmpty {
            var lastGood: JSONObject = ["limits": limits, "fetched_at": fetched["fetched_at"] ?? NSNull()]
            lastGood["account"] = account
            result["last_good"] = lastGood
            return result
        }
        if fetched.string("error") == signedOut {
            result["last_good"] = nil
            return result
        }
        if let lastGood = previous?.object("last_good"), !(lastGood.array("limits") ?? []).isEmpty {
            if let saved = lastGood.string("account"), let account = account, saved != account {
                result["last_good"] = nil
                return result
            }
            result["last_good"] = lastGood
        } else if let limits = previous?.array("limits"), !limits.isEmpty {
            // Saved by a version before `last_good`: its answer is the last good one.
            result["last_good"] = ["limits": limits, "fetched_at": previous?["fetched_at"] ?? NSNull()] as JSONObject
        }
        return result
    }

    public static func usageDue(_ saved: JSONObject?, now: Double? = nil) -> Bool {
        guard let saved = saved, !saved.isEmpty, JSON.truthy(saved["fetched_at"]),
              let fetchedAt = saved.double("fetched_at")
        else { return true }
        return (now ?? Date().timeIntervalSince1970) - fetchedAt >= refreshSeconds
    }
}

// MARK: - Shared by the network and Keychain modules
//
// ClaudeUsage, Accounts, GistSync and Updater all shell out (to `security`
// and `git`) and make HTTP requests. These two namespaces are the real
// implementations behind their injectable `run` and `send` parameters.

/// Running a command, like Python's `subprocess.run(args, capture_output=True,
/// text=True, input=...)`.
public enum Subprocess {
    /// How a command ended and what it printed (Python's CompletedProcess).
    public struct Result: Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public init(status: Int32 = 0, stdout: String = "", stderr: String = "") {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Runs `args` (program first), writing `input` to its stdin if given.
    public typealias Runner = (_ args: [String], _ input: String?) -> Result

    /// Runs `args` and waits for it. A program that can't be found or
    /// started ends with status 127, as in a shell, instead of throwing.
    /// A program name without a slash is looked up on PATH, as Python does,
    /// so `security` is /usr/bin/security and `git` the system's git.
    public static func run(_ args: [String], input: String? = nil) -> Result {
        guard let program = args.first, let executable = find(program) else {
            return Result(status: 127, stderr: "\(args.first ?? ""): command not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do {
            try process.run()
        } catch {
            return Result(status: 127, stderr: "\(program): \(error.localizedDescription)")
        }

        // Read both pipes and write stdin at the same time: a command stuck
        // writing to a full pipe, or waiting for input, would never exit.
        // These run on threads of their own, not GCD's shared pool: blocking
        // a pool thread here, with many commands running at once, can use up
        // the pool so the reads never start and every caller hangs.
        var helpers = [DispatchSemaphore]()
        let errorOutput = DataBox()
        helpers.append(onOwnThread {
            errorOutput.data = stderr.fileHandleForReading.readDataToEndOfFile()
        })
        if let input = input {
            let writer = stdin.fileHandleForWriting
            // A command that exits without reading would raise SIGPIPE and
            // kill the app; this makes the write fail quietly instead.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            helpers.append(onOwnThread {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            })
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        helpers.forEach { $0.wait() }
        process.waitUntilExit()
        let status = process.terminationReason == .uncaughtSignal
            ? -process.terminationStatus : process.terminationStatus
        return Result(status: status, stdout: String(decoding: output, as: UTF8.self),
                      stderr: String(decoding: errorOutput.data, as: UTF8.self))
    }

    /// Runs `work` on a new thread; the returned semaphore is signaled when
    /// it's done.
    static func onOwnThread(_ work: @escaping () -> Void) -> DispatchSemaphore {
        let done = DispatchSemaphore(value: 0)
        Thread {
            work()
            done.signal()
        }.start()
        return done
    }

    /// The full path of `program`, searching PATH when it has no slash.
    static func find(_ program: String) -> String? {
        if program.contains("/") {
            return program
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = "\(folder)/\(program)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

/// Synchronous HTTP requests through URLSession, for code that already runs
/// off the main thread (as the Python app's urllib calls did).
public enum HTTP {
    /// Sends a request; `followRedirects` false turns a redirect into a
    /// `StatusError` so credentials never follow it. Returns the body.
    public typealias Send = (_ request: URLRequest, _ followRedirects: Bool) throws -> Data

    /// The server answered with a status outside 200-299 (urllib's HTTPError).
    public struct StatusError: Error, Equatable, Sendable, CustomStringConvertible {
        public let code: Int
        public init(code: Int) { self.code = code }
        public var description: String { "HTTP Error \(code)" }
    }

    /// The server couldn't be reached or stopped answering (urllib's
    /// URLError, or an OSError such as a timeout).
    public struct ConnectionError: Error, Sendable, CustomStringConvertible {
        public let reason: String
        public init(reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// A URL the caller won't send credentials to (Python's ValueError).
    public struct RefusedURL: Error, Sendable, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// An answer that isn't what was expected: not JSON, or missing fields
    /// (Python's ValueError, KeyError or TypeError).
    public struct UnexpectedAnswer: Error, Sendable, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    /// `url`'s host in lower case, as Python's `urlparse(url).hostname` gives it.
    static func host(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased()
    }

    /// The JSON value in a response body.
    public static func json(_ data: Data) throws -> Any {
        guard let value = JSON.parse(data) else {
            throw UnexpectedAnswer(description: "the answer isn't JSON")
        }
        return value
    }

    /// The real `Send`: one request on a fresh ephemeral session (no
    /// cookies, cache or saved credentials, like urllib), waiting for the
    /// answer. Never call it on the main thread.
    public static func send(_ request: URLRequest, followRedirects: Bool) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        let session = URLSession(configuration: configuration,
                                 delegate: followRedirects ? nil : NoRedirect(),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            done.signal()
        }.resume()
        done.wait()

        if let error = box.error {
            if let error = error as? URLError, error.code == .timedOut {
                throw ConnectionError(reason: "timed out")
            }
            throw ConnectionError(reason: error.localizedDescription)
        }
        guard let response = box.response as? HTTPURLResponse else {
            throw ConnectionError(reason: "no answer")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw StatusError(code: response.statusCode)
        }
        return box.data ?? Data()
    }

    private final class ResponseBox: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)  // a redirect becomes a StatusError; credentials never follow it
        }
    }
}
