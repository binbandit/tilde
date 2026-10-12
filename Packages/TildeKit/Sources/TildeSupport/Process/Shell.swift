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

    /// Runs `command` (argv[0] resolved on the user's PATH) and returns its output. Past `timeout`
    /// it's stopped, and the output says so.
    public static func run(
        _ command: [String], cwd: String? = nil, environment: [String: String] = UserEnvironment.shared.variables,
        input: String? = nil, timeout: Duration? = nil
    ) async throws -> Output {
        try Task.checkCancellation()
        guard let executable = command.first else { throw ChildProcess.Failure.notFound("") }
        let output = Mutex((stdout: Data(), stderr: Data(), timedOut: false))
        let process = try ChildProcess(
            .init(executable: executable, arguments: Array(command.dropFirst()),
                  cwd: cwd ?? FileManager.default.currentDirectoryPath, environment: environment),
            stdout: { chunk in output.withLock { $0.stdout.append(chunk) } },
            stderr: { chunk in output.withLock { $0.stderr.append(chunk) } })
        let deadline = timeout.map { timeout in
            Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                guard !process.isFinished else { return }
                output.withLock { $0.timedOut = true }
                await process.terminate(grace: .milliseconds(100))
                process.stopOutput()
            }
        }
        defer { deadline?.cancel() }
        return try await withTaskCancellationHandler {
            do {
                if let input { try process.write(Data(input.utf8)) }
            } catch {
                await process.terminate(grace: .milliseconds(100))
                process.stopOutput()
                // A deadline/cancellation can close a pipe while a large input is being
                // written. Report that cause, rather than replacing it with stdinClosed.
                if !output.withLock({ $0.timedOut }) && !Task.isCancelled { throw error }
            }
            process.closeStdin()
            let status = await process.waitForExit()
            await process.waitForOutput()
            try Task.checkCancellation()
            return output.withLock {
                Output(status: status, stdout: String(decoding: $0.stdout, as: UTF8.self),
                       stderr: String(decoding: $0.stderr, as: UTF8.self), timedOut: $0.timedOut)
            }
        } onCancel: {
            Task {
                await process.terminate(grace: .milliseconds(100))
                process.stopOutput()
            }
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
}
