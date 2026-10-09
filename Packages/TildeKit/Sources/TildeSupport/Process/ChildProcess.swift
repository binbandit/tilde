import Darwin
import Foundation
import Synchronization

/// A child process in its own process group, with line-oriented stdout.
///
/// Agent CLIs spawn their own children (shells, builds, MCP servers), so
/// stopping one means signalling the whole group, not just the leader.
public final class ChildProcess: Sendable {
    public struct Spec: Sendable {
        public var executable: String
        public var arguments: [String]
        public var cwd: String
        public var environment: [String: String]

        public init(executable: String, arguments: [String], cwd: String, environment: [String: String]) {
            self.executable = executable
            self.arguments = arguments
            self.cwd = cwd
            self.environment = environment
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        case spawn(String, Int32)
        case stdinClosed

        public var description: String {
            switch self {
            case .notFound(let name): "\(name) is not installed (not found on PATH)"
            case .spawn(let name, let code): "could not start \(name): \(String(cString: strerror(code)))"
            case .stdinClosed: "the process is no longer accepting input"
            }
        }
    }

    public let pid: pid_t
    /// Complete stdout lines, without the trailing newline.
    public let lines: AsyncStream<String>

    private let stdin: Mutex<Int32?>
    private let stderrTail = Mutex(Data())
    private let exitState = Mutex<(status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>((nil, []))

    public init(_ spec: Spec) throws {
        ChildProcess.ignoreSIGPIPE

        let path = try ChildProcess.resolve(spec.executable, path: spec.environment["PATH"] ?? "")
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw Failure.spawn(spec.executable, errno)
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, spec.cwd)

        var attrs: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        // New process group, clean signal state, and no inherited descriptors
        // beyond the three we dup'd in.
        posix_spawnattr_setflags(
            &attrs,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attrs, 0)
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attrs, &noSignals)
        posix_spawnattr_setsigdefault(&attrs, &allSignals)

        let argv = ([path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attrs, argv, envp)
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw Failure.spawn(spec.executable, rc)
        }
        _ = fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)

        self.pid = pid
        self.stdin = Mutex(inPipe[1])

        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        self.lines = lines
        let outFD = outPipe[0], errFD = errPipe[0]
        Thread.detachNewThread {
            ChildProcess.readLines(outFD) { continuation.yield($0) }
            continuation.finish()
        }
        // These threads hold `self` until the child exits and its pipes close.
        Thread.detachNewThread { [self] in
            ChildProcess.readChunks(errFD) { chunk in
                self.stderrTail.withLock { tail in
                    tail.append(chunk)
                    if tail.count > 16_384 { tail.removeFirst(tail.count - 16_384) }
                }
            }
        }
        let childPID = pid
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1, errno == EINTR {}
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            let waiters = self.exitState.withLock { state in
                state.status = code
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume(returning: code) }
        }
    }

    deinit {
        stdin.withLock { fd in if let open = fd { close(open) } }
    }

    // MARK: Input

    public func write(_ data: Data) throws {
        try stdin.withLock { fd in
            guard let fd else { throw Failure.stdinClosed }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw Failure.stdinClosed
                    }
                    offset += n
                }
            }
        }
    }

    public func closeStdin() {
        stdin.withLock { fd in
            if let open = fd { close(open) }
            fd = nil
        }
    }

    // MARK: Lifecycle

    public var exitStatus: Int32? { exitState.withLock { $0.status } }

    public var stderr: String { String(decoding: stderrTail.withLock { $0 }, as: UTF8.self) }

    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done: Int32? = exitState.withLock { state in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    /// SIGTERM the group, then SIGKILL whatever is left after `grace`.
    public func terminate(grace: Duration = .seconds(3)) async {
        closeStdin()
        guard exitStatus == nil else { return }
        killpg(pid, SIGTERM)
        // waitForExit can't be cancelled, so the deadline runs beside it rather than racing it.
        let pid = self.pid
        let killer = Task {
            try? await Task.sleep(for: grace)
            if !Task.isCancelled, self.exitStatus == nil { killpg(pid, SIGKILL) }
        }
        _ = await waitForExit()
        killer.cancel()
    }

    // MARK: Helpers

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// The executable `name` names: a path as given, or the first match on `path` (a PATH value).
    public static func resolve(_ name: String, path: String) throws -> String {
        if name.contains("/") {
            guard access(name, X_OK) == 0 else { throw Failure.notFound(name) }
            return name
        }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw Failure.notFound(name)
    }

    private static func readChunks(_ fd: Int32, _ body: (Data) -> Void) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { body(Data(buffer[0..<n])) }
            else if n < 0, errno == EINTR { continue }
            else { return }
        }
    }

    private static func readLines(_ fd: Int32, _ emit: (String) -> Void) {
        var pending = Data()
        readChunks(fd) { chunk in
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if !line.isEmpty { emit(String(decoding: line, as: UTF8.self)) }
            }
        }
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)) }
    }
}
