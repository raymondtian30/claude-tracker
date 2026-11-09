import AppKit
import TrackerCore

/// Check for Updates: list newer releases, install the newest (git
/// fast-forward, rebuild the bundle), then restart.
extension AppController {
    private enum UpdateOutcome {
        case found([Updater.Release])
        case current
        case updated(tag: String)
        case failed(String)

        /// UpdateError's own message, or a generic one for anything else.
        static func failure(_ error: Error) -> UpdateOutcome {
            if let error = error as? Updater.UpdateError {
                return .failed(error.description)
            }
            return .failed("Unexpected problem (\(type(of: error))).")
        }
    }

    /// The "Claude Tracker.app" this runs from, or where install.sh puts it.
    var bundlePath: URL {
        AppState.bundlePath(running: Bundle.main.bundleURL, defaultDest: AppState.defaultDest())
    }

    /// List the newer releases and ask whether to install the newest.
    func checkForUpdates() {
        guard updateStatus == nil else { return }  // already checking or updating
        showUpdateStatus("Checking…")
        inBackground({ () -> UpdateOutcome in
            do {
                return .found(try Updater.newerReleases())
            } catch {
                return .failure(error)
            }
        }, then: { [weak self] outcome in
            self?.offerUpdates(outcome)
        })
    }

    private func offerUpdates(_ outcome: UpdateOutcome) {
        guard case .found(let releases) = outcome, let newestRelease = releases.first else {
            if case .found = outcome {
                finishUpdate(.current)
            } else {
                finishUpdate(outcome)
            }
            return
        }
        updateStatus = nil
        renderPanel()
        let newest = String(newestRelease.tag.drop(while: { $0 == "v" }))
        let count = releases.count
        panel.close()
        let wanted = Dialogs.confirmWithDetails(
            title: count > 1 ? "\(count) Updates Available" : "Update Available",
            message: "\(Version.appName) \(newest) is available (you have \(Version.version)). Updating keeps "
                + "your settings and totals, and restarts the app.",
            details: Updater.describeReleases(releases), ok: "Update to \(newest)", cancel: "Not Now")
        guard wanted else { return }
        showUpdateStatus("Updating to \(newest)…")
        let tag = newestRelease.tag
        let projectDir = files.projectDir.path
        let bundleDir = bundlePath.deletingLastPathComponent().path
        inBackground({ () -> UpdateOutcome in
            do {
                let before = Updater.currentCommit(projectDir)
                try Updater.installRelease(tag, projectDir: projectDir)
                try Updater.rebuildBundle(bundleDir, projectDir: projectDir, undoTo: before)
                return .updated(tag: tag)
            } catch {
                return .failure(error)
            }
        }, then: { [weak self] outcome in
            self?.finishUpdate(outcome)
        })
    }

    private func showUpdateStatus(_ status: String) {
        updateStatus = status
        renderPanel()
    }

    private func finishUpdate(_ outcome: UpdateOutcome) {
        updateStatus = nil
        renderPanel()
        switch outcome {
        case .updated(let tag):
            state["updated_to"] = tag
            save()
            restart()
        case .current, .found:
            Dialogs.alert("You're Up to Date", "\(Version.appName) \(Version.version) is the newest version.")
        case .failed(let detail):
            Dialogs.alert("Couldn't Update", detail)
        }
    }

    /// Quit, and start again once this copy is gone: through the LaunchAgent
    /// if there is one, else by opening the bundle.
    private func restart() {
        let command = Updater.restartCommand(Int(ProcessInfo.processInfo.processIdentifier),
                                             bundlePath.path, LoginItem.serviceTarget())
        do {
            try Subprocess.spawnDetached(["/bin/sh", "-c", command])
        } catch {
            log("Couldn't schedule the restart: \(error)")
        }
        NSApp.terminate(nil)
    }
}
