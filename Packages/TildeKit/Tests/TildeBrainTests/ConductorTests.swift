import Foundation
import Harnesses
import Testing
import TildeMemory
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

@MainActor
@Suite(.serialized) struct ConductorTests {
    let fixture = ConductorFixture()
    var repo: String { fixture.repo }

    @Test func delegateFinishAndLand() async throws {
        let conductor = try await fixture.makeConductor()
        let started = await fixture.call(conductor, "delegate", ["project_path": .string(repo), "title": "Nav bar", "brief": "Add a nav", "harness": "scripted"])
        #expect(!started.isError, "\(started.text)")
        let job = try #require(conductor.jobs.first)
        #expect(job.branch == "tilde/nav-bar")
        #expect(job.workdir.hasPrefix(fixture.root.appending(path: "home/worktrees/app").path))

        try await fixture.waitFor { conductor.jobs.first?.phase == .deciding }
        #expect(conductor.jobs.first?.diff?.files == 1)
        #expect(conductor.jobs.first?.sessionID == "scripted-1")

        let finished = await fixture.call(conductor, "finish", ["job": .string(job.id), "summary": "Added the nav."])
        #expect(!finished.isError, "\(finished.text)")
        #expect(conductor.jobs.first?.phase == .ready)

        try await conductor.land(job.id)
        #expect(FileManager.default.fileExists(atPath: "\(repo)/Nav.swift"))
        #expect(conductor.jobs.first?.phase == .landed)

        let note = try #require(conductor.memory.notebook.read("tasks/\(job.id).md"))
        #expect(note.contains("## Brief") && note.contains("Add a nav") && note.contains("Added the nav.") && note.contains("Landed"))
        #expect(conductor.memory.notebook.read(Notebook.journalName())?.contains("Nav bar") == true)
    }

    @Test func escalationsReachTheWorkerDirectly() async throws {
        let conductor = try await fixture.makeConductor()
        _ = await fixture.call(conductor, "delegate", ["project_path": .string(repo), "title": "Ship it", "brief": "Add a nav and push", "harness": "scripted"])
        let job = try #require(conductor.jobs.first)
        try await fixture.waitFor { conductor.jobs.first?.phase == .deciding }

        // The manager escalates the worker's push request to Brayden...
        let asked = await fixture.call(conductor, "ask", ["question": "Push the nav?", "options": ["Allow", "Don't allow"], "recommended": 1, "request": "r-push"])
        #expect(!asked.isError)
        let item = try #require(conductor.attention.first)
        #expect(item.isApproval && item.jobID == job.id)
        #expect(conductor.jobs.first?.phase == .needsYou)

        // ...and his answer goes straight to the worker.
        conductor.answer(item.id, with: "Don't allow")
        try await fixture.waitFor { conductor.jobs.first?.phase == .deciding && conductor.attention.isEmpty }
        let note = try #require(conductor.memory.notebook.read("tasks/\(job.id).md"))
        #expect(note.contains("git push: denied"))
    }

    @Test func theManagerAllowsWhatIsntARail() async throws {
        let conductor = try await fixture.makeConductor()
        let worker = FakeWorker()
        let job = try await fixture.delegate(conductor, to: worker)
        await worker.ask(WorkerRequest(id: "r-test", kind: .permission(tool: "Bash", action: "swift test", rail: nil)))
        try await fixture.waitFor { conductor.job(job.id)?.phase == .deciding }

        let allowed = await fixture.call(conductor, "respond", ["request": "r-test", "decision": "allow"])
        #expect(!allowed.isError, "\(allowed.text)")
        try await fixture.waitFor { await worker.answers["r-test"]?.isAllow == true }
        #expect(conductor.job(job.id)?.phase == .working)
        #expect(conductor.transcriptStore.load(job.id).contains { $0.kind == .decision && $0.from == .tilde && $0.text.contains("allowed") })
    }

    @Test func onlyTheOwnerAllowsARail() async throws {
        let conductor = try await fixture.makeConductor()
        _ = await fixture.call(conductor, "delegate", ["project_path": .string(repo), "title": "Ship it", "brief": "Add a nav and push", "harness": "scripted"])
        let job = try #require(conductor.jobs.first)
        try await fixture.waitFor { conductor.jobs.first?.phase == .deciding }

        // The manager can't wave a push through...
        let waved = await fixture.call(conductor, "respond", ["request": "r-push", "decision": "allow"])
        #expect(waved.isError && waved.text.contains("Pushes to a remote"))

        // ...the owner can, and "Always" then covers exactly that rail in that project.
        // A permission's answers are a plain yes and no, whatever the manager labelled them.
        _ = await fixture.call(conductor, "ask", ["question": "Push the nav?", "options": ["Allow push", "Deny"], "request": "r-push"])
        let item = try #require(conductor.attention.first)
        #expect(item.options == ["Allow", "Don't allow"])
        conductor.answer(item.id, with: "Allow", always: true)
        try await fixture.waitFor { conductor.attention.isEmpty && conductor.jobs.first?.phase != .needsYou }
        let push = WorkerRequest(id: "r-2", kind: .permission(tool: "Bash", action: "git push", rail: "Pushes to a remote"))
        let deploy = WorkerRequest(id: "r-3", kind: .permission(tool: "Bash", action: "vercel deploy --prod", rail: "Deploys"))
        #expect(conductor.unallowedRail(push, job: job.id) == nil)
        #expect(conductor.unallowedRail(deploy, job: job.id) == "Deploys")
        // Running outside the sandbox can't be allowed for good: it would cover anything.
        #expect(!conductor.allowAlways(Rails.outsideSandbox, job: job.id))
    }

    @Test func tildesOwnQuestionsOutliveARestartAndTheDay() async throws {
        let first = try await fixture.makeConductor()
        _ = await fixture.call(first, "ask", ["question": "Merge app#7?", "options": ["Merge", "Not now"]])
        let asked = try #require(first.attention.first)

        // The next launch (which restores it), on a new day's empty thread: still open, and still there to answer.
        let next = try fixture.restart(first)
        #expect(next.attention.map(\.id) == [asked.id])
        next.thread = []
        next.reconcileQuestions()
        #expect(next.attention.map(\.id) == [asked.id])
        #expect(next.thread.map(\.attentionID) == [asked.id])
        #expect(next.thread.first?.at == asked.createdAt)
    }

    @Test func aJobWaitingOnTildesQuestionStaysPutThroughARestart() async throws {
        let first = try await fixture.makeConductor()
        _ = await fixture.call(first, "delegate", ["project_path": .string(repo), "title": "Nav bar", "brief": "Add a nav", "harness": "scripted"])
        let job = try #require(first.jobs.first)
        try await fixture.waitFor { first.jobs.first?.phase == .deciding }
        _ = await fixture.call(first, "ask", ["question": "Ship app#7 as is?", "options": ["Yes", "No"], "job": .string(job.id)])
        #expect(first.jobs.first?.phase == .needsYou)

        // Its worker had finished its turn; a restart leaves it waiting on the question, not working again.
        let next = try fixture.restart(first)
        next.resumeActive()
        #expect(next.jobs.first?.phase == .needsYou)
        #expect(next.attention.map(\.jobID) == [job.id])
    }

    @Test func wordsThatNeverReachTheModelSaySoAndCanBeSentAgain() async throws {
        var config = fixture.config
        config.initiative = false
        let conductor = try Conductor(home: TildeHome(root: fixture.root.appending(path: "home")), config: config)
        try await conductor.start()  // its manager is /usr/bin/false: nothing gets through

        conductor.tap("how many PRs are open?", context: TapContext(pointing: "oh-fx · Ghostty"))
        try await fixture.waitFor { conductor.thread.first?.delivery.map { if case .failed = $0 { true } else { false } } ?? false }
        #expect(conductor.thread.map(\.from) == [.you])  // no empty reply left waiting

        conductor.retry(conductor.thread[0].id)
        #expect(conductor.thread.map(\.text) == ["how many PRs are open?", ""])
        #expect(conductor.thread[0].delivery == .sent && conductor.thread[0].pointing == "oh-fx · Ghostty")
    }

    @Test(.timeLimit(.minutes(1))) func whatYouSayMidTurnJoinsItAndGetsOneReply() async throws {
        let codex = try FakeCodex(in: fixture.root, scenario: "quiet")
        var config = fixture.config
        config.initiative = false
        config.manager.executable = codex.executable
        let conductor = try Conductor(home: TildeHome(root: fixture.root.appending(path: "home")), config: config)
        try await conductor.start()

        // The first turn is still going when the second thing is said.
        conductor.tap("first")
        try await fixture.waitFor { codex.requests("turn/start").count == 1 }
        conductor.tap("second")
        try await fixture.waitFor { conductor.thread.last?.streaming == false }

        #expect(conductor.thread.map(\.from) == [.you, .you, .tilde])
        #expect(conductor.thread.last?.text.hasPrefix("You said") == true)
        #expect(conductor.thread.prefix(2).allSatisfy { if case .read = $0.delivery { true } else { false } })
    }

    @Test func aReplyARestartCutOffSaysSoInsteadOfTypingForever() async throws {
        let conductor = try await fixture.makeConductor()
        var said = Message(from: .you, text: "how are my PRs?")
        said.delivery = .read(.now)
        conductor.thread = [said, Message(from: .tilde, text: "", streaming: true)]
        conductor.settleInterrupted()
        #expect(conductor.thread.map(\.from) == [.you])
        // It was read, so it says there was no reply rather than that it wasn't delivered.
        guard case .failed(_, read: .some) = conductor.thread[0].delivery else { Issue.record("not marked unanswered"); return }
    }

    @Test func aQuestionAskedJustAfterMidnightIsAskedOnce() async throws {
        let conductor = try await fixture.makeConductor()
        conductor.thread = [Message(from: .you, text: "night", at: .now.addingTimeInterval(-86_400))]
        conductor.threadDay = .now.addingTimeInterval(-86_400)
        _ = await fixture.call(conductor, "ask", ["question": "Merge app#7?", "options": ["Merge", "Not now"]])
        #expect(conductor.thread.filter { $0.attentionID != nil }.count == 1)
    }

    @Test func scratchJobsNeedNoRepo() async throws {
        let conductor = try await fixture.makeConductor()
        let started = await fixture.call(conductor, "delegate", ["title": "Check the app", "brief": "Look at it", "harness": "scripted"])
        #expect(!started.isError, "\(started.text)")
        let job = try #require(conductor.jobs.first)
        #expect(job.isolation == .scratch && job.branch == nil)
        #expect(job.workdir.hasPrefix(fixture.root.appending(path: "home/scratch").path))
    }

    @Test func delegatePassesTheModelToTheWorker() async throws {
        let conductor = try await fixture.makeConductor()
        let (harness, launches) = fixture.harness { ScriptedWorker(workdir: $0.workdir) }
        let started = await fixture.call(conductor, "delegate", [
            "project_path": .string(repo), "title": "Nav bar", "brief": "Add a nav", "harness": .string(harness.rawValue), "model": "opus",
        ])
        #expect(!started.isError, "\(started.text)")
        #expect(conductor.jobs.first?.model == "opus")
        #expect(launches.all.map(\.model) == ["opus"])
    }

    @Test func steeringAStoppedWorkerResumesItsSession() async throws {
        let conductor = try await fixture.makeConductor()
        let (harness, launches) = fixture.harness { ScriptedWorker(workdir: $0.workdir) }
        _ = await fixture.call(conductor, "delegate", ["project_path": .string(repo), "title": "Nav bar", "brief": "Add a nav", "harness": .string(harness.rawValue)])
        let job = try #require(conductor.jobs.first)
        try await fixture.waitFor { conductor.jobs.first?.sessionID == "scripted-1" }

        _ = await fixture.call(conductor, "stop", ["job": .string(job.id)])
        let steered = await fixture.call(conductor, "steer", ["job": .string(job.id), "message": "Make it sticky"])
        #expect(!steered.isError, "\(steered.text)")
        #expect(launches.all.count == 2)
        let resumed = try #require(launches.all.last)
        #expect(resumed.resume && resumed.sessionID == "scripted-1")
    }

    @Test func unknownHarnessesAreRefused() async throws {
        let conductor = try await fixture.makeConductor()
        let result = await fixture.call(conductor, "delegate", ["project_path": .string(repo), "title": "X", "brief": "Y", "harness": "nonexistent"])
        #expect(result.isError && result.text.contains("Installed:"))
    }
}
