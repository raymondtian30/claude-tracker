import AppKit
import TrackerCore

// Claude Tracker: a menu bar app counting the tokens AI coding tools use.
//
// The LaunchAgent starts it with `--foreground` (a leftover from the Python
// app's launcher); arguments are accepted and ignored.

// The app keeps its totals in its own folder (see ProjectLocator.dataDirectory),
// not in the code's folder. A scratch or test build, or CLAUDE_TRACKER_PROJECT_DIR,
// names a folder of its own instead. The first launch of an installed app
// copies the totals over from the folder it was built in, wherever that is now.
// A bare executable (`swift run`, no app bundle) works in the current folder.
let explicitDir = AppState.explicitDataDirectory(
    infoValue: Bundle.main.object(forInfoDictionaryKey: AppState.dataDirKey) as? String,
    environment: ProcessInfo.processInfo.environment)
    ?? (Bundle.main.bundleURL.pathExtension == "app" ? nil
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
let files = AppState.Files(projectDir: ProjectLocator.dataDirectory(
    explicit: explicitDir, home: UsageStats.homeDirectory,
    previous: {
        ProjectLocator.resolve(configured: AppState.projectDirectory(
            infoValue: Bundle.main.object(forInfoDictionaryKey: AppState.projectDirKey) as? String,
            environment: [:], currentDirectory: FileManager.default.currentDirectoryPath)).dir
    }))

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
