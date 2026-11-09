import AppKit
import TrackerCore

/// Menu bar and header icons for each AI tool, from the tool's own app or
/// editor extension (see TrackerCore's ToolIconSource), else a drawn
/// monogram, else nil (the caller keeps the coin).
@MainActor
enum ToolIcons {
    static let menuBarIconSize = ToolIconSource.menuBarIconSize
    static let headerIconSize = ToolIconSource.headerIconSize

    private struct Key: Hashable {
        let tool: String
        let size: CGFloat
    }

    // Nil results are cached too: looking for a missing app on every redraw
    // would touch the disk each time.
    private static var cache: [Key: NSImage?] = [:]

    /// An image sized for the menu bar, or nil to keep the coin.
    static func menuBarImage(_ tool: String) -> NSImage? {
        iconImage(tool, size: menuBarIconSize)
    }

    /// `tool`'s icon as a `size`-point image, or nil to keep the coin.
    static func iconImage(_ tool: String, size: CGFloat) -> NSImage? {
        let key = Key(tool: tool, size: size)
        if let cached = cache[key] { return cached }
        let image = findImage(tool, size: size)
        cache[key] = image
        return image
    }

    private static func findImage(_ tool: String, size: CGFloat) -> NSImage? {
        let workspace = NSWorkspace.shared
        let source = ToolIconSource.iconSource(
            tool,
            appPathForBundle: { workspace.urlForApplication(withBundleIdentifier: $0)?.path },
            extensionDirs: ToolIconSource.extensionDirs,
            appDirs: ToolIconSource.appDirs)
        if let source = source {
            let found = source.app ? workspace.icon(forFile: source.path) : NSImage(contentsOfFile: source.path)
            if let image = found?.copy() as? NSImage {
                image.size = NSSize(width: size, height: size)
                image.isTemplate = source.template
                return image
            }
        }
        if let letters = ToolIconSource.monograms[tool] {
            return monogramImage(letters, size: size)
        }
        return nil
    }

    /// Letters in a rounded square, drawn as a template image so it follows
    /// the menu bar's colours.
    static func monogramImage(_ text: String, size: CGFloat = ToolIconSource.menuBarIconSize) -> NSImage {
        let scale = size / ToolIconSource.menuBarIconSize  // drawn for 16 pt, scaled to `size`
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor.black.set()
            let frame = NSBezierPath(
                roundedRect: NSRect(x: scale, y: scale, width: size - 2 * scale, height: size - 2 * scale),
                xRadius: 3.5 * scale, yRadius: 3.5 * scale)
            frame.lineWidth = 1.3 * scale
            frame.stroke()
            let font = NSFont.systemFont(ofSize: (text.count == 1 ? 10 : 7.5) * scale, weight: NSFont.Weight(0.4))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let label = text as NSString
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                       withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}
