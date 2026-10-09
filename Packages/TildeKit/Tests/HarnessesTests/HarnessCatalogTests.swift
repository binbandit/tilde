import Testing
import WorkerKit
@testable import Harnesses

@Suite struct HarnessCatalogTests {
    @Test func harnessIDsAreUnique() {
        let ids = HarnessCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        // The manager picks a harness by its strengths, so every one needs them.
        #expect(HarnessCatalog.all.allSatisfy { !$0.strengths.isEmpty })
    }
}
