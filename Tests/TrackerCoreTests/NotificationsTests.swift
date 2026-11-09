// Port of tests/test_notifications.py, with a fake notification center.

import Foundation
import Testing
@testable import TrackerCore

private let authorized = 2

/// Answers like UNUserNotificationCenter, straight away.
private final class FakeCenter: NotificationCenterAPI {
    var status: Int
    let grant: Bool
    let postError: Error?
    let style: Int
    var posted: [String] = []

    init(_ status: Int, grant: Bool = true, postError: Error? = nil, style: Int = Notifications.alertStyleBanner) {
        self.status = status
        self.grant = grant
        self.postError = postError
        self.style = style
    }

    func getSettings(_ completion: @escaping (Int, Int) -> Void) {
        completion(status, style)
    }

    func requestAuthorization(_ completion: @escaping (Bool, Error?) -> Void) {
        status = grant ? authorized : Notifications.statusDenied
        completion(grant, nil)
    }

    func add(title: String, body: String, _ completion: @escaping (Error?) -> Void) {
        posted.append(body)
        completion(postError)
    }
}

private struct Nope: Error {}

private func notifier(_ center: FakeCenter) -> Notifier {
    Notifier(title: "Claude Tracker", center: center, fallback: { _, _ in },
             callAfter: { $0() }, log: { _ in })
}

@Test func testAlertIsSentOnceAllowedInSystemSettings() {
    // Turning notifications on in System Settings works straight away: the
    // permission is looked up on each test alert, not remembered.
    let center = FakeCenter(Notifications.statusDenied)
    let n = notifier(center)
    var blocked: [Int] = []

    n.sendChecked("hi", onBlocked: { blocked.append(1) })
    center.status = authorized  // the user allows it in System Settings
    n.sendChecked("hi again", onBlocked: { blocked.append(1) })

    #expect(blocked == [1])
    #expect(center.posted == ["hi again"])
}

@Test func testAlertAsksWhenMacosHasntAskedYet() {
    let center = FakeCenter(Notifications.statusNotDetermined, grant: true)

    notifier(center).sendChecked("hi", onBlocked: {})

    #expect(center.posted == ["hi"])
}

@Test func testAlertSaysBlockedWhenPermissionRefusedOrPostingFails() {
    var blocked: [Int] = []
    for center in [FakeCenter(Notifications.statusNotDetermined, grant: false),
                   FakeCenter(authorized, postError: Nope())] {
        notifier(center).sendChecked("hi", onBlocked: { blocked.append(1) })
    }

    #expect(blocked == [1, 1])
}

@Test func testAlertSaysWhenBannersAreOff() {
    // With the alert style set to None, macOS files alerts in Notification
    // Center without showing them: the test alert is still sent, and the
    // user hears why it didn't pop up.
    var noBanners: [Int] = []
    let center = FakeCenter(authorized, style: Notifications.alertStyleNone)

    notifier(center).sendChecked("hi", onBlocked: {}, onNoBanners: { noBanners.append(1) })

    #expect(center.posted == ["hi"])
    #expect(noBanners == [1])
}

@Test func testAlertWithBannersOnSaysNothingMore() {
    var noBanners: [Int] = []
    let center = FakeCenter(authorized)

    notifier(center).sendChecked("hi", onBlocked: {}, onNoBanners: { noBanners.append(1) })

    #expect(center.posted == ["hi"] && noBanners.isEmpty)
}

@Test func settingsLinkOpensClaudeTrackersOwnPage() {
    #expect(Notifications.settingsURL.hasSuffix("?id=com.raymondtian.claudetracker"))
}

// Swift-only: without a notification center (not an app bundle), messages
// go to the fallback.
@Test func withoutACenterMessagesGoToTheFallback() {
    var shown: [String] = []
    let n = Notifier(title: "Claude Tracker", center: nil, fallback: { shown.append("\($0): \($1)") })

    n.send("hi")
    n.sendChecked("checked", onBlocked: {})

    #expect(shown == ["Claude Tracker: hi", "Claude Tracker: checked"])
}
