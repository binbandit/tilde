import Foundation
import Testing
import TildeMemory
import TildeSupport
import WorkerKit
@testable import TildeBrain

@MainActor
@Suite struct ManagerDeliveryRaceTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-delivery-race-\(UUID().uuidString)")

    @Test(.timeLimit(.minutes(1))) func aSuspendedSteerReceiptCannotJoinTheNextTurn() async throws {
        let manager = try manager()
        let outputs = DeliveryOutputs(manager)
        defer { outputs.task.cancel() }
        await manager.post(.init("First turn", tap: "first"))
        try await wait { outputs.reads == [["first"]] }
        let receipt = SuspendedDelivery()
        var steered = Manager.Message("Accepted in the first turn", tap: "steered")
        steered.onDelivery = { accepted in await receipt.receive(accepted) }
        await manager.post(steered)
        try await wait { await receipt.values == [true] }
        // A background message waits for the next turn while this receipt saves its agenda.
        await manager.post(.init("Next background turn"))
        try complete(1)
        try await wait { outputs.reads.contains([]) }
        await manager.post(.init("Second turn's question", tap: "second"))
        try await wait { outputs.reads.contains { $0.contains("second") } }
        await receipt.release()
        try await wait { outputs.reads.count == 4 }
        try complete(2)
        try await wait { outputs.finals.count == 2 }
        #expect(outputs.finals[0].taps == ["first", "steered"])
        #expect(outputs.finals[1].taps == ["second"])
        #expect(outputs.finals[1].text == "Reply 2")
        #expect(await receipt.values == [true])
        await manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func aSuspendedFailureReceiptCannotEndTheNextTurn() async throws {
        let manager = try manager(rejectFirst: true)
        let outputs = DeliveryOutputs(manager)
        defer { outputs.task.cancel() }
        let receipt = SuspendedDelivery()
        var rejected = Manager.Message("Rejected send", tap: "rejected")
        rejected.onDelivery = { accepted in await receipt.receive(accepted) }
        await manager.post(rejected)
        try await wait { await receipt.values == [false] }
        await manager.post(.init("Next background turn"))
        // The rejected process exits while the failure callback is still saving.
        try complete(1)
        try await wait { outputs.reads.contains([]) }
        await manager.post(.init("Second turn's question", tap: "second"))
        try await wait { outputs.reads.contains(["second"]) }
        await receipt.release()
        try await wait { outputs.undelivered == [["rejected"]] }
        #expect(await manager.isBusy)
        #expect(outputs.finals.allSatisfy { !$0.taps.contains("second") })
        try complete(2)
        try await wait { outputs.finals.count == 2 }
        #expect(outputs.finals.last?.text == "Reply 2")
        #expect(await receipt.values == [false])
        await manager.shutdown()
    }

    private func manager(rejectFirst: Bool = false) throws -> Manager {
        let memory = try Memory(home: TildeHome(root: root.appending(path: "home")))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_delivery_manager.py")
        let executable = root.appending(path: "fake-codex")
        try "#!/bin/sh\nFAKE_CONTROL='\(root.path)' FAKE_REJECT_FIRST=\(rejectFirst ? 1 : 0) exec /usr/bin/python3 -I '\(fixture.path)'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var config = Manager.Config()
        config.executable = executable.path
        return Manager(memory: memory, tools: Toolset(name: "fixture", instructions: "", tools: []), config: config)
    }

    private func complete(_ turn: Int) throws {
        try Data().write(to: root.appending(path: "complete-\(turn)"))
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

private actor SuspendedDelivery {
    var values: [Bool] = []
    var continuation: CheckedContinuation<Void, Never>?
    func receive(_ accepted: Bool) async {
        values.append(accepted)
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class DeliveryOutputs {
    var reads: [[String]] = []
    var undelivered: [[String]] = []
    var finals: [(taps: [String], text: String)] = []
    var task: Task<Void, Never>!

    init(_ manager: Manager) {
        task = Task { [weak self] in
            for await output in manager.outputs {
                guard let self else { return }
                if case .read(let taps) = output { reads.append(taps) }
                if case .undelivered(let taps, _) = output { undelivered.append(taps) }
                if case .replyDone(let taps, let text, _) = output { finals.append((taps, text)) }
            }
        }
    }
}
