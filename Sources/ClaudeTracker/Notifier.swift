import AppKit
import TrackerCore
import UserNotifications

// macOS notifications through UNUserNotificationCenter.
//
// The older NSUserNotificationCenter drops notifications without an error on
// recent macOS, so alerts never showed. UNUserNotificationCenter needs the
// process to be a real app bundle; a bare `swift run` build isn't one, so it
// falls back to AppleScript's notification there.
//
// The logic (permission checks, the test alert's "blocked" and "banners
// off" answers) is TrackerCore's Notifier; this file connects it to macOS.

extension Notifier {
    /// A notifier on the real notification center, or on `fallback` when
    /// this process isn't an app bundle.
    static func live(title: String,
                     fallback: @escaping (String, String) -> Void = Notifier.appleScriptNotification) -> Notifier {
        Notifier(title: title, center: isAppBundle ? SystemNotificationCenter() : nil, fallback: fallback)
    }

    /// Asking UNUserNotificationCenter for its center outside an app bundle
    /// raises an Objective-C exception, which Swift can't catch: check first.
    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// For when the app isn't running from its bundle (e.g. `swift run`):
    /// AppleScript's notification, shown as Script Editor's.
    static func appleScriptNotification(title: String, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e",
                             "display notification (item 1 of argv) with title (item 2 of argv)",
                             "-e", "end run", message, title]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// UNUserNotificationCenter behind TrackerCore's NotificationCenterAPI. It's
/// also the center's delegate, so alerts show while the app is active.
final class SystemNotificationCenter: NSObject, NotificationCenterAPI, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self  // weak: the Notifier keeps this object alive
    }

    func getSettings(_ completion: @escaping (Int, Int) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus.rawValue, settings.alertStyle.rawValue)
        }
    }

    func requestAuthorization(_ completion: @escaping (Bool, Error?) -> Void) {
        center.requestAuthorization(options: [.alert, .sound], completionHandler: completion)
    }

    func add(title: String, body: String, _ completion: @escaping (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: completion)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show alerts even while the panel is open (the app is active then).
        completionHandler([.banner, .list, .sound])
    }
}
