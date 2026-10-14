import Foundation
import Testing
import TildeMemory
import TildeSupport
import WorkerKit
@testable import TildeBrain

/// How the manager's turns end up in the conversation: a reply streamed and saved once, or a failure said
/// once, after which the next message still gets through.
@MainActor
@Suite(.serialized) struct ManagerTurnTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-manager-turns-\(UUID().uuidString)")

    @Test(.timeLimit(.minutes(1)), arguments: ["error", "notice-only", "error-exit", "error-drop"])
    func aFailedTurnSaysSoOnceAndTheNextGetsThrough(_ scenario: String) async throws {
        let (conductor, codex) = try makeConductor(scenario)
        let outputs = Outputs(conductor)
        defer { outputs.task.cancel() }
        for _ in 1...2 {
            let tap = conductor.tap("hi")
            try await waitFor { conductor.thread.last?.id == tap && conductor.thread.last?.streaming == false }
            #expect(conductor.thread.last?.trouble == true)
        }
        try await barrier(conductor)
        #expect(outputs.troubles == 2 && outputs.finals == 3)
        #expect(conductor.thread.map(\.from) == [.you, .tilde, .you, .tilde, .you, .tilde])
        #expect(conductor.thread.filter(\.trouble).count == 2)
        #expect(ThreadStore(home: conductor.home).load().map(\.text) == conductor.thread.map(\.text))
        #expect(codex.requests("turn/start").count == 3)
        #expect(codex.requests("thread/start").first?["params"]?["model"]?.isNull == true)
        await conductor.manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["answer", "retry", "duplicate-completion"])
    func aStreamedReplyIsSavedOnce(_ scenario: String) async throws {
        let (conductor, _) = try makeConductor(scenario)
        let outputs = Outputs(conductor)
        defer { outputs.task.cancel() }
        conductor.tap("hi")
        try await barrier(conductor)
        #expect(outputs.troubles == 0 && outputs.finals == 2)
        #expect(outputs.streamed == ["Hello ", "Hello once."])
        #expect(conductor.thread.map(\.text) == ["hi", "Hello once.", "BARRIER", "Done."])
        #expect(ThreadStore(home: conductor.home).load().map(\.text) == conductor.thread.map(\.text))
        await conductor.manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func aTurnThatRunsTooLongIsStoppedOnce() async throws {
        let (conductor, codex) = try makeConductor("cancel", turnLimit: 0.1)
        let outputs = Outputs(conductor)
        defer { outputs.task.cancel() }
        conductor.tap("hi")
        try await waitFor { outputs.finals == 1 }
        try await barrier(conductor)
        #expect(outputs.troubles == 1 && outputs.finals == 2)
        #expect(conductor.thread.map(\.from) == [.you, .tilde, .you, .tilde])
        #expect(codex.requests("turn/interrupt").count == 1)
        await conductor.manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func ownThreadsInheritOrOverrideTheConfiguredModel(_ explicit: Bool) async throws {
        let model = explicit ? "@work/model" : nil
        let provider = explicit ? "portkey" : nil
        let (conductor, codex) = try makeConductor("answer", model: model, provider: provider)
        let outputs = Outputs(conductor)
        defer { outputs.task.cancel() }
        conductor.tap("hi")
        try await waitFor { outputs.finals == 1 }
        let pass = ModelPass(instructions: "Local fixture", prompt: "hi", workdir: root.path)
        let memory = try await CodexMemoryModel(model: model, effort: "low", executable: codex.executable, modelProvider: provider).run(pass)
        let review = try await CodexReviewModel(model: model, executable: codex.executable, modelProvider: provider).run(pass)
        #expect(memory.ok && review.ok && memory.text == "Hello once." && review.text == memory.text)
        let starts = codex.requests("thread/start")
        #expect(starts.count == 3)
        for start in starts {
            #expect(start["params"]?["model"] == (model.map(JSON.string) ?? .null))
            #expect(start["params"]?["modelProvider"] == (provider.map(JSON.string) ?? .null))
        }
        await conductor.manager.shutdown()
    }

    private func makeConductor(
        _ scenario: String, model: String? = nil, provider: String? = nil, turnLimit: TimeInterval = 300
    ) throws -> (Conductor, FakeCodex) {
        let codex = try FakeCodex(in: root, scenario: scenario)
        var config = Conductor.Config()
        config.projectRoots = []
        config.initiative = false
        config.manager.executable = codex.executable
        config.manager.model = model
        config.manager.modelProvider = provider
        config.manager.turnLimit = turnLimit
        config.manager.stallAfter = 1
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        return (try Conductor(home: TildeHome(root: root.appending(path: "home")), config: config), codex)
    }

    /// Says something the fake always answers "Done." to, and waits for that: whatever the turns before
    /// it had to say has been said by then.
    private func barrier(_ conductor: Conductor) async throws {
        conductor.tap("BARRIER")
        try await waitFor { conductor.thread.last?.text == "Done." && conductor.thread.last?.streaming == false }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}

/// Hands the manager's outputs to the conductor (which isn't started here), counting them on the way.
@MainActor
private final class Outputs {
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
}
