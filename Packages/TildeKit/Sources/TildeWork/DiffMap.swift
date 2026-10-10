import Foundation

/// A unified diff read file by file, with where each line lives in the old and new
/// versions, so the diff can be numbered and clicking a line can open the editor there.
public enum DiffMap {
    public struct File: Sendable, Hashable, Identifiable {
        public enum Status: Sendable { case modified, added, deleted, renamed, binary }

        /// Repo-relative, as it is now (as it was, for a deleted file).
        public var path: String
        /// Where a renamed file came from.
        public var oldPath: String?
        public var status: Status
        public var lines: [Line]
        public var insertions: Int { lines.count { $0.kind == .added } }
        public var deletions: Int { lines.count { $0.kind == .removed } }
        public var id: String { path }
    }

    public struct Line: Sendable, Hashable {
        public enum Kind: Sendable { case hunk, added, removed, context }
        /// The line without its +, - or space; for a hunk, the code it sits in (`func layout() {`), if git says,
        /// and its line numbers where it starts.
        public var text: String
        public var kind: Kind
        /// Line number in the old version, for removed and context lines.
        public var oldLine: Int?
        /// Line number in the new version: for added and context lines, and for a
        /// removed line, where it was (so clicking it lands nearby).
        public var newLine: Int?
    }

    public static func files(_ patch: String) -> [File] {
        var files: [File] = []
        var old = 0, new = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if text.hasPrefix("diff --git ") {
                // diff --git a/<old> b/<new>; "rename from" lines below say so if the names differ.
                let path = text.components(separatedBy: " b/").last ?? text
                files.append(File(path: path, status: .modified, lines: []))
                continue
            }
            guard !files.isEmpty else { continue }
            let i = files.count - 1
            if files[i].lines.isEmpty, !text.hasPrefix("@@") {
                // The header between `diff --git` and the first hunk.
                if text.hasPrefix("new file") { files[i].status = .added }
                if text.hasPrefix("deleted file") { files[i].status = .deleted }
                if text.hasPrefix("rename from ") { files[i].oldPath = String(text.dropFirst(12)); files[i].status = .renamed }
                if text.hasPrefix("Binary files") { files[i].status = .binary }
                continue
            }
            if text.hasPrefix("@@") {
                // @@ -a,b +c,d @@ heading
                let parts = text.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
                old = parts.first { $0.hasPrefix("-") }.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                new = parts.first { $0.hasPrefix("+") }.flatMap { Int($0.dropFirst().split(separator: ",").first ?? "") } ?? 0
                let heading = text.split(separator: "@@", maxSplits: 2, omittingEmptySubsequences: true).dropFirst().first
                files[i].lines.append(
                    Line(text: heading.map { $0.trimmingCharacters(in: .whitespaces) } ?? "", kind: .hunk, oldLine: old, newLine: new))
            } else if text.hasPrefix("+") {
                files[i].lines.append(Line(text: String(text.dropFirst()), kind: .added, newLine: new))
                new += 1
            } else if text.hasPrefix("-") {
                files[i].lines.append(Line(text: String(text.dropFirst()), kind: .removed, oldLine: old, newLine: new))
                old += 1
            } else if text.hasPrefix(" ") {
                files[i].lines.append(Line(text: String(text.dropFirst()), kind: .context, oldLine: old, newLine: new))
                old += 1
                new += 1
            }
            // Anything else ("\ No newline at end of file", a trailing blank) isn't part of either file.
        }
        return files
    }
}
