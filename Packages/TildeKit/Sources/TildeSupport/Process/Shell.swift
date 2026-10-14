import Foundation
import Synchronization

/// Short-lived commands (git, gh, auth probes) whose whole output we want.
public enum Shell {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        /// Stopped for running past its timeout.
        public var timedOut = false
        public var ok: Bool { status == 0 && !timedOut }
        public var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public struct Failed: Error, CustomStringConvertible {
        public var command: [String]
        public var output: Output
        public var description: String {
            let detail = output.stderr.isEmpty ? output.stdout : output.stderr
            return "`\(command.joined(separator: " "))` failed (\(output.status)): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// How long a timed-out or cancelled command gets after SIGTERM before SIGKILL. These stop at once.
    static let grace = Duration.milliseconds(100)

    /// Runs `command` (argv[0] resolved on the user's PATH) and returns its output. Past `timeout`
    /// it's stopped, and the output says so.
    public static func run(
        _ command: [String], cwd: String? = nil, environment: [String: String] = UserEnvironment.shared.variables,
        timeout: Duration? = nil
    ) async throws -> Output {
        try Task.checkCancellation()
        guard let executable = command.first else { throw ChildProcess.Failure.notFound("") }
        let output = Mutex((stdout: Data(), stderr: Data(), timedOut: false))
        let process = try ChildProcess(
            .init(executable: executable, arguments: Array(command.dropFirst()),
                  cwd: cwd ?? FileManager.default.currentDirectoryPath, environment: environment),
            stdout: { chunk in output.withLock { $0.stdout.append(chunk) } },
            stderr: { chunk in output.withLock { $0.stderr.append(chunk) } },
            // A command may leave something running on purpose (git's daemons); a deadline still stops it.
            stopsGroupOnExit: false)
        process.closeStdin()
        @Sendable func stop() async {
            await process.terminate(grace: grace)
            process.stopOutput()
        }
        let deadline = timeout.map { timeout in
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                guard !process.isFinished else { return }
                output.withLock { $0.timedOut = true }
                await stop()
            }
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            let status = await process.waitForExit()
            await process.waitForOutput()
            try Task.checkCancellation()
            return output.withLock {
                Output(status: status, stdout: String(decoding: $0.stdout, as: UTF8.self),
                       stderr: String(decoding: $0.stderr, as: UTF8.self), timedOut: $0.timedOut)
            }
        } onCancel: {
            Task { await stop() }
        }
    }

    /// Like `run`, but throws unless the command exits 0. Returns trimmed stdout.
    @discardableResult
    public static func check(
        _ command: [String], cwd: String? = nil, environment: [String: String] = UserEnvironment.shared.variables
    ) async throws -> String {
        let output = try await run(command, cwd: cwd, environment: environment)
        guard output.ok else { throw Failed(command: command, output: output) }
        return output.trimmed
    }

    /// `text` as a single word for sh.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
