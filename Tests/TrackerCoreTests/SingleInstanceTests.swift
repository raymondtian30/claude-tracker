// Port of tests/test_single_instance.py.

import Foundation
import Testing
@testable import TrackerCore

@Test func secondLockIsRefusedUntilFirstIsReleased() throws {
    let path = TempDir().url("app.lock")
    let first = try InstanceLock.acquire(path)
    #expect(first != nil)

    #expect(try InstanceLock.acquire(path) == nil)

    first?.close()
    let again = try InstanceLock.acquire(path)
    #expect(again != nil)
    again?.close()
}
