// Finding the project folder wherever it was moved to, and keeping a private
// clone to update from when there is no usable one.

import Foundation
import Testing
@testable import TrackerCore

/// A folder that looks like this project: the three files `isProject` wants.
@discardableResult
private func makeProject(_ dir: URL, git: Bool = true, state: Bool = false) -> URL {
    writeText(dir.appendingPathComponent("Package.swift"), "// package")
    writeText(dir.appendingPathComponent("build.sh"), "#!/bin/bash")
    writeText(dir.appendingPathComponent("Sources/ClaudeTracker/main.swift"), "// main")
    if git {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    if state {
        writeText(dir.appendingPathComponent("state.json"), "{}")
    }
    return dir
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

@Test func isProjectNeedsTheProjectsFiles() {
    let tmp = TempDir()
    let good = makeProject(tmp.url("good"))
    let partial = tmp.mkdir("partial")
    writeText(partial.appendingPathComponent("Package.swift"), "")

    #expect(ProjectLocator.isProject(good.path, fileExists: exists))
    #expect(!ProjectLocator.isProject(partial.path, fileExists: exists))
    #expect(!ProjectLocator.isProject(tmp.url("missing").path, fileExists: exists))
}

@Test func theConfiguredFolderWinsWhenItIsThere() {
    let tmp = TempDir()
    let configured = makeProject(tmp.url("here"))
    var searched = false

    let found = ProjectLocator.resolve(configured: configured, pointer: nil, home: tmp.root.path,
                                       fileExists: exists, search: { _ in searched = true; return [] })

    #expect(found.dir.path == configured.path && found.source == .configured && !searched)
}

@Test func aConfiguredDataFolderWithoutTheProjectIsStillUsed() {
    // state.json is there: this is where the totals live, so don't leave them.
    let tmp = TempDir()
    let data = tmp.mkdir("data")
    writeText(data.appendingPathComponent("state.json"), "{}")

    let found = ProjectLocator.resolve(configured: data, pointer: nil, home: tmp.root.path,
                                       fileExists: exists, search: { _ in [] })

    #expect(found.dir.path == data.path && found.source == .configured)
}

@Test func aMovedFolderIsFoundThroughTheRememberedPlace() {
    let tmp = TempDir()
    let now = makeProject(tmp.url("Desktop/Claude/app"))

    let found = ProjectLocator.resolve(configured: tmp.url("Desktop/app"), pointer: now.path,
                                       home: tmp.root.path, fileExists: exists, search: { _ in [] })

    #expect(found.dir.path == now.path && found.source == .remembered)
}

@Test func aMovedFolderIsFoundBySearching() {
    let tmp = TempDir()
    let moved = makeProject(tmp.url("Documents/work/tracker"))
    let notIt = tmp.mkdir("Documents/work/other")

    let found = ProjectLocator.resolve(configured: tmp.url("gone"), pointer: tmp.url("also-gone").path,
                                       home: tmp.root.path, fileExists: exists,
                                       search: { _ in [notIt.path, moved.path] })

    #expect(found.dir.path == moved.path && found.source == .found)
}

@Test func withNothingFoundTheAppUsesItsOwnFolder() {
    let tmp = TempDir()

    let found = ProjectLocator.resolve(configured: tmp.url("gone"), pointer: nil, home: tmp.root.path,
                                       fileExists: exists, search: { _ in [] })

    #expect(found.source == .privateFolder)
    #expect(found.dir.path == ProjectLocator.supportDirectory(home: tmp.root.path).path)
    #expect(found.dir.path.hasSuffix("Library/Application Support/Claude Tracker"))
}

@Test func commonFoldersAreSearchedTwoLevelsDeepAndAnyOtherPlaceIsNot() {
    let tmp = TempDir()
    let shallow = makeProject(tmp.url("Desktop/tracker"))
    let deeper = makeProject(tmp.url("Documents/Claude/tracker"))
    makeProject(tmp.url("Documents/a/b/c/tracker"))  // too deep
    makeProject(tmp.url("Elsewhere/tracker"))  // not a place the search looks

    let found = ProjectLocator.projectsInCommonFolders(home: tmp.root.path)

    #expect(Set(found) == [shallow.path, deeper.path])
}

@Test func theNewestCloneIsTriedFirstAndOnesWithoutGitLast() {
    let tmp = TempDir()
    let plain = makeProject(tmp.url("Desktop/zip-download"), git: false)
    let old = makeProject(tmp.url("Desktop/old"))
    let newer = makeProject(tmp.url("Desktop/newer"))
    setModificationTime(old.appendingPathComponent("build.sh"), 100)
    setModificationTime(newer.appendingPathComponent("build.sh"), 5000)
    setModificationTime(plain.appendingPathComponent("build.sh"), 9000)

    let ordered = ProjectLocator.ordered([plain.path, old.path, newer.path], fileExists: exists)

    #expect(ordered == [newer.path, old.path, plain.path])
}

@Test func theRememberedPlaceIsWrittenOnlyWhenItChanges() throws {
    let tmp = TempDir()
    let support = ProjectLocator.supportDirectory(home: tmp.root.path)
    let project = makeProject(tmp.url("Desktop/tracker"))

    ProjectLocator.remember(project, home: tmp.root.path)
    let pointer = support.appendingPathComponent("project-dir")
    #expect(try String(contentsOf: pointer, encoding: .utf8) == project.path)
    #expect(ProjectLocator.remembered(home: tmp.root.path) == project.path)
    setModificationTime(pointer, 42)
    ProjectLocator.remember(project, home: tmp.root.path)  // same: not touched
    #expect(try FileManager.default.attributesOfItem(atPath: pointer.path)[.modificationDate] as? Date
            == Date(timeIntervalSince1970: 42))
}

// MARK: - The app's own data folder

private func readText(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

@Test func theAppKeepsItsDataInItsOwnFolder() {
    let tmp = TempDir()
    let home = tmp.url("home").path
    let dir = ProjectLocator.dataDirectory(explicit: nil, home: home, previous: { nil })

    #expect(dir == ProjectLocator.supportDirectory(home: home))
    #expect(exists(dir.path))
}

@Test func anExplicitFolderIsUsedAsItIsAndNothingIsCopied() {
    let tmp = TempDir()
    let old = makeProject(tmp.url("old"), state: true)
    let scratch = tmp.url("scratch")
    var asked = false
    let dir = ProjectLocator.dataDirectory(explicit: scratch, home: tmp.url("home").path,
                                           previous: { asked = true; return old })

    #expect(dir == scratch && !asked)
    #expect(!exists(tmp.url("home/Library/Application Support/Claude Tracker/state.json").path))
}

@Test func theFirstLaunchCopiesTotalsFromTheOldFolderAndLeavesThemThere() {
    let tmp = TempDir()
    let home = tmp.url("home").path
    let old = makeProject(tmp.url("old"))
    writeText(old.appendingPathComponent("state.json"), "{\"grand_total\": 7}")
    writeText(old.appendingPathComponent("friends.json"), "[1]")

    let dir = ProjectLocator.dataDirectory(explicit: nil, home: home, previous: { old })

    #expect(readText(dir.appendingPathComponent("state.json")) == "{\"grand_total\": 7}")
    #expect(readText(dir.appendingPathComponent("friends.json")) == "[1]")
    #expect(readText(old.appendingPathComponent("state.json")) == "{\"grand_total\": 7}")
    #expect(!exists(dir.appendingPathComponent("state.json.copying").path))
}

@Test func totalsAlreadyInTheAppsFolderAreNeverReplaced() {
    let tmp = TempDir()
    let home = tmp.url("home").path
    let support = ProjectLocator.supportDirectory(home: home)
    writeText(support.appendingPathComponent("state.json"), "{\"grand_total\": 99}")
    let old = makeProject(tmp.url("old"))
    writeText(old.appendingPathComponent("state.json"), "{\"grand_total\": 7}")
    var asked = false

    _ = ProjectLocator.dataDirectory(explicit: nil, home: home, previous: { asked = true; return old })

    #expect(readText(support.appendingPathComponent("state.json")) == "{\"grand_total\": 99}")
    #expect(!asked)  // no need to go looking for the old folder
}

@Test func aFreshInstallStartsEmpty() {
    let tmp = TempDir()
    let old = makeProject(tmp.url("old"))  // a clone with no totals yet
    let dir = ProjectLocator.dataDirectory(explicit: nil, home: tmp.url("home").path, previous: { old })

    #expect(!exists(dir.appendingPathComponent("state.json").path))
    #expect(!exists(dir.appendingPathComponent("friends.json").path))
}

@Test func theOldFolderBeingTheAppsFolderCopiesNothing() {
    let tmp = TempDir()
    let home = tmp.url("home").path
    let support = ProjectLocator.supportDirectory(home: home)
    let dir = ProjectLocator.dataDirectory(explicit: nil, home: home, previous: { support })

    #expect(dir == support && !exists(support.appendingPathComponent("state.json").path))
}

@Test func theDataFolderComesFromTheEnvironmentOrTheBundle() {
    let env = [AppState.projectDirEnvironment: "/scratch/a"]
    #expect(AppState.explicitDataDirectory(infoValue: "/scratch/b", environment: env)?.path == "/scratch/a")
    #expect(AppState.explicitDataDirectory(infoValue: "/scratch/b", environment: [:])?.path == "/scratch/b")
    #expect(AppState.explicitDataDirectory(infoValue: "", environment: [AppState.projectDirEnvironment: ""]) == nil)
    #expect(AppState.explicitDataDirectory(infoValue: nil, environment: [:]) == nil)
}
