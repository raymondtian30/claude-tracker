// Port of tests/test_tool_icons.py. The lookup is TrackerCore's
// ToolIconSource; drawing the image is the app's ToolIcons (AppKit).

import Foundation
import Testing
@testable import TrackerCore

private func apps(_ mapping: [String: String]) -> (String) -> String? {
    { mapping[$0] }
}

@discardableResult
private func makeExtension(_ root: TempDir, _ folder: String, _ rel: String) -> URL {
    let path = root.url("\(folder)/\(rel)")
    writeText(path, "<svg/>")
    return path
}

private func iconSource(_ tool: String, _ appPath: @escaping (String) -> String?, _ extensionDirs: [URL],
                        appDirs: [URL] = []) -> ToolIconSource.Found? {
    ToolIconSource.iconSource(tool, appPathForBundle: appPath, extensionDirs: extensionDirs, appDirs: appDirs)
}

@Test func claudeUsesTheClaudeAppIcon() {
    let found = iconSource("claude_code", apps(["com.anthropic.claudefordesktop": "/Applications/Claude.app"]), [])
    #expect(found == ToolIconSource.Found(path: "/Applications/Claude.app", app: true, template: false))
}

@Test func opencodeUsesTheOpencodeAppIcon() {
    let found = iconSource("opencode", apps(["ai.opencode.desktop": "/Applications/OpenCode.app"]), [])
    #expect(found == ToolIconSource.Found(path: "/Applications/OpenCode.app", app: true, template: false))
}

@Test func codexFallsBackToTheEditorExtensionIcon() {
    let tmp = TempDir()
    let svg = makeExtension(tmp, "openai.chatgpt-26.1021.22027-darwin-arm64", "resources/blossom-black.svg")

    let found = iconSource("codex", apps([:]), [tmp.url("missing"), tmp.root])

    #expect(found == ToolIconSource.Found(path: svg.path, app: false, template: true))
}

@Test func newestExtensionVersionWins() {
    let tmp = TempDir()
    makeExtension(tmp, "openai.chatgpt-26.900.1-darwin-arm64", "resources/blossom-black.svg")
    let newer = makeExtension(tmp, "openai.chatgpt-26.1021.22027-darwin-arm64", "resources/blossom-black.svg")

    #expect(iconSource("codex", apps([:]), [tmp.root])?.path == newer.path)
}

@Test func appIsPreferredOverExtension() {
    let tmp = TempDir()
    makeExtension(tmp, "openai.chatgpt-26.1-darwin-arm64", "resources/blossom-black.svg")

    let found = iconSource("codex", apps(["com.openai.codex": "/Applications/Codex.app"]), [tmp.root])

    #expect(found?.path == "/Applications/Codex.app")
}

@Test func nothingFoundReturnsNone() {
    #expect(iconSource("opencode", apps([:]), [TempDir().root]) == nil)
}

@Test func openaiUsesTheSameSourcesAsCodex() {
    let tmp = TempDir()
    let svg = makeExtension(tmp, "openai.chatgpt-26.1-darwin-arm64", "resources/blossom-black.svg")

    #expect(iconSource("openai", apps([:]), [tmp.root]) == ToolIconSource.Found(path: svg.path, app: false, template: true))
    #expect(iconSource("openai", apps(["com.openai.chat": "/Applications/ChatGPT.app"]), [])?.path
            == "/Applications/ChatGPT.app")
}

@Test func providerAppFoundByName() {
    let tmp = TempDir()
    tmp.mkdir("Kimi.app")

    let found = iconSource("kimi", apps([:]), [], appDirs: [tmp.url("missing"), tmp.root])

    #expect(found == ToolIconSource.Found(path: tmp.url("Kimi.app").path, app: true, template: false))
}

@Test func providersWithoutAnAppGetAMonogram() {
    #expect(ToolIconSource.monograms.filter { ["gemini_cli", "openai", "deepseek", "kimi", "google", "anthropic", "xai", "mistral", "qwen", "zai", "minimax"].contains($0.key) } == ["gemini_cli": "GC", "openai": "AI", "deepseek": "DS", "kimi": "K", "google": "G",
                                         "anthropic": "A", "xai": "X", "mistral": "M", "qwen": "Q",
                                         "zai": "Z", "minimax": "MM"])
    #expect(iconSource("deepseek", apps([:]), [], appDirs: []) == nil)
}

// Not ported: testIconImageComesInTheRequestedSize draws an NSImage (the
// app's ToolIcons.iconImage, AppKit). Checked in the running app: the
// header's 28 pt monogram for a provider without an app.
@Test func iconSizes() {
    #expect(ToolIconSource.menuBarIconSize == 16)
    #expect(ToolIconSource.headerIconSize == 28)
}

@Test func anthropicUsesTheClaudeIcon() {
    let found = iconSource("anthropic", apps(["com.anthropic.claudefordesktop": "/Applications/Claude.app"]), [])
    #expect(found?.path == "/Applications/Claude.app")
}
