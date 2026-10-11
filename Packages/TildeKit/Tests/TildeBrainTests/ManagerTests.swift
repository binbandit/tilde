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
        let out = root.appending(path: "methods.txt")
        var config = Manager.Config()
        config.executable = try fakeCodex(out: out)
        config.stallAfter = 1
        let manager = Manager(memory: memory, tools: Toolset(name: "tilde", instructions: "", tools: []), config: config)

        // tilde's own turn hangs; a second later it's interrupted and the same thread carries on.
        await manager.post(.init("<observations>\n- a PR changed\n</observations>"))
        for _ in 0..<200 where !(methods(out).filter { $0 == "turn/start" }.count == 2) { try await Task.sleep(for: .milliseconds(25)) }

        // Brayden asks something while that turn runs: it's steered in, and the answer is his.
        await manager.post(.init("<tap>how many PRs are open?</tap>", tap: "t-1"))
        var answer: ([String], String)?
        for await output in manager.outputs {
            if case .replyDone(let taps, let text) = output { answer = (taps, text); break }
        }
        #expect(answer?.0 == ["t-1"])
        #expect(answer?.1 == "You said: <tap>how many PRs are open?</tap>")
        #expect(methods(out).filter { $0.hasPrefix("turn/") } == ["turn/start", "turn/interrupt", "turn/start", "turn/steer"])
        await manager.shutdown()
    }

    private func fakeCodex(out: URL) throws -> String {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_manager.py").path
        let path = root.appending(path: "codex").path
        try "#!/bin/sh\nFAKE_OUT='\(out.path)' exec /usr/bin/python3 -I '\(fixture)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func methods(_ out: URL) -> [String] {
        ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
