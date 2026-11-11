import AppKit

/// A plain window with the session diagnostics report in a read-only text view
/// and a Copy button, for pasting into a bug report.
final class DiagnosticsWindow: NSObject {
    let window: NSWindow
    private let textView = NSTextView()
    private var text = ""

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
                          defer: false)
        super.init()
        window.title = "Session diagnostics"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyReport))
        copy.bezelStyle = .rounded
        copy.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(copy)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -8),
            copy.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
    }

    /// Shows `report`, and brings the window to the front.
    func show(_ report: String) {
        text = report
        textView.string = report
        textView.scrollToBeginningOfDocument(nil)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
