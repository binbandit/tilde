import Testing
@testable import CodexWorkers

@Suite struct CodexWorkerTests {
    @Test func commandsAreDescribedByWhatTheShellRuns() {
        #expect(CodexWorker.describe(["type": "commandExecution", "command": "/bin/zsh -lc 'swift build'"]) == "Running swift build")
    }
}
