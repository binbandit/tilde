import Foundation
import WorkerKit

struct StreamTurn: Equatable {
    var ok: Bool
    var text: String
}

/// Pulls one kind of event out of a `WorkerEvent`, for `StreamEvents.next`.
enum StreamPick {
    static func session(_ event: WorkerEvent) -> String? { if case .session(let id) = event { id } else { nil } }
    static func activity(_ event: WorkerEvent) -> String? { if case .activity(let text) = event { text } else { nil } }
    static func turn(_ event: WorkerEvent) -> StreamTurn? {
        if case .turnEnded(let ok, let text) = event { StreamTurn(ok: ok, text: text) } else { nil }
    }
    static func request(_ event: WorkerEvent) -> WorkerRequest? { if case .request(let request) = event { request } else { nil } }
    /// `.some(nil)` for a clean exit.
    static func exit(_ event: WorkerEvent) -> String?? { if case .exited(let detail) = event { .some(detail) } else { nil } }
}

/// Collects a worker's events so a test can wait for the next one it cares about.
actor StreamEvents {
    private(set) var all: [WorkerEvent] = []
    private var cursor = 0
    private var finished = false

    init(_ worker: some Worker) {
        let events = worker.events
        Task { [weak self] in
            for await event in events { await self?.append(event) }
            await self?.finish()
        }
    }

    private func append(_ event: WorkerEvent) { all.append(event) }
    private func finish() { finished = true }

    /// The next event after the last one returned that `pick` accepts.
    func next<T: Sendable>(_ pick: @Sendable (WorkerEvent) -> T?, within limit: Duration = .seconds(10)) async throws -> T {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            while cursor < all.count {
                defer { cursor += 1 }
                if let value = pick(all[cursor]) { return value }
            }
            if finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NoMatch(seen: all.map { "\($0)" })
    }

    struct NoMatch: Error, CustomStringConvertible {
        var seen: [String]
        var description: String { "No matching event. Saw:\n" + seen.joined(separator: "\n") }
    }
}
