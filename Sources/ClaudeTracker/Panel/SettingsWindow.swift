import AppKit
import SwiftUI
import TrackerCore

/// Settings in a window of their own, drawn with the panel's cards and
/// controls. Clicks call `onAction(action, value)` like the panel's. The
/// "Show more…" window of every AI is one too, with its own title.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let title = PanelLayout.settingsWindowTitle

    let onAction: ActionHandler
    let window: NSWindow
    /// The content to show, as last rendered.
    private(set) var settings: Tab?
    /// The content the window's views were built from; nil while closed.
    private var built: Tab?
    private let root = FlippedView(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 400))
    private let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 400))
    private var placed = false

    init(title: String = PanelLayout.settingsWindowTitle, onAction: @escaping ActionHandler) {
        self.onAction = onAction
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        super.init()
        scroll.documentView = root
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.delegate = self
    }

    /// Builds the window's content, unless it's what is already built. The
    /// panel draws on every click and scan, and building and drawing this tall
    /// view takes about 100 ms, so opening Settings, or scrolling it right
    /// after, used to stutter. It's laid out as soon as it's built, so the
    /// first opening has little left to do.
    ///
    /// While the window is closed the content is only remembered: its views
    /// take several megabytes, so they are built when it opens and let go
    /// when it closes.
    func render(_ settings: Tab) {
        self.settings = settings
        if window.isVisible {
            build()
        }
    }

    private func build() {
        guard let settings = settings, settings != built else { return }
        built = settings
        root.subviews.forEach { $0.removeFromSuperview() }
        let height = PanelLayout.settingsHeight(settings)
        let hosting = NSHostingView(rootView: SettingsContentView(settings: settings, onAction: onAction))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: PanelLayout.width, height: height)
        root.addSubview(hosting)
        setHeight(height)
        hosting.layoutSubtreeIfNeeded()
    }

    private func setHeight(_ height: CGFloat) {
        root.setFrameSize(NSSize(width: PanelLayout.width, height: height))
        // Leave room for the title bar and the menu bar.
        let available = NSScreen.main.map { $0.visibleFrame.height - 80 } ?? height
        let frame = window.frame
        let newHeight = min(height, available)
        guard window.contentRect(forFrameRect: frame).height != newHeight else { return }
        let top = frame.maxY
        window.setContentSize(NSSize(width: PanelLayout.width, height: newHeight))
        if placed {  // keep the title bar where it was
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        }
    }

    func show() {
        build()
        if !placed {
            window.center()
            placed = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
        tearDown()
    }

    func windowWillClose(_ notification: Notification) {
        tearDown()
    }

    /// Back from the Dock: catch up with what was rendered meanwhile.
    func windowDidDeminiaturize(_ notification: Notification) {
        build()
    }

    /// Lets go of the content's views (see `render`).
    private func tearDown() {
        root.subviews.forEach { $0.removeFromSuperview() }
        built = nil
    }

    var isShown: Bool { window.isVisible }
}
