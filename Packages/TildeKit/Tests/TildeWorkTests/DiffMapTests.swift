import Testing
@testable import TildeWork

@Suite struct DiffMapTests {
    @Test func mapsAddedAndContextLinesToNewFileLineNumbers() {
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
            """
        let lines = DiffMap.lines(patch)
        #expect(lines.first?.kind == .file)
        #expect(lines.first?.file == "Sources/Nav.swift")
        #expect(lines.filter { $0.kind == .added }.map(\.newLine) == [13, 14])
        #expect(lines.last?.newLine == 15)
    }
}
