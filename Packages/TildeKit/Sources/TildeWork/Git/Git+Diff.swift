import Foundation
import TildeSupport

extension Git {
    /// git for reading a worker's worktree: nothing in it (a monitor, a hook) runs on tilde's behalf.
    static let reading = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// Everything the job changed since `base`: commits plus uncommitted and untracked work. Throws when the
    /// worktree can't be read, which is not the same as no changes.
    public static func diffStat(workdir: String, base: String) async throws -> DiffStat {
        let numstat = try await Shell.check(reading + ["diff", "--numstat", "--no-ext-diff", "--no-textconv", base, "--"], cwd: workdir)
        var stat = DiffStat(files: 0, insertions: 0, deletions: 0)
        for line in numstat.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            stat.files += 1
            stat.insertions += Int(cols[0]) ?? 0
            stat.deletions += Int(cols[1]) ?? 0
        }
        for file in try await untracked(workdir) {
            stat.files += 1
            let path = (workdir as NSString).appendingPathComponent(file)
            if let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty {
                stat.insertions += text.filter { $0 == "\n" }.count + (text.hasSuffix("\n") ? 0 : 1)
            }
        }
        return stat
    }

    /// The full patch since `base`, including untracked files, for review.
    public static func diff(workdir: String, base: String) async -> String {
        var patch = (try? await Shell.run(reading + ["diff", "--no-color", "--no-ext-diff", "--no-textconv", base], cwd: workdir).stdout) ?? ""
        for file in (try? await untracked(workdir)) ?? [] {
            let output = try? await Shell.run(
                reading + ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-index", "--", "/dev/null", file], cwd: workdir)
            patch += output?.stdout ?? ""
        }
        return patch
    }

    /// Untracked files, as paths: NUL-separated, so a name with a newline or one git would quote stays whole.
    static func untracked(_ workdir: String) async throws -> [String] {
        let command = reading + ["ls-files", "--others", "--exclude-standard", "-z"]
        let output = try await Shell.run(command, cwd: workdir)
        guard output.ok else { throw Shell.Failed(command: command, output: output) }
        return output.stdout.split(separator: "\0").map(String.init)
    }
}
