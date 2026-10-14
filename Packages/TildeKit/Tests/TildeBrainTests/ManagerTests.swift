import Foundation
import Testing
import TildeMemory
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

@Suite struct ManagerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-manager-\(UUID().uuidString)")

    @Test(.timeLimit(.minutes(1))) func aStalledTurnIsAskedAgainAndATapIsAnsweredInIt() async throws {
        let home = TildeHome(root: root.appending(path: "home"))
        try home.prepare()
        let memory = try Memory(home: home, projects: ProjectIndex(roots: []))
        try await memory.prepare()
        let codex = try FakeCodex(in: root, scenario: "quiet")
        var config = Manager.Config()
        config.executable = codex.executable
        config.stallAfter = 1
        let manager = Manager(memory: memory, tools: Toolset(name: "tilde", instructions: "", tools: []), config: config)

        // tilde's own turn goes quiet; a second later it's interrupted and the same thread carries on.
        await manager.post(.init("<observations>\n- a PR changed\n</observations>"))
        for _ in 0..<200 where codex.requests("turn/start").count < 2 { try await Task.sleep(for: .milliseconds(25)) }

        // Brayden asks something while that turn runs: it's steered in, and the answer is his.
        await manager.post(.init("<tap>how many PRs are open?</tap>", tap: "t-1"))
        var answer: ([String], String)?
        var read: [String] = []
        for await output in manager.outputs {
            if case .read(let taps) = output { read += taps }
            if case .replyDone(let taps, let text, _) = output { answer = (taps, text); break }
        }
        #expect(read == ["t-1"])
        #expect(answer?.0 == ["t-1"])
        #expect(answer?.1 == "You said: <tap>how many PRs are open?</tap>")
        let turns = codex.requests.compactMap { $0["method"]?.string }.filter { $0.hasPrefix("turn/") }
        #expect(turns == ["turn/start", "turn/interrupt", "turn/start", "turn/steer"])
        await manager.shutdown()
    }
}
