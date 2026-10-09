import Foundation
import os

/// A plain-text trail of what tilde did and why, at `<tilde home>/state/tilde.log`,
/// in local time. Also mirrored to the unified log under the `dev.tilde` subsystem.
///
/// Nothing is written to disk until a home is chosen with `use(_:)` (the
/// Conductor does this), so tests and tools working in a scratch home never
/// write into the real one.
public enum Log {
    private static let logger = Logger(subsystem: "dev.tilde", category: "tilde")
    private static let queue = DispatchQueue(label: "dev.tilde.log")
    nonisolated(unsafe) private static var destination: URL?
    nonisolated(unsafe) private static var file: FileHandle?
    private static let time = Date.ISO8601FormatStyle(timeZone: .current).time(includingFractionalSeconds: true)

    /// Sends the file log to `home`'s state folder from now on.
    public static func use(_ home: TildeHome) {
        let url = home.state.appending(path: "tilde.log")
        queue.async {
            guard url != destination else { return }
            try? file?.close()
            file = nil
            destination = url
        }
    }

    public static func info(_ category: String, _ message: @autoclosure () -> String) {
        let text = message()
        logger.info("[\(category, privacy: .public)] \(text, privacy: .public)")
        let line = "\(Date.now.formatted(time)) [\(category)] \(text)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        guard let url = destination else { return }
        if file == nil {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            file = try? FileHandle(forWritingTo: url)
            _ = try? file?.seekToEnd()
        }
        try? file?.write(contentsOf: Data(line.utf8))
    }
}
