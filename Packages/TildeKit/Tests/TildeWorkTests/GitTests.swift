import Foundation
import Testing
import TildeSupport
import WorkerKit
@testable import TildeWork

@Suite struct GitTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-git-\(UUID().uuidString)")
    var repo: String { root.appending(path: "app").path }

    func git(_ args: String..., cwd: String? = nil) async throws {
        try await Shell.check(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, cwd: cwd ?? repo)
    }

    func makeRepo() async throws {
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main")
        try "hello\n".write(toFile: "\(repo)/README.md", atomically: true, encoding: .utf8)
        try await git("add", ".")
        try await git("commit", "-qm", "init")
    }

    func makeJob() async throws -> Job {
        let workdir = root.appending(path: "worktrees/app/nav").path
        let (base, commit) = try await Git.addWorktree(repo: repo, path: workdir, branch: "tilde/nav")
        var job = Job(id: "j-test", title: "Nav", brief: "", projectName: "app", repoPath: repo, workdir: workdir,
                      harness: Harness(rawValue: "claude"), isolation: .worktree)
        job.branch = "tilde/nav"
        job.baseBranch = base
        job.baseCommit = commit
        return job
    }

    @Test func worktreeJobsDiffAndLandByFastForward() async throws {
        try await makeRepo()
        let job = try await makeJob()
        try "nav\n".write(toFile: "\(job.workdir)/Nav.swift", atomically: true, encoding: .utf8)
        try await git("add", ".", cwd: job.workdir)
        try await git("commit", "-qm", "Add nav", cwd: job.workdir)
        try "more\n".write(toFile: "\(job.workdir)/Untracked.swift", atomically: true, encoding: .utf8)

        let stat = await Git.diffStat(workdir: job.workdir, base: job.baseCommit!)
        #expect(stat.files == 2)
        #expect(stat.insertions == 2)

        try await Git.land(job)
        #expect(FileManager.default.fileExists(atPath: "\(repo)/Nav.swift"))
        #expect(FileManager.default.fileExists(atPath: "\(repo)/Untracked.swift"))
        let log = try await Shell.check(["git", "log", "--oneline"], cwd: repo)
        #expect(log.split(separator: "\n").count == 3)
    }

    @Test func landingRebasesOntoNewWorkInTheCheckout() async throws {
        try await makeRepo()
        let job = try await makeJob()
        try "nav\n".write(toFile: "\(job.workdir)/Nav.swift", atomically: true, encoding: .utf8)
        try await git("add", ".", cwd: job.workdir)
        try await git("commit", "-qm", "Add nav", cwd: job.workdir)
        try "other\n".write(toFile: "\(repo)/Other.swift", atomically: true, encoding: .utf8)
        try await git("add", ".")
        try await git("commit", "-qm", "Brayden kept working")

        try await Git.land(job)
        let log = try await Shell.check(["git", "log", "--oneline"], cwd: repo)
        #expect(log.hasPrefix(log.split(separator: "\n")[0]) && log.contains("Add nav") && log.contains("Brayden kept working"))
    }

    @Test func refusesToLandIntoADirtyCheckout() async throws {
        try await makeRepo()
        let job = try await makeJob()
        try "changed\n".write(toFile: "\(repo)/README.md", atomically: true, encoding: .utf8)
        await #expect(throws: Git.LandFailure.self) { try await Git.land(job) }
    }

    @Test func picksAFreeBranchName() async throws {
        try await makeRepo()
        _ = try await makeJob()
        #expect(await Git.freeBranch(repo: repo, slug: "nav") == "tilde/nav-2")
    }
}
