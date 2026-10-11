import Foundation
import TildeSupport

/// Reads and writes a day's thread under `state/threads/`.
struct ThreadStore: Sendable {
    let home: TildeHome

    func url(for day: Date) -> URL {
        home.state.appending(path: "threads").appending(path: "\(day.day).json")
    }

    /// A day's conversation. One that can't be read is set aside, never overwritten by the next save.
    func load(_ day: Date = .now) -> [Message] {
        let url = url(for: day)
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let messages = try? JSONDecoder().decode([Message].self, from: data) { return messages }
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        Log.info("state", "couldn't read \(url.lastPathComponent); set it aside as \(aside.lastPathComponent)")
        return []
    }

    /// The end of the most recent earlier conversation in the past week, settled: what's still open
    /// was carried into today, so nothing here asks or waits.
    func earlier(than day: Date, last count: Int) -> [Message] {
        for back in 1...7 {
            guard let date = Calendar.current.date(byAdding: .day, value: -back, to: day) else { break }
            let messages = load(date).filter { !$0.text.isEmpty }
            if !messages.isEmpty { return Array(messages.suffix(count)).map(\.asHistory) }
        }
        return []
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
