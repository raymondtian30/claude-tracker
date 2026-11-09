import AppKit
import SwiftUI
import TrackerCore

// Shared look for the panel and Settings: panel_view.py's sizes, fonts and
// colors, for the SwiftUI views.

// SwiftUI (macOS 15 SDK) also declares a `Tab`; the module's own name wins.
typealias Tab = TrackerCore.Tab

/// What controls call with their action and value.
typealias ActionHandler = (_ action: String, _ value: ActionValue) -> Void


extension Color {
    static let label = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)
    static let orange = Color(nsColor: .systemOrange)
    static let accent = Color(nsColor: .controlAccentColor)

    /// The text color, faded: card fills, tracks and hairlines.
    static func faint(_ alpha: Double) -> Color {
        Color(nsColor: .labelColor).opacity(alpha)
    }
}

extension Font {
    /// The system font; `digits` gives every digit the same width, as
    /// right-aligned numbers have in the panel.
    static func panel(_ size: CGFloat, _ weight: Font.Weight = .regular, digits: Bool = false) -> Font {
        let font = Font.system(size: size, weight: weight)
        return digits ? font.monospacedDigit() : font
    }
}

/// One line of text in a fixed-height slot, like the panel's labels.
struct LabelText: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color = .label
    var digits = false
    var truncation: Text.TruncationMode = .tail
    var height: CGFloat = 18
    var alignment: Alignment = .leading

    var body: some View {
        Text(text)
            .font(.panel(size, weight, digits: digits))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(truncation)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: alignment)
    }
}

/// An SF Symbol at a point size.
struct Symbol: View {
    let name: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color = .label

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundColor(color)
    }
}

/// A view in flipped coordinates (y grows down), like the Python panel.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
