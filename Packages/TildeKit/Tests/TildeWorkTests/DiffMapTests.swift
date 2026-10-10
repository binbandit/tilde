import Testing
@testable import TildeWork

@Suite struct DiffMapTests {
    @Test func numbersLinesOnBothSides() throws {
        let patch = """
            diff --git a/Sources/Nav.swift b/Sources/Nav.swift
            index 1..2 100644
            --- a/Sources/Nav.swift
            +++ b/Sources/Nav.swift
            @@ -10,3 +12,4 @@ struct Nav {
             let a = 1
            -let b = 2
            +let b = 3
            +let c = 4
             let d = 5
            \\ No newline at end of file

            """
        let file = try #require(DiffMap.files(patch).first)
        #expect(file.path == "Sources/Nav.swift")
        #expect(file.status == .modified)
        #expect(file.lines.first == DiffMap.Line(text: "struct Nav {", kind: .hunk, oldLine: 10, newLine: 12))
        #expect(file.lines.filter { $0.kind == .added }.map(\.newLine) == [13, 14])
        #expect(file.lines.filter { $0.kind == .removed }.map(\.oldLine) == [11])
        #expect(file.lines.last == DiffMap.Line(text: "let d = 5", kind: .context, oldLine: 12, newLine: 15))
        #expect((file.insertions, file.deletions) == (2, 1))
    }

    @Test func readsWhatHappenedToEachFile() {
        let patch = """
            diff --git a/README.md b/README.md
            new file mode 100644
            --- /dev/null
            +++ b/README.md
            @@ -0,0 +1 @@
            +hi
            diff --git a/old.txt b/new.txt
            similarity index 100%
            rename from old.txt
            rename to new.txt
            diff --git a/logo.png b/logo.png
            Binary files a/logo.png and b/logo.png differ
            diff --git a/gone.swift b/gone.swift
            deleted file mode 100644
            @@ -1 +0,0 @@
            -bye
            """
        let files = DiffMap.files(patch)
        #expect(files.map(\.path) == ["README.md", "new.txt", "logo.png", "gone.swift"])
        #expect(files.map(\.status) == [.added, .renamed, .binary, .deleted])
        #expect(files[1].oldPath == "old.txt")
        #expect(files[0].lines.first?.text == "")
    }
}
