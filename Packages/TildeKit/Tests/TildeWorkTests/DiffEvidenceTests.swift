import Foundation
import Testing
import TildeSupport
@testable import TildeWork

@Suite struct DiffEvidenceTests {
    @Test func cleanIsDistinctFromAnUnavailableDiff() async throws {
        let fixture = GitTests()
        try await fixture.makeRepo()
        let base = try await Git.head(fixture.repo)
        #expect(try await Git.diffStat(workdir: fixture.repo, base: base).isEmpty)
        await #expect(throws: (any Error).self) { try await Git.diffStat(workdir: fixture.repo, base: "missing-revision") }
        await #expect(throws: (any Error).self) { try await Git.diffStat(workdir: fixture.repo + "/missing", base: base) }
    }

    @Test func stagedBinaryAndNewlineNamesAreChanges() async throws {
        let fixture = GitTests()
        try await fixture.makeRepo()
        let base = try await Git.head(fixture.repo)
        try Data([0, 1, 2]).write(to: URL(fileURLWithPath: fixture.repo + "/binary"))
        try await fixture.git("add", "binary")
        try "text\n".write(toFile: fixture.repo + "/a\nb.txt", atomically: true, encoding: .utf8)
        let diff = try await Git.diffStat(workdir: fixture.repo, base: base)
        #expect(diff.files == 2)
        #expect(!diff.isEmpty)
        #expect(await Git.diff(workdir: fixture.repo, base: base).contains("+text"))
    }

    @Test(arguments: [" leading.txt", "\nleading.txt", "\"quoted\".txt", "-option.txt"])
    func untrackedNamesPreserveEveryByte(_ name: String) async throws {
        let fixture = GitTests()
        try await fixture.makeRepo()
        let base = try await Git.head(fixture.repo)
        try "visible content\n".write(toFile: fixture.repo + "/" + name, atomically: true, encoding: .utf8)
        #expect(try await Git.untracked(fixture.repo) == [name])
        #expect(try await Git.diffStat(workdir: fixture.repo, base: base) == DiffStat(files: 1, insertions: 1, deletions: 0))
        #expect(await Git.diff(workdir: fixture.repo, base: base).contains("+visible content"))
    }
}
