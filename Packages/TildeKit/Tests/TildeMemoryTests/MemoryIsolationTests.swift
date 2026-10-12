import Foundation
import Testing
import TildeSupport
@testable import TildeMemory

@Suite struct MemoryIsolationTests {
    private func memory() async throws -> Memory {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-memory-isolation-\(UUID().uuidString)")
        let memory = try Memory(home: TildeHome(root: root))
        try await memory.prepare()
        return memory
    }

    @Test func scribeCannotForgetOwnerRules() async throws {
        let memory = try await memory()
        let rules = "# Rules\n\n## Publishing\n- Never publish private projects.\n"
        try rules.write(to: memory.notebook.url.appending(path: "rules.md"), atomically: true, encoding: .utf8)
        let model = RecordingMemoryModel()
        let scribe = Scribe(memory: memory, model: model)
        let ops = try JSONDecoder().decode(Scribe.Ops.self, from: Data("""
            {"remember":[],"forget":[{"about":"rules","fact":"Never publish private projects."}]}
            """.utf8))
        _ = await scribe.apply(ops)
        #expect(memory.notebook.read("rules.md") == rules)
        await #expect(throws: Notebook.Refused.self) {
            try await memory.forget("Never publish private projects.", about: "rules")
        }
    }

    @Test(.timeLimit(.minutes(1))) func scribeDoesNotConsumeChangedManagerCore() async throws {
        let memory = try await memory()
        _ = await memory.briefing(for: "hello")
        try await memory.notebook.addRule("Ask before publishing private projects.")
        let model = RecordingMemoryModel()
        let scribe = Scribe(memory: memory, model: model)
        var prompts = model.prompts.makeAsyncIterator()

        await scribe.reflect(on: "We discussed the project.")
        let first = try #require(await prompts.next())
        #expect(first.contains("Ask before publishing private projects."))
        let manager = try #require(await memory.briefing(for: "hello again"))
        #expect(manager.contains("Ask before publishing private projects."))

        // Each scribe pass is a fresh model session, even when the core did not change.
        await scribe.reflect(on: "We discussed another project.")
        let second = try #require(await prompts.next())
        #expect(second.contains("<note path=\"me.md\">"))
        #expect(second.contains("Ask before publishing private projects."))
        #expect(await memory.briefing(for: "hello again")?.contains("<note path=\"rules.md\">") != true)
    }
}

private struct RecordingMemoryModel: MemoryModel {
    let prompts: AsyncStream<String>
    private let emit: AsyncStream<String>.Continuation

    init() { (prompts, emit) = AsyncStream.makeStream() }

    func run(_ pass: ModelPass) async throws -> ModelReply {
        emit.yield(pass.prompt)
        return ModelReply(ok: true, text: "{\"remember\":[],\"forget\":[]}")
    }
}
