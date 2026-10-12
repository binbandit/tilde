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
    private let effects = SteerEffects()

    @Test(.timeLimit(.minutes(1))) func acceptedSteerCompletedBeforeItsReceiptRunsOnlyOnce() async throws {
        let manager = try manager("single")
        let outputs = SteerOutputs(manager)
        defer { outputs.task.cancel() }
        await manager.post(.init("Initial turn", tap: "first"))
        try await wait { outputs.reads == [["first"]] }
        let receipts = SteerReceipts()
        await manager.post(message("accepted", receipts))
        try await wait { let idle = await !manager.isBusy; return marker("completed-1") && idle }
        #expect(effects.values.withLock { $0.count } == 1)
        #expect(outputs.finals.isEmpty)
        try release(1)
        try await wait { outputs.finals.contains { $0.taps.contains("accepted") } }
        try await wait { await receipts.values["accepted"] == [true] }
        #expect(effects.values.withLock { $0.count } == 1)
        #expect(outputs.finals.count == 1)
        #expect(outputs.finals.first?.taps == ["first", "accepted"])
        #expect(outputs.finals.first?.text == "Applied 1 effect(s).")
        #expect(outputs.finals.first?.said == "Initial turn\nSTEER_EFFECT accepted")
        #expect(await receipts.values == ["accepted": [true]])
        #expect(try requests().filter { $0["text"]?.string?.contains("STEER_EFFECT") == true }.count == 1)
        await manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func overlappingReceiptsKeepTheirCompletedReplySeparateFromTheNextTurn() async throws {
        let manager = try manager("overlap")
        let outputs = SteerOutputs(manager)
        defer { outputs.task.cancel() }
        await manager.post(.init("Initial turn", tap: "first"))
        try await wait { outputs.reads == [["first"]] }
        let receipts = SteerReceipts()
        await manager.post(message("one", receipts))
        try await wait { (try? requests().filter { $0["method"]?.string == "turn/steer" }.count) == 1 }
        await manager.post(message("two", receipts))
        try await wait { let idle = await !manager.isBusy; return marker("completed-1") && idle }
        await manager.post(.init("A newer turn", tap: "newer"))
        try await wait { outputs.reads.contains(["newer"]) }
        // Acknowledgements arrive out of order while the newer turn stays active.
        try release(2)
        try await wait { await receipts.values["two"] == [true] }
        #expect(outputs.finals.isEmpty)
        try release(1)
        try await wait { outputs.finals.count == 1 }
        #expect(outputs.finals[0].taps == ["first", "one", "two"])
        #expect(outputs.finals[0].text == "Applied 2 effect(s).")
        #expect(outputs.finals[0].said == "Initial turn\nSTEER_EFFECT one\nSTEER_EFFECT two")
        #expect(await manager.isBusy)
        try Data().write(to: root.appending(path: "complete-2"))
        try await wait { outputs.finals.count == 2 }
        #expect(outputs.finals[1].taps == ["newer"])
        #expect(outputs.finals[1].text == "Reply 2")
        #expect(effects.values.withLock { $0.count } == 2)
        #expect(await receipts.values == ["one": [true], "two": [true]])
        await manager.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func aRejectedSteerRetriesWithoutReplayingTheAcceptedOne() async throws {
        let manager = try manager("reject")
        let outputs = SteerOutputs(manager)
        defer { outputs.task.cancel() }
        await manager.post(.init("Initial turn", tap: "first"))
        try await wait { outputs.reads == [["first"]] }
        let receipts = SteerReceipts()
        await manager.post(message("accepted", receipts))
        try await wait { (try? requests().filter { $0["method"]?.string == "turn/steer" }.count) == 1 }
        await manager.post(message("rejected", receipts))
        try await wait { let idle = await !manager.isBusy; return marker("completed-1") && idle }
        try release(2)
        try await wait { outputs.finals.contains { $0.taps == ["rejected"] } }
        try release(1)
        try await wait { outputs.finals.count == 2 }
        try await wait { await receipts.values["accepted"] == [true] }
        #expect(outputs.finals.contains { $0.taps == ["first", "accepted"] && $0.text == "Applied 1 effect(s)." })
        #expect(effects.values.withLock { $0.filter { $0.contains("STEER_EFFECT accepted") }.count } == 1)
        #expect(effects.values.withLock { $0.filter { $0.contains("STEER_EFFECT rejected") }.count } == 1)
        #expect(await receipts.values == ["accepted": [true], "rejected": [true]])
        await manager.shutdown()
    }

    private func message(_ id: String, _ receipts: SteerReceipts) -> Manager.Message {
        var message = Manager.Message("STEER_EFFECT \(id)", tap: id)
        message.onDelivery = { accepted in await receipts.record(id, accepted) }
        return message
    }

    private func manager(_ scenario: String) throws -> Manager {
        let memory = try Memory(home: TildeHome(root: root.appending(path: "home")))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_steer_receipts.py")
        let executable = root.appending(path: "fake-codex")
        try "#!/bin/sh\nFAKE_CONTROL='\(root.path)' FAKE_SCENARIO='\(scenario)' exec /usr/bin/python3 -I '\(fixture.path)'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let effect = AgentTool("fixture_effect", "Record a scratch effect", schema: AgentTool.object(["instruction": .text("Fixture text")])) { args in
            effects.values.withLock { $0.append(args["instruction"]?.string ?? "") }
            return .ok("Recorded")
        }
        var config = Manager.Config()
        config.executable = executable.path
        return Manager(memory: memory, tools: Toolset(name: "fixture", instructions: "", tools: [effect]), config: config)
    }

    private func requests() throws -> [JSON] {
        try String(contentsOf: root.appending(path: "requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { JSON.parse(String($0)) }
    }
    private func marker(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: name).path) }
    private func release(_ index: Int) throws { try Data().write(to: root.appending(path: "release-\(index)")) }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitExpired()
    }
    private struct WaitExpired: Error {}
}

private actor SteerReceipts {
    var values: [String: [Bool]] = [:]
    func record(_ id: String, _ accepted: Bool) { values[id, default: []].append(accepted) }
}

@MainActor
private final class SteerOutputs {
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

private final class SteerEffects: Sendable {
    let values = Mutex<[String]>([])
}
