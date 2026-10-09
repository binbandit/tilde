import Foundation
import os

/// A plain-text trail of what tilde did and why, at ~/.tilde/state/tilde.log.
/// Also mirrored to the unified log under the `dev.tilde` subsystem.
public enum Log {
    private static let logger = Logger(subsystem: "dev.tilde", category: "tilde")
    private static let queue = DispatchQueue(label: "dev.tilde.log")
    nonisolated(unsafe) private static var file: FileHandle?

    public static func info(_ category: String, _ message: @autoclosure () -> String) {
        let text = message()
        logger.info("[\(category, privacy: .public)] \(text, privacy: .public)")
        let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(category)] \(text)\n"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        if file == nil {
            let url = TildeHome.default.state.appending(path: "tilde.log")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("old.log"))
                try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("old.log"))
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            file = try? FileHandle(forWritingTo: url)
            _ = try? file?.seekToEnd()
        }
        try? file?.write(contentsOf: Data(line.utf8))
    }
}
