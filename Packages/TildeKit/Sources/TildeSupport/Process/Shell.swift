import Foundation

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
        let executable = try ChildProcess.resolve(command[0], path: environment["PATH"] ?? "")
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(command.dropFirst())
            process.environment = environment
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let out = Pipe(), err = Pipe(), stdin = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = stdin

            // Drain both pipes concurrently so a chatty command can't deadlock on a full buffer.
            let group = DispatchGroup()
            nonisolated(unsafe) var outData = Data(), errData = Data()
            nonisolated(unsafe) var timedOut = false
            group.enter()
            DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    continuation.resume(returning: Output(
                        status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self),
                        timedOut: timedOut))
                }
            }
            do {
                try process.run()
                if let timeout {
                    let (seconds, attoseconds) = timeout.components
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18) {
                        guard process.isRunning else { return }
                        timedOut = true
                        process.terminate()
                    }
                }
                if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                try? stdin.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
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
