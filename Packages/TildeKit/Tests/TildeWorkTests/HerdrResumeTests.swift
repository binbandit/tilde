import Foundation
import Testing
@testable import TildeWork

@Suite struct HerdrResumeTests {
    private struct CLI {
        let root: URL
        let environment: [String: String]

        init(startStatus: Int = 0, focus: String = "absent", paneStatus: Int = 0) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "tilde-herdr-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake-herdr.sh")
            let program = root.appending(path: "herdr")
            try FileManager.default.copyItem(at: fixture, to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
            environment = [
                "PATH": root.path + ":/bin:/usr/bin", "TILDE_HOME": root.appending(path: "home").path,
                "HERDR_TEST_LOG": root.appending(path: "calls").path,
                "HERDR_TEST_STARTED": root.appending(path: "started").path,
                "HERDR_TEST_FOCUS": focus, "HERDR_TEST_START_STATUS": String(startStatus),
                "HERDR_TEST_START_ERROR": focus == "started" ? "agent_not_ready" : "agent_pane_busy",
                "HERDR_TEST_PANE_STATUS": String(paneStatus),
            ]
        }

        func resume(_ command: String = "claude --resume scratch-session") async throws {
            try await Herdr.resume(command, in: root.path, label: "scratch", name: "j-scratch", environment: environment)
        }

        var calls: [String] {
            get throws { try String(contentsOf: root.appending(path: "calls"), encoding: .utf8).split(separator: "\n").map(String.init) }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test(arguments: [1, 127, 143])
    func failedStartWithoutALiveAgentThrows(status: Int) async throws {
        let cli = try CLI(startStatus: status)
        defer { cli.remove() }
        do {
            try await cli.resume()
            Issue.record("Rejected startup returned as a successful takeover")
        } catch Herdr.Failure.refused(let reason) {
            #expect(reason.contains("scratch startup rejected"))
        }
        let calls = try cli.calls
        #expect(calls.filter { $0 == "agent focus j-scratch" }.count == 2)
        #expect(!calls.contains { $0.hasPrefix("pane run") })
    }

    @Test func aLiveAgentAtAStartupPromptIsFocusedWithoutAnotherResume() async throws {
        let cli = try CLI(startStatus: 1, focus: "started")
        defer { cli.remove() }
        try await cli.resume()
        let calls = try cli.calls
        #expect(calls.last == "agent focus j-scratch")
        #expect(calls.filter { $0.hasPrefix("agent start") }.count == 1)
        #expect(!calls.contains { $0.hasPrefix("pane run") })
    }

    @Test func successfulStartDoesNotRetryTheCommand() async throws {
        let cli = try CLI()
        defer { cli.remove() }
        try await cli.resume()
        let calls = try cli.calls
        #expect(calls.filter { $0 == "agent focus j-scratch" }.count == 1)
        #expect(calls.last == "agent start j-scratch --kind claude --pane w1:p1 -- --resume scratch-session")
    }

    @Test func takingOverAgainFocusesTheExistingAgent() async throws {
        let cli = try CLI(focus: "existing")
        defer { cli.remove() }
        try await cli.resume()
        #expect(try cli.calls == ["status server --json", "agent focus j-scratch"])
    }

    @Test func unsupportedKindRunsThePlainCommand() async throws {
        let cli = try CLI(startStatus: 2)
        defer { cli.remove() }
        try await cli.resume("goose session --resume --session-id scratch-session")
        #expect(try cli.calls.last == "pane run w1:p1 goose session --resume --session-id scratch-session")
    }

    @Test func aRefusedPlainCommandAlsoThrows() async throws {
        let cli = try CLI(startStatus: 2, paneStatus: 1)
        defer { cli.remove() }
        await #expect(throws: Herdr.Failure.self) { try await cli.resume("goose session --resume --session-id scratch-session") }
    }
}
