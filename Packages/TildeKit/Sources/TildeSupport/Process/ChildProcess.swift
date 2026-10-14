import Darwin
import Foundation
import Synchronization

/// A child process in its own process group, with line-oriented stdout.
///
/// Agent CLIs spawn their own children (shells, builds, MCP servers), so stopping one means signalling the
/// whole group, not just the leader. `exitStatus` and `waitForExit` report the leader the moment it exits;
/// what it leaves running in its group is then stopped too, SIGTERM first and SIGKILL after `grace`. The
/// leader is reaped only once that's done, since an unreaped leader keeps its PID, which is the group's id,
/// from being reused while the group is signalled. `terminate` returns once the whole group is gone.
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

    /// How long the group gets between SIGTERM and SIGKILL, unless `terminate` is given less.
    public static let grace = Duration.seconds(3)

    public let pid: pid_t
    /// Complete stdout lines, without the trailing newline.
    public let lines: AsyncStream<String>

    private let stdin: Mutex<Int32?>
    private let inputStopped = Mutex(false)
    private let stderrTail = Mutex(Data())
    private let exitState = Mutex<(status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>((nil, []))
    /// Signals and the reap share this lock, so a late signal never reaches a reused group id. `deadline`
    /// is when what's left of the group is SIGKILLed, once something has asked it to stop.
    private let groupState = Mutex<(reaped: Bool, deadline: ContinuousClock.Instant?)>((false, nil))
    private let groupDone = DispatchGroup()
    private let outputDone = DispatchGroup()
    private let outputStopped = Mutex(false)

    public convenience init(_ spec: Spec) throws {
        try self.init(spec, stdout: nil, stderr: nil, stopsGroupOnExit: true)
    }

    /// Raw consumers are used by Shell, which must preserve blank lines and final bytes.
    /// With a stdout consumer, `lines` finishes normally but does not buffer the same output again.
    /// Without `stopsGroupOnExit`, what the leader leaves running when it exits on its own is left alone.
    init(_ spec: Spec, stdout: (@Sendable (Data) -> Void)?, stderr: (@Sendable (Data) -> Void)?, stopsGroupOnExit: Bool) throws {
        ChildProcess.ignoreSIGPIPE

        let path = try ChildProcess.resolve(spec.executable, path: spec.environment["PATH"] ?? "")
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            throw Failure.spawn(spec.executable, errno)
        }
        // A helper may retain stdin without reading it, even after leaving our process group.
        // Polling lets closeStdin release a full-pipe writer without depending on that helper's exit.
        guard fcntl(inPipe[1], F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno
            (inPipe + outPipe + errPipe).forEach { close($0) }
            throw Failure.spawn(spec.executable, code)
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
        groupDone.enter()
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
        Thread.detachNewThread { [self] in
            // Observe the leader's exit without reaping it.
            var info = siginfo_t()
            while waitid(P_PID, id_t(self.pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            let code = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
            let waiters = self.exitState.withLock { state in
                state.status = code
                defer { state.waiters = [] }
                return state.waiters
            }
            waiters.forEach { $0.resume(returning: code) }
            if stopsGroupOnExit || self.groupState.withLock({ $0.deadline != nil }) { self.stopGroup() }
            self.groupState.withLock { state in
                var status: Int32 = 0
                while waitpid(self.pid, &status, 0) == -1, errno == EINTR {}
                state.reaped = true
            }
            self.groupDone.leave()
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
                    guard !inputStopped.withLock({ $0 }) else { throw Failure.stdinClosed }
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN {
                            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            _ = poll(&descriptor, 1, 50)
                            continue
                        }
                        throw Failure.stdinClosed
                    }
                    guard n > 0 else { throw Failure.stdinClosed }
                    offset += n
                }
            }
        }
    }

    public func closeStdin() {
        inputStopped.withLock { $0 = true }
        stdin.withLock { fd in
            if let open = fd { close(open) }
            fd = nil
        }
    }

    // MARK: Lifecycle

    /// The leader's exit status, once it has exited.
    public var exitStatus: Int32? { exitState.withLock { $0.status } }

    public var stderr: String { String(decoding: stderrTail.withLock { $0 }, as: UTF8.self) }

    /// Waits for the leader to exit. Its group may still be stopping.
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

    /// SIGTERM the group and SIGKILL whatever is left after `grace`. Returns once all of it is gone.
    public func terminate(grace: Duration = ChildProcess.grace) async {
        inputStopped.withLock { $0 = true }
        groupState.withLock { state in
            guard !state.reaped else { return }
            let deadline = ContinuousClock.now + grace
            state.deadline = min(state.deadline ?? deadline, deadline)
            killpg(pid, SIGTERM)
        }
        // Arm escalation before acquiring stdin's lock. A stopped writer releases it on its next poll.
        let killer = Task {
            try? await Task.sleep(for: grace)
            if !Task.isCancelled { self.signalGroup(SIGKILL) }
        }
        closeStdin()
        await withCheckedContinuation { continuation in
            groupDone.notify(queue: .global()) { continuation.resume() }
        }
        killer.cancel()
    }

    private func signalGroup(_ signal: Int32) {
        groupState.withLock { state in
            if !state.reaped { killpg(pid, signal) }
        }
    }

    /// After the leader has exited, unreaped: SIGTERM what's left of its group, then wait for it to go
    /// until the deadline, which `terminate` can bring forward, and SIGKILL the rest.
    private func stopGroup() {
        groupState.withLock { state in
            if state.deadline == nil { state.deadline = .now + Self.grace }
            killpg(pid, SIGTERM)
        }
        while groupHasMembers() {
            if ContinuousClock.now >= groupState.withLock({ $0.deadline! }) {
                killpg(pid, SIGKILL)
                return
            }
            usleep(10_000)
        }
    }

    private func groupHasMembers() -> Bool {
        // We only need to find one other member; a full buffer also proves that.
        var members = [pid_t](repeating: 0, count: 32)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &members, Int32(members.count * MemoryLayout<pid_t>.stride))
        // If enumeration fails, assume members remain: the deadline still ends the wait.
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
