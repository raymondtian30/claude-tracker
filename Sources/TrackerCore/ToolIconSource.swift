import Foundation

/// Where each AI tool's icon comes from, kept free of AppKit so the lookup
/// can be tested. The app's ToolIcons turns what's found here into images.
///
/// Icons are taken at runtime from the tool's own app or editor extension
/// already installed on this Mac; no logo files ship with Claude Tracker. If
/// a tool's icon can't be found, the menu bar keeps the coin; a provider
/// without one gets a drawn monogram instead, so it can still be told apart.
public enum ToolIconSource {
    /// An editor extension folder holding an icon: (folder prefix, icon file
    /// inside it, draw as a template image that follows the menu bar's colors).
    public struct Extension {
        public let prefix: String
        public let file: String
        public let template: Bool
    }

    /// Per tool: app bundle ids to try, app names to look for in the app
    /// folders, then an editor extension.
    public struct Source {
        public let apps: [String]
        public var appNames: [String] = []
        public let `extension`: Extension?
    }

    /// An icon that was found: an app (draw its Finder icon) or an image file.
    public struct Found: Equatable {
        public let path: String
        public let app: Bool
        public let template: Bool

        public init(path: String, app: Bool, template: Bool) {
            self.path = path
            self.app = app
            self.template = template
        }
    }

    private static let claudeExtension = Extension(
        prefix: "anthropic.claude-code-", file: "resources/claude-logo.svg", template: false)
    private static let openAIExtension = Extension(
        prefix: "openai.chatgpt-", file: "resources/blossom-black.svg", template: true)

    public static let sources: [String: Source] = [
        "claude_code": Source(apps: ["com.anthropic.claudefordesktop"], extension: claudeExtension),
        "codex": Source(apps: ["com.openai.codex", "com.openai.chat"], extension: openAIExtension),
        "opencode": Source(apps: ["ai.opencode.desktop"], extension: nil),
        "openai": Source(apps: ["com.openai.chat", "com.openai.codex"], extension: openAIExtension),
        "deepseek": Source(apps: [], appNames: ["DeepSeek.app"], extension: nil),
        "kimi": Source(apps: [], appNames: ["Kimi.app"], extension: nil),
        "anthropic": Source(apps: ["com.anthropic.claudefordesktop"], extension: claudeExtension),
        "google": Source(apps: [], appNames: ["Gemini.app"], extension: nil),
        "xai": Source(apps: [], appNames: ["Grok.app"], extension: nil),
        "mistral": Source(apps: [], appNames: ["Le Chat.app"], extension: nil),
        "qwen": Source(apps: [], appNames: ["Qwen.app"], extension: nil),
        "zai": Source(apps: [], appNames: ["Z.ai.app"], extension: nil),
        "minimax": Source(apps: [], appNames: ["MiniMax.app"], extension: nil),
    ]

    public static var appDirs: [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public static let monograms: [String: String] = [
        "gemini_cli": "GC", "openai": "AI", "deepseek": "DS", "kimi": "K", "google": "G",
        "anthropic": "A", "xai": "X", "mistral": "M", "qwen": "Q",
        "zai": "Z", "minimax": "MM",
    ]

    public static var extensionDirs: [URL] {
        [".vscode", ".cursor", ".windsurf"].map {
            home.appendingPathComponent($0).appendingPathComponent("extensions")
        }
    }

    public static let menuBarIconSize: CGFloat = 16
    /// The panel header's logo.
    public static let headerIconSize: CGFloat = 28

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The numbers of an extension folder's version ("openai.chatgpt-26.1021.22027-darwin-arm64"
    /// gives [26, 1021, 22027]), for picking the newest.
    static func versionKey(_ folderName: String, prefix: String) -> [Int] {
        let rest = String(folderName.dropFirst(prefix.count))
        let version = rest.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return version.split { !$0.isNumber }.compactMap { Int($0) }
    }

    /// Where to get `tool`'s icon, or nil. `appPathForBundle(bundleId)`
    /// returns an installed app's path or nil; apps without a known bundle id
    /// are looked up by name in `appDirs`.
    public static func iconSource(_ tool: String, appPathForBundle: (String) -> String?,
                                  extensionDirs: [URL], appDirs: [URL] = []) -> Found? {
        guard let source = sources[tool] else { return nil }
        for bundleId in source.apps {
            if let path = appPathForBundle(bundleId) {
                return Found(path: path, app: true, template: false)
            }
        }
        for name in source.appNames {
            for folder in appDirs {
                let app = folder.appendingPathComponent(name)
                if isDirectory(app) {
                    return Found(path: app.path, app: true, template: false)
                }
            }
        }
        guard let ext = source.extension else { return nil }
        let manager = FileManager.default
        var candidates: [(key: [Int], url: URL)] = []
        for root in extensionDirs where isDirectory(root) {
            let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where name.hasPrefix(ext.prefix) {
                let file = root.appendingPathComponent(name).appendingPathComponent(ext.file)
                if manager.fileExists(atPath: file.path) {
                    candidates.append((versionKey(name, prefix: ext.prefix), file))
                }
            }
        }
        // Python's max() keeps the first of equal keys; Swift's max(by:)
        // keeps the last, so ties are broken by folder name instead.
        let newest = candidates.max { a, b in
            a.key != b.key ? a.key.lexicographicallyPrecedes(b.key) : a.url.path > b.url.path
        }
        return newest.map { Found(path: $0.url.path, app: false, template: ext.template) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
