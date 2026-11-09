import Foundation

/// Runs `body` as main-actor code from a callback that AppKit, a Timer or
/// the main dispatch queue already makes on the main thread.
///
/// This is what `onMain` does, but that needs macOS 14
/// when the app is built with Swift 5.9, the newest Swift on macOS 13.
/// Function types differ only in their actor annotation here, so the cast
/// is safe, and the precondition catches any call off the main thread.
@discardableResult
func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    precondition(Thread.isMainThread, "onMain called off the main thread")
    return try withoutActuallyEscaping(body) { escapable in
        try unsafeBitCast(escapable, to: (() throws -> T).self)()
    }
}
