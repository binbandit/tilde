import Foundation

/// Where each line of a unified diff lives in the new file, so clicking a line
/// can open the editor right there.
public enum DiffMap {
    public struct Line: Sendable, Hashable {
        public enum Kind: Sendable { case file, hunk, added, removed, context }
        public var text: String
        public var kind: Kind
        /// The file this line belongs to (repo-relative).
        public var file: String?
        /// Line number in the new version, for added and context lines.
        public var newLine: Int?
    }

    public static func lines(_ patch: String) -> [Line] {
        var out: [Line] = []
        var file: String?
        var next = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if text.hasPrefix("diff --git") {
                file = text.components(separatedBy: " b/").last
                out.append(Line(text: file ?? text, kind: .file, file: file))
            } else if text.hasPrefix("index ") || text.hasPrefix("--- ") || text.hasPrefix("+++ ") || text.hasPrefix("new file")
                || text.hasPrefix("deleted file") || text.hasPrefix("\\ No newline")
            {
                continue
            } else if text.hasPrefix("@@") {
                // @@ -a,b +c,d @@: the new side starts at c.
                if let plus = text.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                    next = Int(plus.dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                out.append(Line(text: text, kind: .hunk, file: file))
            } else if text.hasPrefix("+") {
                out.append(Line(text: text, kind: .added, file: file, newLine: next))
                next += 1
            } else if text.hasPrefix("-") {
                out.append(Line(text: text, kind: .removed, file: file, newLine: next))
            } else if file != nil {
                out.append(Line(text: text, kind: .context, file: file, newLine: next))
                next += 1
            }
        }
        return out
    }
}
