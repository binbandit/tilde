import Foundation
import Testing
@testable import TildeSupport

@Suite struct PathsTests {
    @Test func resolvesTmpSymlinksWhenComparingPaths() {
        #expect(Paths.isInside("/private/tmp/x/y", "/tmp/x"))
        #expect(!Paths.isInside("/tmp/xy", "/tmp/x"))
    }

    /// A link inside the worktree that leads out of it: `..` after it climbs from where it leads.
    @Test func dotDotAfterALinkClimbsFromWhereItLeads() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-paths-\(UUID().uuidString)")
        let work = root.appending(path: "work"), outside = root.appending(path: "outside/sub")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: work.appending(path: "link"), withDestinationURL: outside)
        #expect(!Paths.isInside(work.path + "/link/../x", work.path))
        #expect(!Paths.isInside(work.path + "/link/file", work.path))
        #expect(Paths.isInside(work.path + "/src/../README.md", work.path))
    }
}
