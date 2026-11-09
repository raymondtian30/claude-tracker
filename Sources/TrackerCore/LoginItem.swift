import Foundation

/// Starting the app at login, through its LaunchAgent.
public enum LoginItem {
    /// The LaunchAgent's label (its plist is ~/Library/LaunchAgents/<label>.plist).
    public static let label = "com.claudetokencounter.menubar"

    /// launchctl's name for the LaunchAgent in this user's session.
    public static func serviceTarget(uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(label)"
    }

    /// A command that failed: launchctl's exit code and what it printed.
    public struct CommandFailed: Error, CustomStringConvertible {
        public let arguments: [String]
        public let status: Int32
        public let output: String

        public var description: String {
            "Command '\(arguments.joined(separator: " "))' returned non-zero exit status \(status). \(output)"
        }
    }

    /// Enable/disable this LaunchAgent starting at login via launchctl overrides.
    ///
    /// Does not touch the currently running process -- only affects whether
    /// launchd starts it again on the next login. Throws if launchctl fails.
    public static func setStartAtLogin(_ enabled: Bool, run: ([String]) throws -> Void = runChecked) throws {
        try run(["launchctl", enabled ? "enable" : "disable", serviceTarget()])
    }

    /// Runs `arguments` (found on the PATH), throwing if it exits non-zero,
    /// like Python's `subprocess.run(..., check=True, capture_output=True)`.
    public static func runChecked(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailed(arguments: arguments, status: process.terminationStatus,
                                output: String(decoding: output, as: UTF8.self))
        }
    }
}
