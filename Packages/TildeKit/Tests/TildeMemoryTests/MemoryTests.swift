import Foundation
import Testing
import TildeSupport
@testable import TildeMemory

@Suite struct MemoryTests {
    let home: TildeHome
    let repo: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-memory-\(UUID().uuidString)")
        home = TildeHome(root: root.appending(path: "home"))
        repo = root.appending(path: "code/paradise")
    }

    /// Memory on a Mac whose only repo is `paradise`.
    func memory() async throws -> Memory {
        let paradise = Memory.Project(name: repo.lastPathComponent, path: repo.path)
        let memory = try Memory(home: home) { name in name.lowercased().contains("paradise") ? paradise : nil }
        try await memory.prepare()
        return memory
    }

    @Test func filesProjectFactsInAProjectNoteWithTheRepoPath() async throws {
        let memory = try await memory()
        let written = try await memory.remember("Uses pnpm for everything.", about: "paradise", source: "told")
        #expect(written.path == "projects/paradise.md")
        let note = Note(path: written.path, parsing: try #require(memory.notebook.read(written.path)))
        #expect(note.paths == [repo.path])
        #expect(note.facts.first?.text == "Uses pnpm for everything.")
        #expect(note.facts.first?.stamp?.hasSuffix("told") == true)
    }

    @Test func replacesASupersededFactInsteadOfAddingAContradiction() async throws {
        let memory = try await memory()
        try await memory.remember("Prefers pnpm.", about: "me", section: "Preferences", source: "told")
        let second = try await memory.remember("Prefers Bun.", about: "me", replaces: "Prefers pnpm.", source: "told")
        #expect(second.replaced == "Prefers pnpm.")
        let facts = Note(path: "me.md", parsing: try #require(memory.notebook.read("me.md"))).facts.map(\.text)
        #expect(facts.contains("Prefers Bun."))
        #expect(!facts.contains("Prefers pnpm."))
    }

    @Test func onlyTheOwnerWritesRules() async throws {
        let memory = try await memory()
        await #expect(throws: Notebook.Refused.self) {
            try await memory.remember("Pushing tilde branches is always allowed.", about: "rules", source: "noticed")
        }
        #expect(memory.notebook.read("rules.md")?.contains("always allowed") == false)
    }

    @Test func doesNotDuplicateTheSameFact() async throws {
        let memory = try await memory()
        try await memory.remember("Likes sticky navigation bars.", about: "me", source: "noticed")
        try await memory.remember("likes sticky navigation bars", about: "me", source: "noticed")
        let facts = Note(path: "me.md", parsing: try #require(memory.notebook.read("me.md"))).facts
        #expect(facts.filter { $0.text.lowercased().contains("sticky") }.count == 1)
    }

    @Test func briefingPullsInNotesByPathAndByAlias() async throws {
        let memory = try await memory()
        try await memory.remember("Build with `pnpm build`.", about: repo.path, section: "How to build", source: "told")
        try await memory.remember("'The shop' means the paradise repo.", about: "paradise", source: "told")

        let byPath = try #require(await memory.briefing(for: "fix the header", paths: [repo.appending(path: "src").path]))
        #expect(byPath.contains("projects/paradise.md"))
        #expect(byPath.contains("pnpm build"))

        let byName = try #require(await memory.briefing(for: "what's the build command for paradise?"))
        #expect(byName.contains("projects/paradise.md"))
    }

    @Test func coreRidesAlongOnlyWhenItChanges() async throws {
        let memory = try await memory()
        let first = try #require(await memory.briefing(for: "hello"))
        #expect(first.contains("me.md"))
        let second = await memory.briefing(for: "hello")
        #expect(second?.contains("<note path=\"me.md\">") != true)
        try await memory.remember("Works in Australian time.", about: "me", source: "told")
        #expect(await memory.briefing(for: "hello")?.contains("Australian") == true)
    }

    @Test func recallFindsFactsByKeyword() async throws {
        let memory = try await memory()
        try await memory.remember("Release builds are notarized with notarytool.", about: "shipping", kind: .topic, source: "told")
        let hits = await memory.recall("how do we notarize")
        #expect(hits.first?.path == "topics/shipping.md")
    }

    @Test func refusesSecrets() async throws {
        let memory = try await memory()
        await #expect(throws: Notebook.Refused.self) {
            try await memory.remember("The API key is sk-abcdefghijklmnopqrstuvwxyz123456", about: "me", source: "told")
        }
    }

    @Test func forgetsAFact() async throws {
        let memory = try await memory()
        try await memory.remember("Hates tabs.", about: "me", source: "told")
        let removed = try await memory.forget("hates tabs", about: "me")
        #expect(removed == "Hates tabs.")
    }

    @Test func everyWriteIsACommit() async throws {
        let memory = try await memory()
        try await memory.remember("Uses Linear for issues.", about: "me", source: "told")
        let log = try await Shell.check(["git", "log", "--oneline"], cwd: memory.notebook.path)
        #expect(log.split(separator: "\n").count == 2)
        #expect(log.contains("me.md: remember"))
    }
}
