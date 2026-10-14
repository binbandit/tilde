import Darwin
import Foundation

/// A process on this Mac, with as much as finding terminal agents needs.
struct RunningProcess: Sendable, Hashable {
    var pid: Int32
    var parent: Int32
    /// The executable on disk.
    var path: String
    /// One of the owner's, with a controlling terminal: started from a shell, not by an app or launchd.
    var interactive = false
    /// argv and the working directory, read only for interactive processes.
    var arguments: [String] = []
    var cwd: String?

    var program: String { (path as NSString).lastPathComponent }
}

/// Every process on this Mac at one moment, to walk from one up to the terminal it runs in.
struct ProcessTree: Sendable {
    let processes: [Int32: RunningProcess]

    init(_ processes: [RunningProcess]) {
        self.processes = Dictionary(processes.map { ($0.pid, $0) }) { first, _ in first }
    }

    /// Its parent, grandparent and so on, nearest first.
    func ancestors(of process: RunningProcess) -> [RunningProcess] {
        var chain: [RunningProcess] = []
        var visited: Set<Int32> = [process.pid]
        var next = processes[process.parent]
        while let current = next, visited.insert(current.pid).inserted {
            chain.append(current)
            next = processes[current.parent]
        }
        return chain
    }

    /// The app it shows in: the bundle of its nearest ancestor that's part of one. An app's helpers
    /// live inside it (VS Code's terminal runs under `Code Helper.app`), so it's the outermost bundle.
    func app(of process: RunningProcess) -> String? {
        ancestors(of: process).lazy.compactMap { ancestor in
            ancestor.path.range(of: ".app/").map { String(ancestor.path[..<$0.lowerBound]) + ".app" }
        }.first
    }
}

extension ProcessTree {
    /// Read from the kernel. Every process is listed, so a chain can be followed through the root-owned
    /// `login` a terminal starts shells with; only the owner's interactive ones have argv and cwd read.
    static func snapshot() -> ProcessTree {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return ProcessTree([]) }
        size += size / 8  // room for processes started in between
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &table, &size, nil, 0) == 0 else { return ProcessTree([]) }
        let owner = getuid()
        return ProcessTree(table.prefix(size / MemoryLayout<kinfo_proc>.stride).map { info in
            let pid = info.kp_proc.p_pid
            var process = RunningProcess(pid: pid, parent: info.kp_eproc.e_ppid, path: path(of: pid))
            if info.kp_eproc.e_ucred.cr_uid == owner, info.kp_proc.p_flag & P_CONTROLT != 0 {
                process.interactive = true
                process.arguments = arguments(of: pid)
                process.cwd = cwd(of: pid)
            }
            return process
        })
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// argv, from `KERN_PROCARGS2`: argc, the executable's path and its NUL padding, then the arguments
    /// (and after them the environment, which is never read).
    static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let end = buffer[index..<size].firstIndex(of: 0) ?? size
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }

    private static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }
}
