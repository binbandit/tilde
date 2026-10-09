import Foundation
import TildeSupport

/// The editors on this Mac that can open a file at a line from the command line.
public struct Editor: Sendable, Hashable, Identifiable {
    public var id: String { executable }
    public var name: String
    public var executable: String
    /// argv after the executable to open `path` at `line`.
    fileprivate var arguments: @Sendable (_ path: String, _ line: Int?) -> [String]

    public static func == (a: Editor, b: Editor) -> Bool { a.executable == b.executable }
    public func hash(into hasher: inout Hasher) { hasher.combine(executable) }

    /// In order of preference when nothing says otherwise.
    public static let known: [Editor] = [
        Editor(name: "Zed", executable: "zed") { path, line in [line.map { "\(path):\($0)" } ?? path] },
        Editor(name: "Cursor", executable: "cursor") { path, line in line.map { ["-g", "\(path):\($0)"] } ?? [path] },
        Editor(name: "VS Code", executable: "code") { path, line in line.map { ["-g", "\(path):\($0)"] } ?? [path] },
        Editor(name: "Xcode", executable: "xed") { path, line in line.map { ["-l", "\($0)", path] } ?? [path] },
        Editor(name: "Sublime Text", executable: "subl") { path, line in [line.map { "\(path):\($0)" } ?? path] },
    ]

    /// The editors installed here, best first. Xcode leads for Apple projects.
    public static func installed(for project: String? = nil) -> [Editor] {
        let path = UserEnvironment.shared.variables["PATH"] ?? ""
        var editors = known.filter { (try? ChildProcess.resolve($0.executable, path: path)) != nil }
        if let project, isApple(project), let xcode = editors.firstIndex(where: { $0.executable == "xed" }) {
            editors.insert(editors.remove(at: xcode), at: 0)
        }
        return editors
    }

    /// Opens a file or folder (at a line, when given).
    public func open(_ path: String, line: Int? = nil) async throws {
        try await Shell.check([executable] + arguments(path, line))
    }

    private static func isApple(_ project: String) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: project)) ?? []
        return files.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }
}
