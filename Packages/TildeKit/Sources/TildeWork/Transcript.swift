import Foundation

/// One moment in a job's conversation: what its agent was told, said and did, what it
/// asked, and who answered. Every harness's events become these, so every agent reads the same.
public struct JobEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Speaker: String, Codable, Sendable {
        case tilde, you, agent
    }

    public enum Kind: String, Codable, Sendable {
        /// Words: the brief, a follow-up, the agent's reply.
        case message
        /// A step the agent took ("Running swift test").
        case step
        /// The agent wants a decision or an answer, or tilde passed one on to you.
        case request
        /// Someone decided or answered, as a verb: "allowed", "denied (why)", "answered: …".
        case decision
        /// The agent ended its turn; the text says what changed.
        case turnEnded
        /// Something that happened to the job (stopped, landed, taken over).
        case event
    }

    public var id: String
    public var at: Date
    public var from: Speaker
    public var kind: Kind
    public var text: String

    public init(id: String = UUID().uuidString, at: Date = .now, from: Speaker, kind: Kind, text: String) {
        self.id = id
        self.at = at
        self.from = from
        self.kind = kind
        self.text = text
    }
}

/// Each job's conversation, one JSON line per entry, in `<folder>/<job id>.jsonl`.
public struct TranscriptStore: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public func append(_ entry: JobEntry, to jobID: String) {
        guard let line = try? JSONEncoder.lines.encode(entry) else { return }
        let url = url(jobID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: line + Data("\n".utf8))
    }

    public func load(_ jobID: String) -> [JobEntry] {
        guard let text = try? String(contentsOf: url(jobID), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder.lines.decode(JobEntry.self, from: Data($0.utf8)) }
    }

    private func url(_ jobID: String) -> URL { folder.appending(path: "\(jobID).jsonl") }
}

private extension JSONEncoder {
    static let lines: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let lines: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
