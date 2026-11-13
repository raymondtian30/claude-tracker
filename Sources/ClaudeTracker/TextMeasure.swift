import AppKit
import TrackerCore

/// The real text widths, for the model's cut-off checks: the system font at
/// the size and weight the views draw with, with tabular digits (values are
/// drawn that way; for labels it errs a hair wide, never narrow). Widths are
/// remembered, since every render measures every label again.
enum TextMeasures {
    private static let cache = NSCache<NSString, NSNumber>()

    static let live: TextMeasure = { text, size, weight in
        let key = "\(size)|\(weight == .semibold ? 1 : 0)|\(text)" as NSString
        if let known = cache.object(forKey: key) {
            return CGFloat(known.doubleValue)
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight == .semibold ? .semibold : .regular)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        cache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }
}
