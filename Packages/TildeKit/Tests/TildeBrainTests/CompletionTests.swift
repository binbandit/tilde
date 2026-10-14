import Foundation
import Testing
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

/// Signing work off, and what the owner can then do with it.
@MainActor @Suite(.serialized) struct CompletionTests {
    let fixture = ConductorFixture()

    @Test func noChangeResultIsAnnouncedAndAcknowledgedWithoutLanding() async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.finishedJob(conductor)
        let original = try await Git.head(fixture.repo)
        let finished = await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "No issues found."])
        #expect(!finished.isError, "\(finished.text)")
        #expect(conductor.job(job.id)?.reviewAction == .acknowledge)
        #expect(conductor.job(job.id)?.ticker == "Complete")
        #expect(conductor.thread.last?.text.contains("No issues found.") == true)
        await #expect(throws: ActionRefused.self) { try await conductor.land(job.id) }

        try await conductor.dismiss(job.id)
        #expect(conductor.job(job.id)?.phase == .done)
        #expect(try await Git.head(fixture.repo) == original)
        #expect(FileManager.default.fileExists(atPath: job.workdir))
        let restored = try fixture.restart(conductor)
        #expect(restored.job(job.id)?.phase == .done)
        #expect(restored.job(job.id)?.canDiscard == true)
        try await conductor.discard(job.id)
        #expect(!FileManager.default.fileExists(atPath: job.workdir))
        #expect(conductor.job(job.id)?.ticker == "Discarded")
    }

    @Test(arguments: [false, true])
    func oldCompletionCannotDiscardAReusedWorktree(acknowledged: Bool) async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.finishedJob(conductor)
        let branch = try #require(job.branch)
        if acknowledged {
            _ = await fixture.call(conductor, "finish", ["job": .string(job.id)])
            try await conductor.dismiss(job.id)
            #expect(conductor.job(job.id)?.canDiscard == true)
            await Git.removeWorktree(job, deleteBranch: true)
        } else {
            try "change".write(toFile: job.workdir + "/change.txt", atomically: true, encoding: .utf8)
            _ = await fixture.call(conductor, "finish", ["job": .string(job.id)])
            try await conductor.land(job.id)
            #expect(conductor.job(job.id)?.canDiscard == false)
        }
        _ = try await Git.addWorktree(repo: fixture.repo, path: job.workdir, branch: branch)
        var replacement = Job(id: "replacement", title: job.title, brief: "New task", projectName: "app",
                              repoPath: job.repoPath, workdir: job.workdir, harness: job.harness, isolation: .worktree)
        replacement.branch = branch
        replacement.phase = .working
        conductor.addJob(replacement)
        try "keep".write(toFile: job.workdir + "/replacement.txt", atomically: true, encoding: .utf8)
        try await conductor.discard(job.id)
        #expect(FileManager.default.fileExists(atPath: job.workdir + "/replacement.txt"))
        #expect(conductor.job(replacement.id)?.phase == .working)
        #expect(try await Git.currentBranch(job.workdir) == branch)
    }

    @Test func untrackedChangesNeedBringingIn() async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.finishedJob(conductor)
        try "new\n".write(toFile: job.workdir + "/new.txt", atomically: true, encoding: .utf8)
        let finished = await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "Changed a file."])
        #expect(!finished.isError)
        #expect(conductor.job(job.id)?.reviewAction == .bringIn)
        try await conductor.dismiss(job.id)
        #expect(conductor.job(job.id)?.phase == .ready)
    }

    @Test func changesAfterSignOffPreventAcknowledgement() async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.finishedJob(conductor)
        _ = await fixture.call(conductor, "finish", ["job": .string(job.id)])
        try "late change\n".write(toFile: job.workdir + "/late.txt", atomically: true, encoding: .utf8)
        await #expect(throws: ActionRefused.self) { try await conductor.dismiss(job.id) }
        #expect(conductor.job(job.id)?.phase == .ready)
        #expect(conductor.job(job.id)?.reviewAction == .bringIn)
    }

    @Test func anUnreadableWorktreeIsNotANoChangeResult() async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.finishedJob(conductor)
        conductor.update(job.id) { $0.baseCommit = "not-a-valid-commit" }
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "Done."]).isError)
        #expect(conductor.job(job.id)?.phase == .deciding)
        conductor.update(job.id) { $0.baseCommit = nil }
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
    }

    @Test func onlyAGoodTurnWithNothingOpenCanBeSignedOff() async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.delegate(conductor, to: worker)
        // Still working on its brief.
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)

        // A turn that failed.
        await worker.end(ok: false)
        try await fixture.waitFor { conductor.job(job.id)?.phase == .failed }
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)

        // A good turn, but a request of its worker's still open.
        try await conductor.deliver("Try again", to: job.id, from: .tilde)
        await worker.ask(WorkerRequest(id: "r-open", kind: .permission(tool: "Bash", action: "swift build", rail: nil)))
        await worker.end()
        try await fixture.waitFor { conductor.job(job.id)?.lastTurn == .succeeded }
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)

        // Stopped.
        await conductor.stop(job.id)
        #expect(await fixture.call(conductor, "finish", ["job": .string(job.id)]).isError)
        #expect(conductor.job(job.id)?.phase == .stopped)
    }

    @Test func aRestartDoesntRunAFinishedTurnAgain() async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.finishedJob(conductor, worker: worker)
        let next = try fixture.restart(conductor)
        next.resumeActive()
        // Sign-off waits for anything queued for the job, so a resumed turn would have cleared its outcome.
        let finished = await fixture.call(next, "finish", ["job": .string(job.id), "summary": "Done before the restart."])
        #expect(!finished.isError, "\(finished.text)")
        #expect(await worker.received.count == 1)
    }

    @Test func aGoodTurnCanStillBeSignedOffAfterARestart() async throws {
        let conductor = try await fixture.makeConductor()
        let job = try await fixture.finishedJob(conductor)
        _ = await fixture.call(conductor, "ask", ["question": "Ship it as is?", "options": ["Yes", "No"], "job": .string(job.id)])

        // The worker was done, so it isn't resumed; the owner's answer lets tilde sign it off.
        let next = try fixture.restart(conductor)
        next.resumeActive()
        next.answer(try #require(next.attention.first?.id), with: "Yes")
        let finished = await fixture.call(next, "finish", ["job": .string(job.id), "summary": "Shipped as is."])
        #expect(!finished.isError, "\(finished.text)")
        #expect(next.job(job.id)?.phase == .ready)
    }
}
