import Testing
@testable import TildeMemory

@Suite struct NoteTests {
    let sample = """
        ---
        kind: project
        aliases: [paradise app, the paradise one]
        paths: [/Users/b/Developer/frontend/paradise]
        updated: 2026-10-01
        ---
        # paradise

        A Next.js storefront.

        ## Facts

        - Uses pnpm. _(2026-10-01, told)_
        - Deploys from main. _(2026-10-02, noticed)_

        ## How to build

        - `pnpm build`
        """

    @Test func parsesFrontmatterSectionsAndFacts() {
        let note = Note(path: "projects/paradise.md", parsing: sample)
        #expect(note.kind == "project")
        #expect(note.aliases == ["paradise app", "the paradise one"])
        #expect(note.paths == ["/Users/b/Developer/frontend/paradise"])
        #expect(note.title == "paradise")
        #expect(note.intro == "A Next.js storefront.")
        #expect(note.sections.map(\.heading) == ["Facts", "How to build"])
        #expect(note.facts.map(\.text) == ["Uses pnpm.", "Deploys from main.", "`pnpm build`"])
        #expect(note.facts.first?.stamp == "2026-10-01, told")
    }

    @Test func roundTripsThroughRender() {
        let note = Note(path: "projects/paradise.md", parsing: sample)
        #expect(Note(path: note.path, parsing: note.render()) == note)
    }

    @Test func addsReplacesAndRemovesFacts() {
        var note = Note(path: "projects/paradise.md", parsing: sample)
        note.add("Uses Bun now.", section: "Facts", stamp: "2026-10-08, told", replacing: note.facts.first)
        #expect(note.facts.map(\.text).contains("Uses Bun now."))
        #expect(!note.facts.map(\.text).contains("Uses pnpm."))

        note.add("Prefers sticky nav bars.", section: "Preferences", stamp: "2026-10-08, noticed")
        #expect(note.sections.last?.heading == "Preferences")

        let removed = note.remove(Note.Fact(section: "Facts", text: "Deploys from main.", stamp: nil))
        #expect(removed)
        #expect(!note.facts.map(\.text).contains("Deploys from main."))
    }

    @Test func unquotesFrontmatterValues() {
        let note = Note(path: "projects/echo.md", parsing: "---\nkind: \"project\"\npaths: [\"/Users/b/Echo\", '/tmp/x']\n---\n\n# Echo\n")
        #expect(note.kind == "project")
        #expect(note.paths == ["/Users/b/Echo", "/tmp/x"])
        #expect(note.title == "Echo")
    }

    @Test func noteWithoutFrontmatterTakesTitleFromHeadingOrFile() {
        #expect(Note(path: "topics/swiftui.md", parsing: "# SwiftUI\n\n- Likes previews.").title == "SwiftUI")
        #expect(Note(path: "topics/swiftui.md", parsing: "- Likes previews.").title == "swiftui")
    }
}
