import AppKit
import TrackerCore

/// The real text widths, for the model's cut-off checks. Uses the same
/// system font, size and weight that `LabelText` draws with.
enum TextMeasures {
    static let live: TextMeasure = { text, size, weight in
        let font = NSFont.systemFont(ofSize: size, weight: weight == .semibold ? .semibold : .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}
