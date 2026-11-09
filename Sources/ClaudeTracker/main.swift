import AppKit
import TrackerCore

// Temporary entry point: shows the panel with PanelPreview's sample data.
// A later wave replaces this with the real app controller.
//
//   swift run ClaudeTracker [--open] [--tab N] [--settings] [--welcome]
//                           [--dark|--light] [--slow] [--quit-after SECONDS]
//
// --open opens the panel (and --settings the Settings window) by itself and
// prints the window numbers, for `screencapture -l <number>`.

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

let app = NSApplication.shared
// Accessory policy = menu-bar only: no Dock icon, no app menu, not in Cmd-Tab.
app.setActivationPolicy(.accessory)

@MainActor
final class PreviewController {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    lazy var panel = PanelController(onAction: handle, onTabChange: { print("tab:", $0) })
    lazy var settingsWindow = SettingsWindow(onAction: handle)

    func start() {
        statusItem.button?.title = "🪙 48.3M"
        panel.animationSeconds = PanelSpeeds.animationSeconds(arguments.contains("--slow") ? "slow" : "normal")
        panel.attach(statusItem)
        panel.render(tabs: PanelPreview.tabs, footer: PanelPreview.footer,
                     toolChoices: PanelPreview.toolChoices, selectedTool: "claude_code",
                     welcome: arguments.contains("--welcome") ? PanelPreview.welcome : nil,
                     subtitle: "for Claude Code",
                     logo: ToolIcons.iconImage("claude_code", size: ToolIcons.headerIconSize))
        settingsWindow.render(PanelPreview.settings)
    }

    func handle(_ action: String, _ value: ActionValue) {
        print("action:", action, value)
        switch action {
        case "open_settings":
            panel.close()
            settingsWindow.show()
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }
}

let preview = MainActor.assumeIsolated { () -> PreviewController in
    let preview = PreviewController()
    preview.start()
    if arguments.contains("--dark") { Appearance.apply("dark") }
    if arguments.contains("--light") { Appearance.apply("light") }
    return preview
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    if arguments.contains("--open") {
        preview.panel.show()
        if let tab = option("--tab").flatMap(Int.init) {
            preview.panel.selectTab(tab, fade: false)
        }
    }
    if arguments.contains("--settings") { preview.settingsWindow.show() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        if let window = preview.panel.root.window, preview.panel.isShown {
            print("panel window:", window.windowNumber, window.effectiveAppearance.name.rawValue,
                  NSApp.appearance?.name.rawValue ?? "auto", preview.panel.popover.appearance?.name.rawValue ?? "nil")
        }
        if preview.settingsWindow.isShown { print("settings window:", preview.settingsWindow.window.windowNumber) }
        fflush(stdout)
    }
}
if let seconds = option("--quit-after").flatMap(Double.init) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
}
app.run()
