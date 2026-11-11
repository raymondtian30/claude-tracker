import AppKit
import TrackerCore

/// Settings > Scanning > Session diagnostics: one fresh scan, written out as
/// text that says why each process was counted or not (`SessionDiagnostics`),
/// in a window with a Copy button.
extension AppController {
    func showSessionDiagnostics() {
        let previous = registry.snapshot
        inBackground({
            let started = Date()
            do {
                let processes = try ProcessTable.read()
                let read = Int(Date().timeIntervalSince(started) * 1000)
                return SessionDiagnostics.report(processes: processes, records: ClaudeRecords.read(),
                                                 previous: previous, now: Date().timeIntervalSince1970,
                                                 timings: [("read processes", read)])
            } catch {
                return "Couldn't read the process list: \(error)\n"
            }
        }, then: { [weak self] text in
            self?.diagnosticsWindow.show(text)
        })
    }
}
