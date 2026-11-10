import AppKit
import SwiftUI
import TrackerCore

/// The popover shown when the menu bar icon is clicked. Call `render` with
/// fresh data; clicks on controls call `onAction(action, value)`, and
/// picking a tab calls `onTabChange(key)`.
///
/// AppKit runs the popover, its grow/shrink animation, outside-click and Esc
/// closing; SwiftUI draws the header, tab bar and each tab's cards. Each
/// tab's content is its own hosting view, built the first time it's shown
/// and kept until the next render, so switching tabs only swaps views.
@MainActor
final class PanelController: NSObject {
    let onAction: ActionHandler
    let onTabChange: ((String) -> Void)?
    /// Set from Settings; 0 = no animation.
    var animationSeconds: Double = 0

    private(set) var tabs: [Tab] = []
    private var selection: TabSelection
    private var footer = ""
    private var welcome: Tab?
    private var logo: NSImage?
    private var subtitle = "for Claude Code"
    private var toolPicker: Item?
    /// The tab the last draw showed, to keep its scroll position on a redraw.
    private var drawnTab: String?

    let popover = NSPopover()
    /// The panel's content, in flipped coordinates; it scrolls when it's
    /// taller than the screen allows.
    let root = FlippedView(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 400))
    private let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 400))
    /// What the popover shows: it clips `stage`, which keeps the panel at its
    /// full size and is scaled down while the panel grows or shrinks.
    let wrapper = PanelWrapperView(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 400))
    let stage = PanelStageView(frame: NSRect(x: 0, y: 0, width: PanelLayout.width, height: 400))
    private var chrome: PanelChrome?
    private var chromeView: NSView?
    private var tabViews = TabViewCache<NSView>()
    private(set) var shownTabView: NSView?
    private var contentTop: CGFloat = 0

    weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var lastToggle: TimeInterval = 0
    var fullHeight: CGFloat = 400
    /// `fromShare`: how far open the panel was when the animation started
    /// (PanelLayout.foldFrame), so reversing one carries on from there.
    var animation: (start: TimeInterval, unfolding: Bool, fromShare: Double)?
    /// How far open the panel is: 0 closed, 1 fully open.
    var lastShare: Double = 0
    var animationTimer: AnyObject?

    var selected: String { selection.selected }
    /// Called just before the panel opens, so the app can draw fresh data
    /// then instead of on every scan while nobody's looking.
    var onWillShow: (() -> Void)?

    init(onAction: @escaping ActionHandler, onTabChange: ((String) -> Void)? = nil,
         selectedTab: String = "overview") {
        self.onAction = onAction
        self.onTabChange = onTabChange
        selection = TabSelection(selected: selectedTab)
        super.init()
        scroll.documentView = root
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = []
        stage.autoresizingMask = []
        stage.addSubview(scroll)
        wrapper.addSubview(stage)
        let controller = NSViewController()
        controller.view = wrapper
        popover.contentViewController = controller
        // Not .transient: that closes the panel whenever this background app
        // isn't active, which macOS doesn't always allow it to be. Outside
        // clicks and Esc are handled with event monitors instead.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: PanelLayout.width, height: 400)
    }

    // MARK: - Wiring

    /// Make clicking the status item open this panel instead of a menu.
    func attach(_ statusItem: NSStatusItem) {
        statusItem.menu = nil
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        self.button = button
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        // Showing the popover while the status bar button is still handling
        // its click fails silently, so open it on the next run-loop pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.toggle() }
    }

    func toggle() {
        // One click on the status item can deliver the action twice; ignore
        // a second toggle that arrives right after the first.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastToggle >= 0.3 else { return }
        lastToggle = now
        if popover.isShown {
            close(animated: true)
        } else {
            onWillShow?()
            show(retriesLeft: 3)
        }
    }

    /// Open the panel if it isn't already open.
    func show() {
        if button != nil && !popover.isShown {
            onWillShow?()
            show(retriesLeft: 3)
        }
    }

    /// Every opening starts on the first tab (Home).
    func goHome() {
        selectTab(0, fade: false)  // it's closed: nothing to fade
    }

    private func show(retriesLeft: Int) {
        guard let button = button else { return }
        goHome()
        NSApp.activate(ignoringOtherApps: true)
        if animationSeconds > 0 {
            show(frame: PanelLayout.foldFrame(progress: 0, unfolding: true, fromShare: 0, fullSize: fullSize))
            lastShare = 0
        }
        // A popover takes its look from the menu bar icon, which follows the
        // menu bar (dark over a dark wallpaper), not the Appearance setting.
        popover.appearance = NSApp.effectiveAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if popover.isShown {
            startMonitors()
            if animationSeconds > 0 {
                animate(unfolding: true)
            }
        } else if retriesLeft > 0 {
            // The status bar can still be busy with the click; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.show(retriesLeft: retriesLeft - 1)
            }
        }
    }

    /// Close the panel; `animated` folds it up first (if the animation is
    /// on). Dialogs and the Settings window close it straight away.
    func close(animated: Bool = false) {
        if animated && animationSeconds > 0 && popover.isShown {
            if let animation = animation, !animation.unfolding {
                return  // already folding
            }
            stopMonitors()
            animate(unfolding: false)
            return
        }
        stopAnimation()
        stopMonitors()
        if popover.isShown {
            popover.close()
        }
        resetToFullSize(share: 0)
    }

    /// The size and scale the panel has when it's open (and what it goes back
    /// to once it's closed, so the next opening starts from a clean state).
    func resetToFullSize(share: Double) {
        stage.isAnimating = false
        stage.setFrameSize(fullSize)
        stage.setBoundsSize(fullSize)
        popover.contentSize = fullSize
        lastShare = share
    }

    var fullSize: NSSize { NSSize(width: PanelLayout.width, height: fullHeight) }

    /// Puts the panel at one step of growing or shrinking: the popover at the
    /// window size, and the stage's contents scaled to fit it.
    func show(frame: PanelLayout.FoldFrame) {
        stage.setFrameSize(NSSize(width: frame.width, height: frame.height))
        stage.setBoundsSize(fullSize)
        popover.contentSize = NSSize(width: frame.windowWidth, height: frame.windowHeight)
    }

    var isShown: Bool { popover.isShown }

    /// Whether the panel is unfolding or folding up right now.
    var isAnimating: Bool { animation != nil }

    // MARK: - Outside clicks and Esc

    private func startMonitors() {
        stopMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        // Global monitors only see clicks in other apps, so any click here
        // is outside the panel.
        let outside = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            onMain { self?.close(animated: true) }
        }
        // A click in this app's own windows (e.g. Settings) is outside too.
        let inApp = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            let window = event.window
            onMain {
                if let self = self, self.clickCloses(window) {
                    self.close(animated: true)
                }
            }
            return event
        }
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEsc = event.keyCode == 53
            let window = event.window
            let closed = onMain { () -> Bool in
                guard let self = self, isEsc, window === self.root.window else { return false }
                self.close(animated: true)
                return true
            }
            return closed ? nil : event
        }
        monitors = [outside, inApp, escape].compactMap { $0 }
    }

    /// Not in the panel itself, and not on the menu bar icon, whose own
    /// click toggles the panel.
    private func clickCloses(_ window: NSWindow?) -> Bool {
        PanelLayout.clickCloses(window, panel: root.window, statusItem: button?.window,
                                partOfPanel: belongsToPanel)
    }

    /// A pop-up the panel opened (a date field's calendar): a pop-over window,
    /// a window whose parent is the panel's, or any window without a title
    /// bar. Only a real window, like Settings, counts as outside the panel.
    private func belongsToPanel(_ window: NSWindow) -> Bool {
        if PanelLayout.isPopoverWindowClass(String(describing: type(of: window)))
            || !window.styleMask.contains(.titled) {
            return true
        }
        var parent = window.parent
        while let current = parent {
            if current === root.window { return true }
            parent = current.parent
        }
        return false
    }

    private func stopMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: - Rendering

    /// `toolChoices` (key, name) adds a tool switcher when there are 2+;
    /// `welcome` (a tab) replaces everything with the first-run picker;
    /// `logo` replaces the header's coin. Settings live in their own window
    /// (SettingsWindow).
    func render(tabs: [Tab], footer: String, toolChoices: [(key: String, name: String)] = [],
                selectedTool: String? = nil, welcome: Tab? = nil,
                subtitle: String = "for Claude Code", logo: NSImage? = nil) {
        // Most draws (every click and scan) change nothing that shows. Drawing
        // again would rebuild every view for nothing, and stutter whatever
        // the panel is doing, such as unfolding.
        let picker = PanelLayout.toolPicker(toolChoices, selected: selectedTool)
        if !self.tabs.isEmpty, self.tabs == tabs, self.footer == footer, self.welcome == welcome,
           self.subtitle == subtitle, self.logo === logo, toolPicker == picker {
            return
        }
        self.tabs = tabs
        self.footer = footer
        self.welcome = welcome
        self.subtitle = subtitle
        self.logo = logo
        toolPicker = picker
        selection.update(keys: tabs.map(\.key))
        draw()
    }

    /// Draw everything from scratch (new data).
    private func draw() {
        guard !tabs.isEmpty else { return }
        // A redraw of the same tab keeps where the user had scrolled to.
        let keptOffset: CGFloat? = drawnTab == selection.selected && welcome == nil
            ? scroll.contentView.bounds.origin.y : nil
        defer {
            drawnTab = welcome == nil ? selection.selected : nil
            if let offset = keptOffset {
                let maxOffset = max(root.frame.height - scroll.contentView.bounds.height, 0)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, maxOffset)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        root.subviews.forEach { $0.removeFromSuperview() }
        tabViews.removeAll()
        shownTabView = nil
        chrome = nil
        chromeView = nil

        if let welcome = welcome {
            let view = WelcomeView(tab: welcome, logo: logo, subtitle: subtitle, onAction: onAction)
            let height = PanelLayout.welcomeHeight(welcome)
            root.addSubview(hosting(view, y: 0, height: height))
            setHeight(height)
            return
        }

        let chrome = PanelChrome(
            selected: selection.selected, tabs: tabs, logo: logo, subtitle: subtitle, toolPicker: toolPicker,
            onSelectTab: { [weak self] index in self?.selectTab(index) }, onAction: onAction)
        contentTop = PanelLayout.contentTop(hasToolPicker: toolPicker != nil)
        let chromeView = hosting(PanelChromeView(chrome: chrome), y: 0, height: contentTop)
        root.addSubview(chromeView)
        self.chrome = chrome
        self.chromeView = chromeView
        showTab(fade: false)
    }

    /// Shows the tab with this key, if there is one.
    func select(key: String) {
        guard let index = tabs.firstIndex(where: { $0.key == key }) else { return }
        selectTab(index, fade: false)
    }

    func selectTab(_ index: Int, fade: Bool = true) {
        guard selection.select(index) else { return }
        onTabChange?(selection.selected)
        guard let chrome = chrome, welcome == nil else {
            draw()
            return
        }
        // Only the tab bar's highlight and the content change: no redraw.
        chrome.selected = selection.selected
        showTab(fade: fade)
    }

    private func showTab(fade: Bool) {
        guard let tab = tabs.first(where: { $0.key == selection.selected }) else { return }
        let height = PanelLayout.tabContentHeight(tab)
        let view = tabViews.view(for: tab.key) {
            let content = TabContentView(tab: tab, footer: footer, onAction: onAction)
            let view = hosting(content, y: contentTop, height: height)
            view.wantsLayer = true  // so it can fade in smoothly
            // Laid out now, not when first drawn, so showing it has little left to do.
            view.layoutSubtreeIfNeeded()
            return view
        }
        if let shown = shownTabView, shown !== view {
            shown.removeFromSuperview()
        }
        shownTabView = view
        if view.superview == nil {
            root.addSubview(view)
        }
        setHeight(contentTop + height + PanelLayout.pad)
        if fade && animationSeconds > 0 {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = PanelLayout.tabFadeSeconds
                view.animator().alphaValue = 1
            }
        } else {
            view.alphaValue = 1
        }
    }

    private func setHeight(_ height: CGFloat) {
        root.setFrameSize(NSSize(width: PanelLayout.width, height: height))
        let screenHeight = NSScreen.main?.visibleFrame.height ?? height + PanelLayout.screenMargin
        fullHeight = PanelLayout.panelHeight(height, screenHeight: screenHeight)
        // The scroll view always has the full size; only the stage's scale
        // changes while the panel grows or shrinks.
        scroll.setFrameSize(fullSize)
        // An animation sizes the panel itself (from the next step on, with
        // this height); an unchanged size would only cost a needless layout
        // pass.
        if animation != nil {
            stage.setBoundsSize(fullSize)
        } else if popover.contentSize != fullSize || stage.frame.size != fullSize {
            resetToFullSize(share: lastShare)
        }
    }

    /// `view` in a hosting view placed at `y` in the root view.
    private func hosting<Content: View>(_ view: Content, y: CGFloat, height: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []  // sized here, from PanelLayout
        hosting.frame = NSRect(x: 0, y: y, width: PanelLayout.width, height: height)
        return hosting
    }
}
