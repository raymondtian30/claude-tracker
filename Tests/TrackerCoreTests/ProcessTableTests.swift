// The process reader: ps and lsof text in, plain ProcInfo values out. The
// sample lines are what ps printed on the owner's Mac on 2026-11-10 (start
// times are UTC, because the reader runs ps with TZ=UTC).

import Foundation
import Testing
@testable import TrackerCore

private let psTable = """
  747     1 ??       S    Mon Nov  9 07:19:59 2026     /Applications/Claude Tracker.app/Contents/MacOS/claude-tracker
15075     1 ??       Ss   Tue Nov 10 18:28:11 2026     /opt/homebrew/Cellar/opencode/2.2.5/bin/opencode
18426 16972 ??       S    Tue Nov 10 18:46:36 2026     /Users/alice/vscode/ext/native-binary/claude
22367 17216 ttys011  S+   Tue Nov 10 18:57:05 2026     codex
22377 22367 ??       Ss   Tue Nov 10 18:57:06 2026     /Users/alice/.codex/packages/app-server-daemon/bin/codex
22311 22237 ttys017  T+   Tue Nov 10 18:56:59 2026     opencode
30001 30000 ??       S    Tue Nov 10 19:00:00 2026     /usr/local/bin/node
"""

@Test func tableParsesPidParentTerminalStateStartAndProgram() {
    let table = ProcessTable.parseTable(psTable)
    #expect(table.count == 7)
    let codex = table.first { $0.pid == 22367 }
    #expect(codex == ProcInfo(pid: 22367, ppid: 17216, tty: "ttys011", state: "S+",
                              start: "Tue Nov 10 18:57:05 2026", program: "codex"))
    let server = table.first { $0.pid == 15075 }
    #expect(server?.tty == nil)
    #expect(server?.ppid == 1)
    #expect(server?.program == "opencode")
}

@Test func tableKeepsAProgramPathWithSpaces() {
    let tracker = ProcessTable.parseTable(psTable).first { $0.pid == 747 }
    #expect(tracker?.program == "claude-tracker")
    // A single-digit day is padded by ps; the start text keeps one space.
    #expect(tracker?.start == "Mon Nov 9 07:19:59 2026")
}

@Test func tableMarksAPausedProcess() {
    let table = ProcessTable.parseTable(psTable)
    #expect(table.first { $0.pid == 22311 }?.stopped == true)
    #expect(table.first { $0.pid == 22367 }?.stopped == false)
}

@Test func tableSkipsBlankAndBrokenLines() {
    let text = "\n  12 1 ??\nnot a process line at all here ok\n  42 1 ?? S Tue Nov 10 18:28:11 2026 /bin/zsh\n"
    #expect(ProcessTable.parseTable(text).map(\.pid) == [42])
}

@Test func argsParseOnePerPidAndKeepTheRestOfTheLine() {
    let text = """
    22377 /Users/alice/.codex/bin/codex app-server --listen  --managed-daemon
    22393 /Users/alice/.codex/bin/codex app-server daemon pid-update-loop
    22367 codex
    """
    let args = ProcessTable.parseArgs(text)
    #expect(args[22377] == "/Users/alice/.codex/bin/codex app-server --listen  --managed-daemon")
    #expect(args[22367] == "codex")
    #expect(args.count == 3)
}

@Test func foldersParseFromLsofFieldOutput() {
    let text = "p22367\nn/Users/alice/Desktop/example-app\np15075\nn/Users/alice\n"
    #expect(ProcessTable.parseFolders(text) == [22367: "/Users/alice/Desktop/example-app",
                                                 15075: "/Users/alice"])
}

@Test func toolKeyComesFromTheProgramAndForNodeFromTheScript() {
    func tool(_ program: String, _ args: String) -> String? {
        ProcessTable.toolKey(program: program, args: args)
    }
    #expect(tool("claude", "/x/claude --verbose") == "claude_code")
    #expect(tool("codex", "codex") == "codex")
    #expect(tool("opencode", "/opt/homebrew/bin/opencode serve --service") == "opencode")
    #expect(tool("node", "node /usr/local/bin/gemini --yolo") == "gemini_cli")
    #expect(tool("node", "node /usr/local/bin/other") == nil)
    #expect(tool("zsh", "-zsh") == nil)
}

@Test func sameStartIgnoresPaddingOnly() {
    #expect(ProcessTable.sameStart("Tue Nov 10 18:46:36 2026", "Tue Nov 10 18:46:36 2026"))
    #expect(ProcessTable.sameStart("Mon Nov  9 07:19:59 2026", "Mon Nov 9 07:19:59 2026"))
    #expect(!ProcessTable.sameStart("Tue Nov 10 18:46:36 2026", "Tue Nov 10 18:46:37 2026"))
    #expect(!ProcessTable.sameStart("", ""))
}

/// A runner that answers by the program asked for and records every call.
private final class FakeRunner {
    var calls = [[String]]()
    var table: Subprocess.Result
    var args: Subprocess.Result
    var folders: Subprocess.Result

    init(table: String, args: String = "", folders: String = "") {
        self.table = Subprocess.Result(stdout: table)
        self.args = Subprocess.Result(status: 1, stdout: args)  // ps -p exits 1 when a pid is gone
        self.folders = Subprocess.Result(status: 1, stdout: folders)  // so does lsof
    }

    var runner: Subprocess.Runner {
        { arguments, _ in
            self.calls.append(arguments)
            if arguments.first == "env" { return self.table }
            if arguments.first == "lsof" { return self.folders }
            return self.args
        }
    }
}

@Test func readMakesOnePsOneArgumentsCallAndOneLsofForCandidatesOnly() throws {
    let fake = FakeRunner(
        table: psTable,
        args: "18426 /x/claude --verbose\n22367 codex\n22377 /y/codex app-server\n22311 opencode\n15075 /o/opencode serve --service\n30001 node /usr/local/bin/gemini\n",
        folders: "p18426\nn/work/a\np22367\nn/work/b\np22377\nn/work/b\np22311\nn/work/c\np15075\nn/home\np30001\nn/work/d\n")
    let processes = try ProcessTable.read(run: fake.runner)

    #expect(fake.calls.count == 3)
    #expect(fake.calls[0].prefix(4) == ["env", "TZ=UTC", "LC_ALL=C", "ps"])
    #expect(fake.calls[1].first == "ps")
    #expect(fake.calls[1].contains("-p"))
    #expect(fake.calls[2].first == "lsof")
    #expect(fake.calls[2].contains("-b"))  // never wait on a dead network folder
    // Candidates are the tool programs and node, never claude-tracker.
    let asked = fake.calls[1].last ?? ""
    #expect(!asked.split(separator: ",").contains("747"))
    #expect(asked.split(separator: ",").contains("30001"))

    let server = processes.first { $0.pid == 15075 }
    #expect(server?.args == "/o/opencode serve --service")
    #expect(server?.folder == "/home")
    #expect(processes.first { $0.pid == 747 }?.args == nil)
    #expect(processes.first { $0.pid == 747 }?.folder == nil)
}

@Test func readSkipsTheExtraCallsWhenNoToolIsRunning() throws {
    let fake = FakeRunner(table: "  42 1 ?? S Tue Nov 10 18:28:11 2026 /bin/zsh\n")
    let processes = try ProcessTable.read(run: fake.runner)
    #expect(processes.map(\.pid) == [42])
    #expect(fake.calls.count == 1)
}

@Test func readThrowsWhenTheProcessListFails() {
    let runner: Subprocess.Runner = { _, _ in Subprocess.Result(status: 1, stdout: "", stderr: "boom") }
    #expect(throws: (any Error).self) { try ProcessTable.read(run: runner) }
}

@Test func readDropsAProcessNotAToolAndKeepsTheRestWhenLsofFindsNothing() throws {
    let fake = FakeRunner(table: psTable, args: "22367 codex\n", folders: "")
    let processes = try ProcessTable.read(run: fake.runner)
    #expect(processes.first { $0.pid == 22367 }?.folder == nil)
    #expect(processes.first { $0.pid == 22367 }?.args == "codex")
}

@Test func psOutputThatParsesToNothingIsAnErrorNotAnEmptyTable() {
    // The format changed: lines are there, none is understood.
    let runner: Subprocess.Runner = { _, _ in Subprocess.Result(stdout: "12 1 ?? S 10 Nov 18:00:00 2026 /bin/zsh\n") }
    #expect(throws: (any Error).self) { try ProcessTable.read(run: runner) }
    let empty: Subprocess.Runner = { _, _ in Subprocess.Result(stdout: "") }
    #expect((try? ProcessTable.read(run: empty))?.isEmpty == true)  // really no output: no processes
}
