import Foundation

/// Sending macOS notifications, and what to do when macOS won't show them.
///
/// The real notification center (UNUserNotificationCenter) is reached
/// through `NotificationCenterAPI`, so this logic can be tested with a fake.
/// The app's Notifier.swift supplies the real one (`Notifier.live`).
///
/// UNUserNotificationCenter needs the process to be a real app bundle; where
/// it isn't (a `swift run` build), `fallback(title, message)` is used.
public enum Notifications {
    // UNAuthorizationStatus
    public static let statusNotDetermined = 0
    public static let statusDenied = 1
    // UNAlertStyle: none means only Notification Center, nothing pops up.
    public static let alertStyleNone = 0
    public static let alertStyleBanner = 1

    public static let bundleID = "com.raymondtian.claudetracker"
    /// Claude Tracker's own page in System Settings > Notifications.
    public static let settingsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
}

/// The parts of UNUserNotificationCenter the notifier uses. Completion
/// handlers may run on any thread.
public protocol NotificationCenterAPI: AnyObject {
    /// Calls back with the authorization status and alert style (raw values).
    func getSettings(_ completion: @escaping (_ status: Int, _ alertStyle: Int) -> Void)
    /// Asks for alert and sound permission.
    func requestAuthorization(_ completion: @escaping (_ granted: Bool, _ error: Error?) -> Void)
    /// Posts one notification with the default sound.
    func add(title: String, body: String, _ completion: @escaping (Error?) -> Void)
}

/// Sends notifications.
///
/// Permission is looked up from macOS each time it matters, never kept:
/// the user can turn notifications on or off in System Settings at any
/// moment.
public final class Notifier {
    public let title: String
    /// Nil where UNUserNotificationCenter isn't available.
    public let center: NotificationCenterAPI?
    private let fallback: (_ title: String, _ message: String) -> Void
    /// Runs a callback on the main thread (tests run it straight away).
    private let callAfter: (@escaping () -> Void) -> Void
    private let log: (String) -> Void

    public init(title: String, center: NotificationCenterAPI?,
                fallback: @escaping (_ title: String, _ message: String) -> Void,
                callAfter: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                log: @escaping (String) -> Void = Notifier.logToStderr) {
        self.title = title
        self.center = center
        self.fallback = fallback
        self.callAfter = callAfter
        self.log = log
    }

    /// Goes to agent.err.log.
    public static func logToStderr(_ text: String) {
        FileHandle.standardError.write(Data("notifications: \(text)\n".utf8))
    }

    /// Asks macOS's question once (it remembers the answer), then calls
    /// `then(granted)` on the main thread.
    public func requestPermission(then: ((Bool) -> Void)? = nil) {
        guard let center = center else { return }
        center.requestAuthorization { [self] granted, error in
            if let error = error {
                log("permission request failed: \(error)")
            }
            if let then = then {
                callAfter { then(granted) }
            }
        }
    }

    /// Send `message` if macOS allows it right now; otherwise call
    /// `onBlocked()` on the main thread. If it's sent but the alert style
    /// is None (it only goes to Notification Center), `onNoBanners()` is
    /// called too. For the test alert, where the user should hear why
    /// nothing popped up.
    public func sendChecked(_ message: String, onBlocked: @escaping () -> Void,
                            onNoBanners: (() -> Void)? = nil) {
        guard let center = center else {
            fallback(title, message)
            return
        }
        let blocked = { [self] in callAfter(onBlocked) }
        center.getSettings { [self] status, alertStyle in
            if status == Notifications.statusDenied {
                blocked()
            } else if status == Notifications.statusNotDetermined {
                requestPermission { [self] granted in
                    if granted {
                        send(message, onError: blocked)
                    } else {
                        onBlocked()
                    }
                }
            } else {
                send(message, onError: blocked)
                if let onNoBanners = onNoBanners, alertStyle == Notifications.alertStyleNone {
                    callAfter(onNoBanners)
                }
            }
        }
    }

    public func send(_ message: String, onError: (() -> Void)? = nil) {
        guard let center = center else {
            fallback(title, message)
            return
        }
        center.add(title: title, body: message) { [self] error in
            if let error = error {
                log("couldn't post a notification: \(error)")
                onError?()
            }
        }
    }
}
