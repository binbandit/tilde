/// How much a job changed, as shown on its row and in review.
public struct DiffStat: Codable, Sendable, Hashable {
    public var files: Int
    public var insertions: Int
    public var deletions: Int

    public init(files: Int, insertions: Int, deletions: Int) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }

    public var isEmpty: Bool { files == 0 }
    public var label: String {
        isEmpty ? "no changes" : "\(files) file\(files == 1 ? "" : "s") +\(insertions) −\(deletions)"
    }
}
