import Foundation

/// The panel's open/close animation speeds, kept free of AppKit so the
/// Settings tab (PanelModel) can list them.
///
/// Each is (key, label, seconds). The panel grows out of the menu bar icon when
/// it opens and shrinks back into it when it closes.
public enum PanelSpeeds {
    public static let animationSpeeds: [(key: String, label: String, seconds: Double)] = [
        ("off", "Off", 0.0), ("fast", "Fast", 0.12), ("normal", "Normal", 0.22), ("slow", "Slow", 0.4),
    ]
    public static let defaultAnimation = "normal"

    // Light or dark look for the panel and Settings; "auto" follows macOS.
    public static let appearances: [(key: String, label: String)] = [
        ("auto", "Auto"), ("light", "Light"), ("dark", "Dark"),
    ]
    public static let defaultAppearance = "auto"

    public static func animationSeconds(_ key: String?) -> Double {
        animationSpeeds.first { $0.key == key }?.seconds ?? 0.22
    }
}
