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
    /// The leader stays waitable until group cleanup is done, reserving its PID/PGID.
    /// Signals and reaping use one lock so a stale terminate cannot signal a reused group.
    private let groupState = Mutex<(reaped: Bool, deadline: ContinuousClock.Instant?)>((false, nil))
    private let outputDone = DispatchGroup()
    private let outputStopped = Mutex(false)

    public convenience init(_ spec: Spec) throws {
        try self.init(spec, stdout: nil, stderr: nil)
    }

    /// Raw consumers are used by Shell, which must preserve blank lines and final bytes.
    /// With a stdout consumer, `lines` finishes normally but does not buffer the same output again.
    init(_ spec: Spec, stdout: (@Sendable (Data) -> Void)?, stderr: (@Sendable (Data) -> Void)?) throws {
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
        outputDone.enter()
        outputDone.enter()
        Thread.detachNewThread { [self] in
            if let stdout { ChildProcess.readChunks(outFD, until: { self.outputStopped.withLock { $0 } }, stdout) }
            else { ChildProcess.readLines(outFD) { continuation.yield($0) } }
            continuation.finish()
            self.outputDone.leave()
        }
        // These threads hold `self` until the child exits and its pipes close.
        Thread.detachNewThread { [self] in
            let stop: (() -> Bool)? = stderr == nil ? nil : { self.outputStopped.withLock { $0 } }
            ChildProcess.readChunks(errFD, until: stop) { chunk in
                stderr?(chunk)
                self.stderrTail.withLock { tail in
                    tail.append(chunk)
                    if tail.count > 16_384 { tail.removeFirst(tail.count - 16_384) }
                }
            }
            self.outputDone.leave()
        }
        let childPID = pid
        Thread.detachNewThread { [self] in
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(childPID), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
            // The leader may exit before its children. Clean them while its unreaped PID
            // still reserves the group identity, including on a natural/crash exit.
            if result == 0 { self.finishGroup() }
            var status: Int32 = 0
            self.groupState.withLock { state in
                while waitpid(childPID, &status, 0) == -1, errno == EINTR {}
                state.reaped = true
            }
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

    func waitForOutput() async {
        await withCheckedContinuation { continuation in
            outputDone.notify(queue: .global()) { continuation.resume() }
        }
    }

    var isFinished: Bool { exitStatus != nil && outputDone.wait(timeout: .now()) == .success }

    /// A detached helper can retain our pipes after leaving the owned group. A Shell
    /// deadline must still finish; stop its raw readers once group shutdown is complete.
    func stopOutput() { outputStopped.withLock { $0 = true } }

    /// SIGTERM the group, then SIGKILL whatever is left after `grace`.
    public func terminate(grace: Duration = .seconds(3)) async {
        groupState.withLock { state in
            guard !state.reaped else { return }
            let deadline = ContinuousClock.now + grace
            state.deadline = min(state.deadline ?? deadline, deadline)
            killpg(pid, SIGTERM)
        }
        // waitForExit can't be cancelled, so the deadline runs beside it rather than racing it.
        let killer = Task {
            try? await Task.sleep(for: grace)
            if !Task.isCancelled { self.signalGroup(SIGKILL) }
        }
        // A writer may hold the stdin lock while blocked on a full pipe. Signal and arm
        // escalation first, so closing stdin cannot prevent us from stopping that child.
        closeStdin()
        _ = await waitForExit()
        killer.cancel()
    }

    private func signalGroup(_ signal: Int32) {
        groupState.withLock { state in
            if !state.reaped { killpg(pid, signal) }
        }
    }

    /// Called only after waitid observed the leader's exit without reaping it.
    private func finishGroup() {
        groupState.withLock { state in
            if state.deadline == nil { state.deadline = .now + .seconds(3) }
            killpg(pid, SIGTERM)
        }
        while groupHasChildren() {
            let deadline = groupState.withLock { $0.deadline! }
            if ContinuousClock.now >= deadline {
                signalGroup(SIGKILL)
                return
            }
            usleep(10_000)
        }
    }

    private func groupHasChildren() -> Bool {
        // We only need to find one other member; a full buffer also proves that.
        var members = [pid_t](repeating: 0, count: 32)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &members, Int32(members.count * MemoryLayout<pid_t>.stride))
        // If enumeration fails, retain the PID until the grace period and kill the group.
        guard bytes > 0 else { return true }
        return members.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).contains { $0 != 0 && $0 != pid }
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

    private static func readChunks(_ fd: Int32, until stopped: (() -> Bool)? = nil, _ body: (Data) -> Void) {
        defer { close(fd) }
        if stopped != nil { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if stopped?() == true { return }
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { body(Data(buffer[0..<n])) }
            else if n < 0, errno == EINTR { continue }
            else if n < 0, errno == EAGAIN, stopped != nil {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 50)
            }
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
