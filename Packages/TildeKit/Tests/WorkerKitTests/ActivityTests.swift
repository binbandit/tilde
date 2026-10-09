import Testing
import TildeSupport
@testable import WorkerKit

@Suite struct ActivityTests {
    @Test func activityDescribesToolsLikeAPerson() {
        #expect(Activity.describe(tool: "Read", input: ["file_path": "/a/b/Nav.swift"]) == "Reading Nav.swift")
        #expect(Activity.describe(tool: "Bash", input: ["command": "swift test", "description": "Run the tests"]) == "Run the tests")
    }
}
