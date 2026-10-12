import Foundation
import Harnesses
import Testing
import TildeSupport
import TildeWork
import WorkerKit
@testable import TildeBrain

private actor ApprovalWorker: Worker {
    nonisolated let events: AsyncStream<WorkerEvent>
    private let emit: AsyncStream<WorkerEvent>.Continuation
    private(set) var answers: [WorkerAnswer] = []

    init() { (events, emit) = AsyncStream.makeStream() }
    func start(brief: String) async throws {}
    func steer(_ text: String) async throws {}
    func resolve(_ requestID: String, _ answer: WorkerAnswer) { answers.append(answer) }
    func stop() async { emit.finish() }
    func request(_ request: WorkerRequest) { emit.yield(.request(request)) }
}

@MainActor @Suite(.serialized) struct AutomaticApprovalTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-automatic-approval-\(UUID().uuidString)")

    private func fixture() throws -> (Conductor, ApprovalWorker, Job) {
        let workdir = root.appending(path: "work")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        var config = Conductor.Config()
        config.initiative = false
        config.projectRoots = []
        config.manager.executable = "/usr/bin/false"
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        let conductor = try Conductor(home: TildeHome(root: root.appending(path: "home")), config: config)
        let worker = ApprovalWorker()
        var job = Job(
            id: "approval-job", title: "Approval fixture", brief: "List the job folder", projectName: "Fixture",
            repoPath: workdir.path, workdir: workdir.path, harness: Harness(rawValue: "approval-fixture"), isolation: .scratch)
        job.phase = .working
        conductor.addJob(job)
        conductor.workers[job.id] = worker
        return (conductor, worker, job)
    }

    private func permission(_ job: Job, id: String = "permission", command: String? = nil, metadata: Bool = true, rail: String? = nil) -> WorkerRequest {
        let input: JSON = ["command": .string(command ?? "/bin/ls '\(job.workdir)'")]
        return WorkerRequest(
            id: id, kind: .permission(tool: "Bash", action: "safe according to the model", rail: rail),
            permissionContext: metadata ? PermissionContext(source: .claudeToolCallback, tool: "Bash", input: input, workdir: job.workdir) : nil)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    private func pending(_ request: WorkerRequest, in conductor: Conductor, job: Job) {
        conductor.requests[request.id] = (job.id, request)
    }

    @Test func permissionRequestsDefaultToOwnerAndCannotBeDisguisedAsAnswers() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        let request = permission(job)
        pending(request, in: conductor, job: job)
        #expect(!conductor.automaticApprovalEnabled(for: job.id))
        for decision in ["allow", "answer", "anything"] {
            let response = await conductor.makeTools().call("respond", ["request": .string(request.id), "decision": .string(decision), "text": "allow"])
            #expect(response.isError)
            #expect(conductor.requests[request.id] != nil)
        }
        #expect(!conductor.resolve(request.id, .allow, by: .tilde))
        #expect(!conductor.resolve(request.id, .reply("allow"), by: .tilde))
        #expect(!conductor.resolve(request.id, .allow, by: .agent))
        #expect(await worker.answers.isEmpty)
        #expect(conductor.resolve(request.id, .allow, by: .you))
        try await eventually { conductor.transcriptStore.load(job.id).filter { $0.kind == .decision }.count == 1 }
        #expect(await worker.answers.count == 1)
        #expect(conductor.transcriptStore.load(job.id).filter { $0.kind == .decision }.count == 1)
        #expect(conductor.transcriptStore.load(job.id).last?.from == .you)
        await conductor.stopWorker(job.id)
    }

    @Test func optInIsPerJobRuntimeOnlyAndDoesNotAllowUnknownOrDangerousInputs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        #expect(conductor.setAutomaticApproval(true, for: job.id))
        #expect(!conductor.setAutomaticApproval(true, for: "missing"))
        let commands = ["/bin/ls '\(job.workdir)' && git push", "rm -rf .", "curl https://example.com", "/bin/cat .env", "/bin/ls .."]
        for (index, command) in commands.enumerated() {
            let request = permission(job, id: "unsafe-\(index)", command: command)
            pending(request, in: conductor, job: job)
            #expect(!conductor.resolve(request.id, .allow, by: .tilde))
        }
        let unknown = permission(job, id: "unknown", metadata: false)
        pending(unknown, in: conductor, job: job)
        #expect(!conductor.resolve(unknown.id, .allow, by: .tilde))
        let safe = permission(job, id: "safe")
        pending(safe, in: conductor, job: job)
        let allowed = await conductor.makeTools().call("respond", ["request": "safe", "decision": "allow"])
        #expect(!allowed.isError)
        try await eventually { conductor.transcriptStore.load(job.id).last?.kind == .decision }
        #expect(await worker.answers.count == 1)
        #expect(conductor.transcriptStore.load(job.id).last?.text.contains("bounded automatic approval") == true)

        var other = Job(
            id: "other", title: "Other", brief: "Other", projectName: "Other", repoPath: job.repoPath,
            workdir: job.workdir, harness: job.harness, isolation: .scratch)
        other.phase = .working
        conductor.addJob(other)
        conductor.workers[other.id] = ApprovalWorker()
        let another = permission(other, id: "another")
        pending(another, in: conductor, job: other)
        #expect(!conductor.resolve(another.id, .allow, by: .tilde))
        #expect(!conductor.automaticApprovalEnabled(for: other.id))
        let modelOptIn = await conductor.makeTools().call("setAutomaticApproval", ["enabled": true, "job": .string(other.id)])
        #expect(modelOptIn.isError)

        let restarted = try Conductor(home: conductor.home, config: {
            var config = Conductor.Config()
            config.manager.executable = "/usr/bin/false"
            config.scribe.executable = "/usr/bin/false"
            config.dream.executable = "/usr/bin/false"
            config.initiative = false
            config.projectRoots = []
            return config
        }())
        #expect(restarted.automaticApprovalJobs.isEmpty)
        await conductor.stopWorker(job.id)
        await conductor.stopWorker(other.id)
        #expect(!conductor.automaticApprovalEnabled(for: job.id))
    }

    @Test func revokedQueuedApprovalStaysPendingWithoutAnAllowedAudit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        #expect(conductor.setAutomaticApproval(true, for: job.id))
        let request = permission(job)
        pending(request, in: conductor, job: job)
        #expect(conductor.resolve(request.id, .allow, by: .tilde))
        #expect(conductor.setAutomaticApproval(false, for: job.id))
        try await eventually { conductor.requests[request.id] != nil }
        #expect(await worker.answers.isEmpty)
        #expect(conductor.transcriptStore.load(job.id).allSatisfy { $0.kind != .decision })
        await conductor.stopWorker(job.id)
    }

    @Test func ownerOptInAlsoResolvesAnAlreadyPendingSupportedRequest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        let request = permission(job)
        pending(request, in: conductor, job: job)
        conductor.raise(Attention(
            id: "attention", jobID: job.id, question: "List this folder?", options: ["Allow", "Don't allow"],
            recommended: 0, detail: nil, requestID: request.id, isApproval: true))
        #expect(conductor.setAutomaticApproval(true, for: job.id))
        try await eventually { conductor.transcriptStore.load(job.id).last?.kind == .decision }
        #expect(await worker.answers.count == 1)
        #expect(conductor.requests.isEmpty)
        #expect(conductor.attention.isEmpty)
        #expect(conductor.job(job.id)?.phase == .working)
        let audit = try #require(conductor.transcriptStore.load(job.id).last)
        #expect(audit.from == .tilde)
        #expect(audit.text.contains(request.id) && audit.text.contains("/bin/ls '\(job.workdir)'"))
        #expect(audit.text.contains("Owner enabled bounded automatic approval"))
        await conductor.stopWorker(job.id)
    }

    @Test func resolvingOneRequestPreservesOtherPendingOwnerAttention() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        let safe = permission(job, id: "safe")
        let unknown = permission(job, id: "unknown", metadata: false)
        pending(safe, in: conductor, job: job)
        pending(unknown, in: conductor, job: job)
        conductor.raise(Attention(
            id: "unknown-attention", jobID: job.id, question: "Allow unknown tool?", options: ["Allow", "Don't allow"],
            recommended: 1, detail: nil, requestID: unknown.id, isApproval: true))
        #expect(conductor.setAutomaticApproval(true, for: job.id))
        try await eventually { conductor.transcriptStore.load(job.id).last?.kind == .decision }
        #expect(await worker.answers.count == 1)
        #expect(conductor.requests.keys.sorted() == [unknown.id])
        #expect(conductor.attention.map(\.requestID) == [unknown.id])
        #expect(conductor.job(job.id)?.phase == .needsYou)
        #expect(conductor.resolve(unknown.id, .deny("Do not allow it."), by: .tilde))
        try await eventually { conductor.transcriptStore.load(job.id).filter { $0.kind == .decision }.count == 2 }
        #expect(conductor.requests.isEmpty && conductor.attention.isEmpty)
        #expect(conductor.job(job.id)?.phase == .working)
        await conductor.stopWorker(job.id)
    }

    @Test func stoppingOrReplacingTheWorkerCancelsAQueuedApproval() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        #expect(conductor.setAutomaticApproval(true, for: job.id))
        let request = permission(job)
        pending(request, in: conductor, job: job)
        #expect(conductor.resolve(request.id, .allow, by: .tilde))
        await conductor.stopWorker(job.id)
        for _ in 0..<10 { await Task.yield() }
        #expect(await worker.answers.isEmpty)
        #expect(conductor.requests.isEmpty)
        #expect(conductor.automaticApprovalJobs.isEmpty)
        #expect(conductor.transcriptStore.load(job.id).allSatisfy { $0.kind != .decision })

        let replacement = ApprovalWorker()
        conductor.workers[job.id] = replacement
        #expect(conductor.setAutomaticApproval(true, for: job.id))
        pending(request, in: conductor, job: job)
        #expect(conductor.resolve(request.id, .allow, by: .tilde))
        conductor.workers[job.id] = ApprovalWorker()
        for _ in 0..<10 { await Task.yield() }
        #expect(await replacement.answers.isEmpty)
        #expect(conductor.transcriptStore.load(job.id).allSatisfy { $0.kind != .decision })
        await conductor.stopWorker(job.id)
    }

    @Test func inactiveOrMissingWorkerCannotBeApprovedAndDenyStillWorks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        let request = permission(job, metadata: false)
        pending(request, in: conductor, job: job)
        conductor.update(job.id) { $0.phase = .ready }
        #expect(!conductor.setAutomaticApproval(true, for: job.id))
        #expect(!conductor.resolve(request.id, .allow, by: .you))
        conductor.update(job.id) { $0.phase = .working }
        conductor.workers[job.id] = nil
        #expect(!conductor.resolve(request.id, .allow, by: .you))
        conductor.workers[job.id] = worker
        #expect(conductor.resolve(request.id, .deny("Unknown permissions need the owner."), by: .tilde))
        try await eventually { await worker.answers.count == 1 }
        #expect(await worker.answers.first?.isAllow == false)
        await conductor.stopWorker(job.id)
    }

    @Test func anExistingExactStandingRailGrantStillWorks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, job) = try fixture()
        let rail = "Pushes to a remote"
        conductor.standingAllows[job.repoPath] = [rail]
        let push = permission(job, command: "git push", metadata: false, rail: rail)
        pending(push, in: conductor, job: job)
        #expect(conductor.resolve(push.id, .allow, by: .tilde))
        try await eventually { await worker.answers.count == 1 }
        let deploy = permission(job, id: "deploy", command: "vercel deploy", metadata: false, rail: "Deploys")
        pending(deploy, in: conductor, job: job)
        #expect(!conductor.resolve(deploy.id, .allow, by: .tilde))
        await conductor.stopWorker(job.id)
    }

    @Test func aSupportedWorkerRequestIsAutomaticallyResolvedAfterOwnerOptIn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (conductor, worker, original) = try fixture()
        let harness = Harness(rawValue: "approval-events-\(UUID().uuidString)")
        HarnessCatalog.register(HarnessSpec(id: harness, label: "Approval fixture", executable: "/usr/bin/false", strengths: "Tests") { _ in worker })
        conductor.update(original.id) { $0.harness = harness }
        let job = try #require(conductor.job(original.id))
        try await conductor.spawn(job, brief: "Fixture", resume: false)
        #expect(conductor.setAutomaticApproval(true, for: job.id))
        await worker.request(permission(job))
        try await eventually { conductor.transcriptStore.load(job.id).last?.kind == .decision }
        #expect(await worker.answers.count == 1)
        #expect(conductor.requests.isEmpty)
        #expect(conductor.job(job.id)?.phase == .working)
        #expect(conductor.transcriptStore.load(job.id).last?.text.contains("bounded automatic approval") == true)
        await conductor.stopWorker(job.id)
    }
}
