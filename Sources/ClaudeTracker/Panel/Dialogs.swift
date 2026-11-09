import AppKit
import TrackerCore

/// Light or dark for the whole app (panel, Settings, dialogs); "auto"
/// follows macOS, switching with it.
@MainActor
enum Appearance {
    static func apply(_ key: String) {
        NSApp.appearance = PanelLayout.appearanceName(key).flatMap { NSAppearance(named: NSAppearance.Name($0)) }
    }
}

@MainActor
enum Dialogs {
    /// A dialog with `details` in a scrolling box under `message`. True if
    /// the user clicks `ok`.
    static func confirmWithDetails(title: String, message: String, details: String,
                                   ok: String, cancel: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: cancel)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
        text.string = details
        text.isEditable = false
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
