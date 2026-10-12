import Darwin
import Foundation

/// Open directories stay pinned during a transaction. Every leaf is opened with
/// O_NOFOLLOW; no event-provided path is ever used as an inbox filename.
final class TerminalAgentDirectory {
    let descriptor: Int32

    init(path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalAgentError.unsafeFile }
        do { try Self.check(fd, directory: true) }
        catch { close(fd); throw error }
        descriptor = fd
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    func child(_ name: String, create: Bool, privateOnly: Bool = false) throws -> TerminalAgentDirectory? {
        if create, mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST { throw TerminalAgentError.io(errno) }
        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT, !create { return nil }
            throw TerminalAgentError.unsafeFile
        }
        do { try Self.check(fd, directory: true, privateOnly: privateOnly) }
        catch { close(fd); throw error }
        return TerminalAgentDirectory(descriptor: fd)
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = openat(descriptor, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TerminalAgentError.unsafeFile }
        defer { close(fd) }
        try Self.check(fd, directory: false, privateOnly: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw TerminalAgentError.storeBusy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    func read(_ name: String, limit: Int, privateOnly: Bool = false) throws -> Data? {
        let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw TerminalAgentError.unsafeFile
        }
        defer { close(fd) }
        try Self.check(fd, directory: false, privateOnly: privateOnly)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw TerminalAgentError.io(errno) }
        guard info.st_size <= limit else { throw TerminalAgentError.limitExceeded }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw TerminalAgentError.io(errno) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw TerminalAgentError.limitExceeded }
        }
    }

    /// Atomic replacement in the same directory; existing files retain their mode.
    func write(_ data: Data, to name: String) throws {
        var previous = stat()
        let exists = fstatat(descriptor, name, &previous, AT_SYMLINK_NOFOLLOW) == 0
        if exists {
            guard previous.st_mode & S_IFMT == S_IFREG, previous.st_uid == geteuid(), previous.st_nlink == 1,
                previous.st_mode & 0o022 == 0
            else { throw TerminalAgentError.unsafeFile }
        } else if errno != ENOENT { throw TerminalAgentError.io(errno) }
        let temporary = ".pending-" + UUID().uuidString
        let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TerminalAgentError.io(errno) }
        defer { close(fd); unlinkat(descriptor, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 { if errno == EINTR { continue }; throw TerminalAgentError.io(errno) }
                guard count > 0 else { throw TerminalAgentError.io(EIO) }
                written += count
            }
        }
        guard fchmod(fd, exists ? previous.st_mode & 0o777 : 0o600) == 0,
            fsync(fd) == 0, renameat(descriptor, temporary, descriptor, name) == 0
        else { throw TerminalAgentError.io(errno) }
    }

    private static func check(_ descriptor: Int32, directory: Bool, privateOnly: Bool = false) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw TerminalAgentError.io(errno) }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            info.st_mode & (privateOnly ? 0o077 : 0o022) == 0,
            directory || info.st_nlink == 1
        else { throw TerminalAgentError.unsafeFile }
    }
}
