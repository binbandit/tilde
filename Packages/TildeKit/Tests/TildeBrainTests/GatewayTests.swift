import Foundation
import Testing
import TildeMemory
import TildeSupport
import WorkerKit
@testable import TildeBrain

@MainActor
@Suite(.serialized) struct GatewayTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-gateway-\(UUID().uuidString)")

    @Test(.timeLimit(.minutes(1)), arguments: ["error", "notice-only", "error-exit", "error-drop"])
    func aFailedGatewayTurnHasOneErrorAndCanBeAskedAgain(_ scenario: String) async throws {
        let conductor = try makeConductor(scenario)
        let outputs = GatewayOutputs(conductor)
        defer { outputs.task.cancel() }
        for turn in 1...2 {
            let tap = conductor.tap("hi")
            try await outputs.waitForFinals(turn)
            #expect(outputs.troubles == turn)
            #expect(outputs.finals == turn)
            #expect(conductor.thread.filter { $0.id == tap }.allSatisfy { $0.trouble && !$0.streaming })
        }
        #expect(conductor.thread.map(\.from) == [.you, .tilde, .you, .tilde])
        #expect(conductor.thread.filter(\.trouble).count == 2)
        #expect(ThreadStore(home: conductor.home).load().map(\.text) == conductor.thread.map(\.text))
        let requests = try requests()
        #expect(requests.filter { $0["method"]?.string == "turn/start" }.count == 2)
        let start = try #require(requests.first { $0["method"]?.string == "thread/start" })
        #expect(start["params"]?["model"]?.isNull == true)
        await conductor.manager.shutdown()
        try await Task.sleep(for: .milliseconds(30))
        #expect(outputs.troubles == 2 && outputs.finals == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["success", "retry", "duplicate-completion"])
    func streamingAndFinalTextBecomeOneSavedReply(_ scenario: String) async throws {
        let conductor = try makeConductor(scenario)
        let outputs = GatewayOutputs(conductor)
        defer { outputs.task.cancel() }
        conductor.tap("hi")
        try await outputs.waitForFinals(1)
        #expect(outputs.troubles == 0)
        #expect(outputs.finals == 1)
        #expect(outputs.streamed == ["Hello ", "Hello once."])
        #expect(conductor.thread.map(\.text) == ["hi", "Hello once."])
        #expect(conductor.thread.last?.streaming == false)
        #expect(ThreadStore(home: conductor.home).load().map(\.text) == ["hi", "Hello once."])
        await conductor.manager.shutdown()
        try await Task.sleep(for: .milliseconds(30))
        #expect(outputs.troubles == 0 && outputs.finals == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aStoppedTurnEndsOnce() async throws {
        let conductor = try makeConductor("cancel")
        let outputs = GatewayOutputs(conductor)
        defer { outputs.task.cancel() }
        conductor.tap("hi")
        try await outputs.waitForFinals(1)
        #expect(outputs.troubles == 1)
        #expect(outputs.finals == 1)
        #expect(conductor.thread.map(\.from) == [.you, .tilde])
        #expect(conductor.thread.last?.streaming == false)
        #expect(try requests().filter { $0["method"]?.string == "turn/interrupt" }.count == 1)
        await conductor.manager.shutdown()
        try await Task.sleep(for: .milliseconds(30))
        #expect(outputs.troubles == 1 && outputs.finals == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func ownThreadsInheritOrExplicitlyOverrideTheGatewayModel(_ explicit: Bool) async throws {
        let conductor = try makeConductor("success", model: explicit ? "@work/model" : nil, provider: explicit ? "portkey" : nil)
        let outputs = GatewayOutputs(conductor)
        defer { outputs.task.cancel() }
        conductor.tap("hi")
        try await outputs.waitForFinals(1)
        let executable = root.appending(path: "codex").path
        let model = explicit ? "@work/model" : nil
        let provider = explicit ? "portkey" : nil
        let pass = ModelPass(instructions: "Local fixture", prompt: "hi", workdir: root.path)
        let memory = try await CodexMemoryModel(model: model, effort: "low", executable: executable, modelProvider: provider).run(pass)
        let review = try await CodexReviewModel(model: model, executable: executable, modelProvider: provider).run(pass)
        #expect(memory.ok && review.ok && memory.text == "Hello once." && review.text == memory.text)
        let starts = try requests().filter { $0["method"]?.string == "thread/start" }
        #expect(starts.count == 3)
        for start in starts {
            #expect(start["params"]?["model"] == (model.map(JSON.string) ?? .null))
            #expect(start["params"]?["modelProvider"] == (provider.map(JSON.string) ?? .null))
        }
        await conductor.manager.shutdown()
    }

    private func makeConductor(_ scenario: String, model: String? = nil, provider: String? = nil) throws -> Conductor {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_gateway_session.py")
        let executable = root.appending(path: "codex")
        try "#!/bin/sh\nFAKE_SCENARIO='\(scenario)' FAKE_OUT='\(root.appending(path: "requests.jsonl").path)' exec /usr/bin/python3 -I '\(fixture.path)'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var config = Conductor.Config()
        config.projectRoots = []
        config.initiative = false
        config.manager.executable = executable.path
        config.manager.model = model
        config.manager.modelProvider = provider
        config.manager.turnLimit = scenario == "cancel" ? 0.1 : 300
        config.manager.stallAfter = 1
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        return try Conductor(home: TildeHome(root: root.appending(path: "home")), config: config)
    }

    private func requests() throws -> [JSON] {
        try String(contentsOf: root.appending(path: "requests.jsonl"), encoding: .utf8).split(separator: "\n").compactMap { JSON.parse(String($0)) }
    }
}

/// Keeps observing after completion, so duplicate finals and exit errors are counted too.
@MainActor
private final class GatewayOutputs {
    var troubles = 0
    var finals = 0
    var streamed: [String] = []
    var task: Task<Void, Never>!

    init(_ conductor: Conductor) {
        task = Task { [weak self] in
            for await output in conductor.manager.outputs {
                guard let self else { return }
                conductor.handle(output)
                if case .trouble = output { troubles += 1 }
                if case .reply(_, let text) = output { streamed.append(text) }
                if case .replyDone = output { finals += 1 }
            }
        }
    }

    func waitForFinals(_ expected: Int) async throws {
        for _ in 0..<500 where finals < expected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finals >= expected)
        // The deterministic fixture writes completion/exit notifications together.
        try await Task.sleep(for: .milliseconds(30))
    }
}
