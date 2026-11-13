import Foundation

/// Runs `body` as main-actor code from a callback that AppKit, a Timer or
/// the main dispatch queue already makes on the main thread.
///
/// This is what `onMain` does, but that needs macOS 14
/// when the app is built with Swift 5.9, the newest Swift on macOS 13.
/// Function types differ only in their actor annotation here, so the cast
/// is safe, and the precondition catches any call off the main thread.
///
/// `body` runs in its own autorelease pool. AppKit drains the main thread's
/// pool only when an event (a click, a key) arrives, and a menu bar app can
/// go minutes without one, so what a timer's scan left there (every object
/// of every JSON file it parsed, a hundred megabytes and more) stayed in
/// memory until then.
@discardableResult
func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    precondition(Thread.isMainThread, "onMain called off the main thread")
    return try autoreleasepool {
        try withoutActuallyEscaping(body) { escapable in
            try unsafeBitCast(escapable, to: (() throws -> T).self)()
        }
    }
}
