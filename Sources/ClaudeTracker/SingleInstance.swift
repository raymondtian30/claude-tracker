import Foundation
import TrackerCore

/// Keep one copy of the app running.
///
/// The app can be started at login (LaunchAgent) and from Finder. A second
/// copy finds the lock held, asks the running copy to open its panel, and
/// exits. The lock file and the notification name are the Python app's, so
/// a Python copy and a Swift copy find each other too.
enum SingleInstance {
    static let showPanelNotification = Notification.Name("com.raymondtian.claudetracker.showPanel")

    /// An exclusive lock on `path`: keep it for the life of the process. Nil
    /// if another process holds it.
    static func acquireLock(_ path: URL) throws -> InstanceLock? {
        try InstanceLock.acquire(path)
    }

    /// Ask the already-running copy to open its panel.
    static func requestShowPanel() {
        DistributedNotificationCenter.default().postNotificationName(
            showPanelNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Calls `callback` on the main thread whenever another copy asks this
    /// one to open its panel. Returns the observer; keep a reference to it.
    static func observeShowRequests(_ callback: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: showPanelNotification, object: nil, queue: .main) { _ in callback() }
    }
}
