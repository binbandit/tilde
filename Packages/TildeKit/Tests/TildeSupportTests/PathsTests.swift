import Testing
@testable import TildeSupport

@Suite struct PathsTests {
    @Test func resolvesTmpSymlinksWhenComparingPaths() {
        #expect(Paths.isInside("/private/tmp/x/y", "/tmp/x"))
        #expect(!Paths.isInside("/tmp/xy", "/tmp/x"))
    }
}
