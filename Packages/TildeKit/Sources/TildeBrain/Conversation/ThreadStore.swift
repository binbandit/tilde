import Foundation
import TildeSupport

/// Reads and writes a day's thread under `state/threads/`.
struct ThreadStore: Sendable {
    let home: TildeHome

    func url(for day: Date) -> URL {
        home.state.appending(path: "threads").appending(path: "\(day.day).json")
    }

    func load(_ day: Date = .now) -> [Message] {
        (try? Data(contentsOf: url(for: day))).flatMap { try? JSONDecoder().decode([Message].self, from: $0) } ?? []
    }

    func save(_ messages: [Message], day: Date = .now) {
        let url = url(for: day)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(messages) { try? data.write(to: url, options: .atomic) }
    }

    /// The day's conversation as plain text, for the dream.
    func transcript(_ day: Date) -> String {
        load(day).filter { !$0.streaming && !$0.text.isEmpty }.map { message in
            let time = message.at.formatted(date: .omitted, time: .shortened)
            let who = message.from == .you ? Owner.firstName : "tilde"
            return "\(time) \(who): \(message.text)" + (message.pointing.map { " (pointing at \($0))" } ?? "")
        }.joined(separator: "\n")
    }
}
