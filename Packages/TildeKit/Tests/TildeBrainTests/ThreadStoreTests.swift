import Foundation
import Testing
import TildeSupport
@testable import TildeBrain

@Suite struct ThreadStoreTests {
    @Test func anUnreadableConversationIsSetAsideNotOverwritten() throws {
        let home = TildeHome(root: FileManager.default.temporaryDirectory.appending(path: "tilde-threads-\(UUID().uuidString)"))
        try home.prepare()
        let store = ThreadStore(home: home)
        let url = store.url(for: .now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[{\"from\": \"a newer tilde\"}]".write(to: url, atomically: true, encoding: .utf8)

        #expect(store.load().isEmpty)
        store.save([Message(from: .you, text: "hi")])
        let kept = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.contains("unreadable") }
        #expect(kept.count == 1)
    }
}
