import Darwin
import Foundation

/// Which directory a terminal window is in, read from its shell processes.
///
/// Terminals don't expose their tabs' working directories, but their shells
/// are child processes and libproc can read any of our own user's processes.
enum Shells {
    private static let names: Set<String> = ["zsh", "bash", "fish", "nu", "sh", "xonsh", "elvish", "tcsh"]

    /// The best guess at the working directory of the terminal's front tab:
    /// the shell whose directory the window title mentions, else the newest shell.
    static func cwd(forTerminal pid: pid_t, title: String?) -> String? {
        let shells = descendants(of: pid, depth: 4).filter { names.contains(name(of: $0) ?? "") }
        let candidates = shells.compactMap { shell -> (pid: pid_t, cwd: String, started: UInt64)? in
            guard let cwd = cwd(of: shell) else { return nil }
            return (shell, cwd, startTime(of: shell))
        }
        if let title {
            let titled = candidates.filter { title.contains(($0.cwd as NSString).lastPathComponent) || title.contains(($0.cwd as NSString).abbreviatingWithTildeInPath) }
            if let best = titled.max(by: { $0.started < $1.started }) { return best.cwd }
        }
        return candidates.max { $0.started < $1.started }?.cwd
    }

    static func descendants(of pid: pid_t, depth: Int) -> [pid_t] {
        guard depth > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: 512)
        let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let direct = Array(children.prefix(Int(count)))
        return direct + direct.flatMap { descendants(of: $0, depth: depth - 1) }
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return name.trimmingCharacters(in: ["-"])
    }

    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    static func startTime(of pid: pid_t) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
}
