import Foundation
import TildeSupport

extension Git {
    /// Everything the job changed since `base`: commits plus uncommitted and untracked work.
    public static func diffStat(workdir: String, base: String) async -> DiffStat {
        let numstat = (try? await Shell.check(["git", "diff", "--numstat", base], cwd: workdir)) ?? ""
        var stat = DiffStat(files: 0, insertions: 0, deletions: 0)
        for line in numstat.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            stat.files += 1
            stat.insertions += Int(cols[0]) ?? 0
            stat.deletions += Int(cols[1]) ?? 0
        }
        let untracked = (try? await Shell.check(["git", "ls-files", "--others", "--exclude-standard"], cwd: workdir)) ?? ""
        for file in untracked.split(separator: "\n") {
            stat.files += 1
            let path = (workdir as NSString).appendingPathComponent(String(file))
            if let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty {
                stat.insertions += text.filter { $0 == "\n" }.count + (text.hasSuffix("\n") ? 0 : 1)
            }
        }
        return stat
    }

    /// The full patch since `base`, including untracked files, for review.
    public static func diff(workdir: String, base: String) async -> String {
        var patch = (try? await Shell.run(["git", "diff", "--no-color", base], cwd: workdir).stdout) ?? ""
        let untracked = (try? await Shell.check(["git", "ls-files", "--others", "--exclude-standard"], cwd: workdir)) ?? ""
        for file in untracked.split(separator: "\n") {
            let output = try? await Shell.run(
                ["git", "diff", "--no-color", "--no-index", "/dev/null", String(file)], cwd: workdir)
            patch += output?.stdout ?? ""
        }
        return patch
    }
}
