import AppKit
import TrackerCore

/// Usage limit alerts, the test alert, and pointing people to System
/// Settings when macOS won't show them.
extension AppController {
    /// Notify about limits that just reached an alert threshold.
    func checkAlerts() {
        let (messages, changed) = AppState.checkAlerts(&state, now: Date().timeIntervalSince1970)
        if changed {
            save()
        }
        for message in messages {
            notifier.send(message)
        }
    }

    func sendTestAlert() {
        notifier.sendChecked(
            "Test alert: this is how usage alerts look.",
            onBlocked: { [weak self] in onMain { self?.notificationsBlocked() } },
            onNoBanners: { [weak self] in onMain { self?.bannersOff() } })
    }

    private func notificationsBlocked() {
        let name = Version.appName
        pointToNotificationSettings(
            "Notifications Are Off",
            "macOS isn't letting \(name) show notifications. Turn them on for "
                + "\(name) in System Settings > Notifications.")
    }

    private func bannersOff() {
        let name = Version.appName
        pointToNotificationSettings(
            "Alerts Won't Pop Up",
            "The test alert was sent, but \(name)'s alert style is set to None, so macOS "
                + "puts alerts only in Notification Center. To see them on screen, choose Temporary "
                + "or Persistent for \(name) in System Settings > Notifications.")
    }

    private func pointToNotificationSettings(_ title: String, _ message: String) {
        panel.close()
        if Dialogs.alert(title, message, ok: "Open Settings", cancel: "Not Now"),
           let url = URL(string: Notifications.settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
