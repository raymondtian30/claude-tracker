// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeTracker",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything that can be tested without AppKit: parsing logs,
        // totals, limits, prices, network and Keychain helpers, the panel's
        // plain-data model.
        .target(name: "TrackerCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The menu bar app itself: AppKit shell and SwiftUI views.
        .executableTarget(name: "ClaudeTracker", dependencies: ["TrackerCore"]),
        .testTarget(name: "TrackerCoreTests", dependencies: ["TrackerCore"]),
    ]
)
