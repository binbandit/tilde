import Foundation
import Synchronization
import Testing
import TildeMemory
import TildeSupport
import WorkerKit
@testable import TildeBrain

@MainActor
@Suite struct ManagerSteerReceiptTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-steer-receipt-\(UUID().uuidString)")
    private let effects = Recorded<String>()

    /// Codex can finish a turn before it confirms what was steered into it. Once it does, that joins the
    /// turn's reply: asking it again in a turn of its own would carry it out twice.
    @Test(.timeLimit(.minutes(1))) func acceptedSteerCompletedBeforeItsReceiptRunsOnlyOnce() async throws {
        let codex = try FakeCodex(in: root, scenario: "steer-receipt")
        let manager = try manager(codex)
        let outputs = Outputs(manager)
        defer { outputs.task.cancel() }
        await manager.post(.init("Initial turn", tap: "first"))
        try await wait { outputs.reads == [["first"]] }
        let receipts = Recorded<Bool>()
        var steered = Manager.Message("STEER_EFFECT", tap: "steered")
        steered.onDelivery = { accepted in receipts.append(accepted) }
        await manager.post(steered)

        try await wait {
            let busy = await manager.isBusy
            return effects.all.count == 1 && !busy
        }
        #expect(outputs.finals.isEmpty)
        try codex.release()
        try await wait { outputs.finals.count == 1 }
        #expect(outputs.finals.first?.taps == ["first", "steered"])
        #expect(outputs.finals.first?.text == "Applied it.")
        #expect(outputs.finals.first?.said == "Initial turn\nSTEER_EFFECT")
        try await wait { receipts.all == [true] }
        #expect(effects.all.count == 1)
        #expect(codex.requests("turn/start").count == 1)
        await manager.shutdown()
    }

    private func manager(_ codex: FakeCodex) throws -> Manager {
        let memory = try Memory(home: TildeHome(root: root.appending(path: "home")))
        let effect = AgentTool("fixture_effect", "Record a scratch effect", schema: AgentTool.object(["instruction": .text("Fixture text")])) { [effects] args in
            effects.append(args["instruction"]?.string ?? "")
            return .ok("Recorded")
        }
        var config = Manager.Config()
        config.executable = codex.executable
        return Manager(memory: memory, tools: Toolset(name: "fixture", instructions: "", tools: [effect]), config: config)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitExpired()
    }
    private struct WaitExpired: Error {}
}

@MainActor
private final class Outputs {
    var reads: [[String]] = []
    var finals: [(taps: [String], text: String, said: String)] = []
    var task: Task<Void, Never>!
    init(_ manager: Manager) {
        task = Task { [weak self] in
            for await output in manager.outputs {
                guard let self else { return }
                if case .read(let taps) = output { reads.append(taps) }
                if case .replyDone(let taps, let text, let said) = output { finals.append((taps, text, said)) }
            }
        }
    }
}

private final class Recorded<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    var all: [Value] { values.withLock { $0 } }
    func append(_ value: Value) { values.withLock { $0.append(value) } }
}
