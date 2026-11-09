import Foundation

extension Subprocess {
    /// Starts `args` in a session of its own and doesn't wait for it, like
    /// Python's `subprocess.Popen(args, start_new_session=True)`. Returns its
    /// process id.
    ///
    /// A new session matters for the restart after an update: launchd ends
    /// a LaunchAgent's whole process group when the app quits, which would
    /// take the restarting shell with it. Foundation's Process can't do
    /// this, so it's posix_spawn with POSIX_SPAWN_SETSID.
    @discardableResult
    public static func spawnDetached(_ args: [String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawnp(&pid, args[0], nil, &attributes, cArgs, environ)
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        return pid
    }
}
