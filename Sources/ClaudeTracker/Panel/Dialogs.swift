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

extension Dialogs {
    /// An "are you sure" box for something that can't be undone. Cancel is the
    /// default button (Return and Esc both cancel); `confirm` goes ahead, in red.
    /// True if the user clicks `confirm`.
    static func confirmDestructive(title: String, message: String, confirm: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: confirm).hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// rumps.alert: `title` in bold, `message` under it. With `cancel`, two
    /// buttons; true if the user clicks `ok`.
    @discardableResult
    static func alert(_ title: String, _ message: String, ok: String = "OK", cancel: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        if let cancel = cancel {
            alert.addButton(withTitle: cancel)
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// rumps.Window: a dialog with a text field. The text typed, or nil if
    /// the user clicks `cancel`. `secure` hides what's typed (keys, tokens).
    static func ask(title: String, message: String, defaultText: String = "", ok: String,
                    cancel: String, secure: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: cancel)
        let frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let field = secure ? NSSecureTextField(frame: frame) : NSTextField(frame: frame)
        field.stringValue = defaultText
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
