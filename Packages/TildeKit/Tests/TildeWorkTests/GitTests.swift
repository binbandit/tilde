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

        let stat = try await Git.diffStat(workdir: job.workdir, base: job.baseCommit!)
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

    @Test(arguments: [false, true]) func refusesToLandAfterTheWorkerLeavesItsBranch(detached: Bool) async throws {
        try await makeRepo()
        let job = try await makeJob()
        if detached {
            try await git("switch", "--detach", cwd: job.workdir)
        } else {
            try await git("switch", "-c", "worker-choice", cwd: job.workdir)
        }
        try "result\n".write(toFile: "\(job.workdir)/Result.swift", atomically: true, encoding: .utf8)
        let checkoutHead = try await Git.head(repo)
        let workerHead = try await Git.head(job.workdir)

        await #expect(throws: Git.LandFailure.self) { try await Git.land(job) }
        #expect(try await Git.head(repo) == checkoutHead)
        #expect(try await Git.head(job.workdir) == workerHead)
        #expect(try String(contentsOfFile: "\(job.workdir)/Result.swift", encoding: .utf8) == "result\n")
        let untracked = try await Shell.check(["git", "ls-files", "--others", "--exclude-standard"], cwd: job.workdir)
        #expect(untracked.split(separator: "\n").contains("Result.swift"))
    }

    @Test func picksAFreeBranchName() async throws {
        try await makeRepo()
        _ = try await makeJob()
        #expect(await Git.freeBranch(repo: repo, slug: "nav") == "tilde/nav-2")
    }
}

@Suite struct ProjectRemoteTests {
    @Test func checkoutsAreKnownByWhereOriginPoints() {
        #expect(ProjectIndex.remote(fromURL: "git@github.com:binbandit/oh-fx.git") == "binbandit/oh-fx")
        #expect(ProjectIndex.remote(fromURL: "https://github.com/binbandit/paradise.git") == "binbandit/paradise")
        #expect(ProjectIndex.remote(fromURL: "https://github.com/maximhq/bifrost") == "maximhq/bifrost")
        #expect(ProjectIndex.remote(fromURL: "nonsense") == nil)
    }
}

@Suite struct ProjectRemotesTests {
    /// A fork's clone is found by the repo it was forked from, too.
    @Test func everyRemoteCountsOriginFirst() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "tilde-remotes-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(repo)/.git", withIntermediateDirectories: true)
        try """
            [remote "upstream"]
            \turl = https://github.com/org/x.git
            [remote "origin"]
            \turl = git@github.com:me/x.git
            """.write(toFile: "\(repo)/.git/config", atomically: true, encoding: .utf8)
        #expect(ProjectIndex.remotes(of: repo) == ["me/x", "org/x"])
    }
}
