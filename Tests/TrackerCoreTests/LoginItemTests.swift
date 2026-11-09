// Port of tests/test_login_item.py.

import Foundation
import Testing
@testable import TrackerCore

@Test func setStartAtLoginEnableCallsLaunchctlEnable() throws {
    var calls: [[String]] = []

    try LoginItem.setStartAtLogin(true, run: { calls.append($0) })

    #expect(calls == [["launchctl", "enable", LoginItem.serviceTarget()]])
}

@Test func setStartAtLoginDisableCallsLaunchctlDisable() throws {
    var calls: [[String]] = []

    try LoginItem.setStartAtLogin(false, run: { calls.append($0) })

    #expect(calls == [["launchctl", "disable", LoginItem.serviceTarget()]])
}

// Swift-only: the target names this user's LaunchAgent.
@Test func serviceTargetIsTheUsersLaunchAgent() {
    #expect(LoginItem.serviceTarget(uid: 501) == "gui/501/com.claudetokencounter.menubar")
}
