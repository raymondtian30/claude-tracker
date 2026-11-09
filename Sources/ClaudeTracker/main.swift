import AppKit
import TrackerCore

// Claude Tracker: a menu bar app counting the tokens AI coding tools use.
//
// The LaunchAgent starts it with `--foreground` (a leftover from the Python
// app's launcher); arguments are accepted and ignored.

let files = AppState.Files(projectDir: AppState.projectDirectory(
    infoValue: Bundle.main.object(forInfoDictionaryKey: AppState.projectDirKey) as? String,
    environment: ProcessInfo.processInfo.environment,
    currentDirectory: FileManager.default.currentDirectoryPath))

let instanceLock: InstanceLock
do {
    guard let lock = try SingleInstance.acquireLock(files.lock) else {
        // Already running (e.g. started at login): show that copy's panel.
        SingleInstance.requestShowPanel()
        exit(0)
    }
    instanceLock = lock
} catch {
    FileHandle.standardError.write(Data("Couldn't open \(files.lock.path): \(error)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
// Accessory policy = menu-bar only: no Dock icon, no app menu, not in Cmd-Tab.
app.setActivationPolicy(.accessory)

let controller = onMain { () -> AppController in
    let controller = AppController(files: files)
    controller.start()
    return controller
}
app.run()
withExtendedLifetime((instanceLock, controller)) {}
