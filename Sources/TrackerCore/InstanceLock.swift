import Foundation

/// The lock that keeps one copy of the app running (see the app's
/// SingleInstance). Same file and the same flock(2) as the Python app, so a
/// Python copy and a Swift copy keep each other out too.
public final class InstanceLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close() }

    /// Takes an exclusive lock on `path`. Returns the open lock (keep it for
    /// the life of the process), or nil if another process holds it. Throws
    /// if the file can't be opened at all.
    public static func acquire(_ path: URL) throws -> InstanceLock? {
        // Python's open(path, "w"): create or empty the file.
        let fd = open(path.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        return InstanceLock(descriptor: fd)
    }

    /// Releases the lock (closing the file does it).
    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
