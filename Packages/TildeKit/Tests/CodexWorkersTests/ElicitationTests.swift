import Foundation
import Synchronization
import Testing
import TildeSupport
@testable import CodexWorkers

/// A host that allows only the tools it's told to, and remembers what it was asked.
final class ToolGate: CodexHost {
    let allowed: Set<String>
    private let asked = Mutex<[String?]>([])
    var tools: [String?] { asked.withLock { $0 } }

    init(allowing allowed: Set<String>) { self.allowed = allowed }

    func approveToolUse(connector: String, tool: String?, message: String) async -> Bool {
        asked.withLock { $0.append(tool) }
        return tool.map(allowed.contains) ?? false
    }
}

@Suite struct ElicitationTests {
    @Test func toolPromptsReachTheHostWithTheToolsName() async throws {
        let out = FileManager.default.temporaryDirectory.appending(path: "tilde-elicit-\(UUID().uuidString).json")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_app_server.py").path
        // Stands in for `codex`: the session runs `<executable> app-server`.
        let codex = FileManager.default.temporaryDirectory.appending(path: "fake-codex-\(UUID().uuidString)").path
        try "#!/bin/sh\nexec /usr/bin/python3 -I '\(fixture)'\n".write(toFile: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex)
        let host = ToolGate(allowing: ["get_issue"])
        let session = CodexSession(
            cwd: FileManager.default.temporaryDirectory.path, host: host, executable: codex,
            environment: ProcessInfo.processInfo.environment.merging(["FAKE_OUT": out.path]) { $1 })
        try await session.start()
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: out.path) { try await Task.sleep(for: .milliseconds(25)) }

        let answers = try JSONDecoder().decode([String].self, from: Data(contentsOf: out))
        #expect(answers == ["accept", "decline", "decline"])
        #expect(host.tools == ["get_issue", "save_issue"])  // a form that isn't an approval never reaches the host
        await session.stop()
    }

    @Test func plainServersNameTheToolInTheirPrompt() {
        #expect(CodexSession.toolName(in: #"Allow the linear MCP server to run tool "list_issues"?"#) == "list_issues")
        #expect(CodexSession.toolName(in: "Allow Codex to use Safari?") == nil)
        #expect(CodexSession.toolName(in: #"run tool ""?"#) == nil)
    }
}
