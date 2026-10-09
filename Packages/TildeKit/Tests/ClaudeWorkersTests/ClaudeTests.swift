import Testing
import TildeSupport
import WorkerKit
@testable import ClaudeWorkers

@Suite struct ClaudeTests {
    @Test func claudeLaunchSpeaksTheControlProtocol() {
        var launch = ClaudeLaunch(cwd: "/tmp", sessionID: "abc")
        launch.hostedServers = ["tilde"]
        launch.permissionMode = "auto"
        let args = launch.arguments
        #expect(args.contains("--permission-prompt-tool") && args.contains("stdio"))
        #expect(args.contains("--session-id") && args.contains("abc"))
        let mcp = args[args.firstIndex(of: "--mcp-config")! + 1]
        #expect(JSON.parse(mcp)?["mcpServers"]?["tilde"]?["type"] == "sdk")

        launch.resume = true
        #expect(launch.arguments.contains("--resume") && !launch.arguments.contains("--session-id"))
    }

    @Test func askUserQuestionAnswersMatchOptionLabels() {
        let input: JSON = ["questions": [["question": "Sticky?", "header": "Nav", "options": [["label": "Sticky"], ["label": "Scroll away"]]]]]
        let questions = [WorkerQuestion(question: "Sticky?", options: ["Sticky", "Scroll away"], multiSelect: false)]
        let answered = ClaudeWorker.answering(input, questions: questions, with: "sticky")
        #expect(answered["answers"]?["Sticky?"] == "Sticky")
        #expect(answered["questions"] != nil)
        let free = ClaudeWorker.answering(input, questions: questions, with: "Only on mobile")
        #expect(free["answers"]?["Sticky?"] == "Only on mobile")
    }
}
