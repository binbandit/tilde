import Darwin
import Foundation
import Testing
import WorkerKit
@testable import TildeWork

@Suite struct TerminalAgentTests {
    /// Captured from `herdr agent list` (0.9.3) on a scratch session: Claude at its trust prompt with its
    /// session reported, Codex working, Gemini idle.
    @Test func readsHerdrsAgents() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/herdr-agent-list.json")
        let agents = Herdr.agents(from: try Data(contentsOf: url))
        #expect(agents.map(\.harness.rawValue) == ["claude", "codex", "gemini"])
        #expect(agents.map(\.state) == [.blocked, .working, .idle])
        #expect(agents.map(\.place) == [.herdr(pane: "w2:p1"), .herdr(pane: "w2:p2"), .herdr(pane: "w3:p1")])
        #expect(agents.map(\.changes) == [1, 2, 3])
        let claude = try #require(agents.first)
        #expect(claude.name == "probe" && claude.session == "3f6c1b2a-8d4e-4f7a-9b1c-2e5d7a9c0b13")
        #expect(claude.cwd == "/Users/owner/Developer/shop/proj")
        #expect(agents[1].session == nil && agents[1].name == nil)
        #expect(Herdr.agents(from: Data(#"{"error":{"code":"server_not_running"}}"#.utf8)).isEmpty)
    }

    @Test func findsTheOwnersAgentsOutsideHerdrAndTilde() {
        func process(_ pid: Int32, _ parent: Int32, _ path: String, _ arguments: [String] = [], cwd: String? = "/Users/o/shop") -> RunningProcess {
            RunningProcess(pid: pid, parent: parent, path: path, interactive: !arguments.isEmpty, arguments: arguments, cwd: cwd)
        }
        let tree = ProcessTree([
            process(100, 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            process(101, 100, "/usr/bin/login"),
            process(102, 101, "/opt/homebrew/bin/fish", ["-fish"]),
            // Claude Code's native binary is named for its version; argv still says claude.
            process(103, 102, "/Users/o/.local/share/claude/versions/2.1.296", ["claude"]),
            process(104, 103, "/Users/o/.local/share/claude/versions/2.1.296", ["claude", "-p", "a subagent"]),
            process(105, 102, "/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/gemini"], cwd: "/Users/o/blog"),
            process(106, 102, "/usr/bin/man", ["man", "claude"]),
            // herdr's panes are herdr's to report.
            process(200, 1, "/opt/homebrew/bin/herdr"),
            process(201, 200, "/opt/homebrew/bin/fish", ["fish"]),
            process(202, 201, "/opt/homebrew/bin/codex", ["codex"]),
            // tilde and its workers.
            process(300, 1, "/Applications/tilde.app/Contents/MacOS/tilde"),
            process(301, 300, "/opt/homebrew/bin/codex", ["codex", "app-server"]),
            // A daemon with no terminal.
            process(400, 1, "/opt/homebrew/bin/codex"),
        ])
        let executables = ["claude": Harness(rawValue: "claude"), "codex": Harness(rawValue: "codex"), "gemini": Harness(rawValue: "gemini")]
        let agents = TerminalAgents.scan(tree, executables: executables, root: 300)
        #expect(agents.map(\.harness.rawValue) == ["claude", "gemini"])
        #expect(agents.map(\.place) == [.terminal(pid: 103, app: "/Applications/Ghostty.app"), .terminal(pid: 105, app: "/Applications/Ghostty.app")])
        #expect(agents.map(\.cwd) == ["/Users/o/shop", "/Users/o/blog"])
        #expect(agents.allSatisfy { $0.state == .unknown })
    }

    @Test(arguments: [
        (["herdr"], "default"), (["/opt/homebrew/bin/herdr", "--session", "dev"], "dev"), (["herdr", "session", "attach", "dev"], "dev"),
        (["herdr", "--session", "dev", "server"], nil), (["herdr", "agent", "list"], nil), (["herdr", "--remote", "box"], nil),
    ] as [([String], String?)])
    func onlyTheTUIIsAHerdrClient(arguments: [String], session: String?) {
        #expect(Herdr.attachedSession(arguments) == session)
    }

    @Test func readsArgumentsFromTheKernel() {
        #expect(ProcessTree.arguments(of: getpid()) == CommandLine.arguments)
    }
}
