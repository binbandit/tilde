import Foundation
import TildeSupport

/// Raw permission data captured by a harness adapter, never a model's description of safety.
/// Unknown adapters and requests without this context cannot use automatic approval.
public struct PermissionContext: Sendable {
    public enum Source: Sendable {
        case claudeToolCallback
    }

    public let source: Source
    public let tool: String
    public let input: JSON
    /// The job this adapter was launched for. This is not a claim about a shell's current directory.
    public let workdir: String
    /// A harness-reported blocked path may require more access than this policy permits.
    public let blockedPath: String?

    public init(source: Source, tool: String, input: JSON, workdir: String, blockedPath: String? = nil) {
        self.source = source
        self.tool = tool
        self.input = input
        self.workdir = workdir
        self.blockedPath = blockedPath
    }
}

/// A deliberately small permission policy. Its caller must separately verify explicit owner opt-in.
/// It recognizes complete commands, not a safe-looking prefix, title, reason, or missing rail.
public enum AutomaticApprovalPolicy {
    /// A reason suitable for the audit log, or nil when the owner must decide.
    public static func reason(for request: WorkerRequest, workdir: String) -> String? {
        guard case .permission(let tool, _, nil) = request.kind,
            let context = request.permissionContext, context.tool == tool, tool == "Bash",
            context.workdir == workdir, workdir.hasPrefix("/"), workdir != "/",
            context.blockedPath == nil, let input = context.input.object,
            let command = input["command"]?.string,
            Rails.check(tool: tool, input: context.input, workdir: workdir) == nil
        else { return nil }

        // Extra fields can change execution, permissions, cwd, or the environment. Even false/null
        // values on unknown fields stay unknown. Description and a bounded timeout are only metadata.
        let known: Set<String> = ["command", "description", "timeout", "run_in_background", "dangerouslyDisableSandbox"]
        guard Set(input.keys).isSubset(of: known),
            input["description"] == nil || input["description"]?.string != nil,
            input["run_in_background"] == nil || input["run_in_background"] == .bool(false),
            input["dangerouslyDisableSandbox"] == nil || input["dangerouslyDisableSandbox"] == .bool(false)
        else { return nil }
        if let timeout = input["timeout"] {
            guard let milliseconds = timeout.number, milliseconds.isFinite, milliseconds > 0, milliseconds <= 120_000 else { return nil }
        }

        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workdir, isDirectory: &directory), directory.boolValue,
            !workdir.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        // Claude's callback does not supply a verified current directory. Every permitted command
        // therefore names the exact job folder. No PATH lookup, file contents, recursion, globbing,
        // arbitrary options, commands after a separator, or environment assignment is accepted.
        var paths = [quoted(workdir)]
        let literalCharacters = CharacterSet(charactersIn: "/abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.@+")
        if workdir.unicodeScalars.allSatisfy({ literalCharacters.contains($0) }) { paths.append(workdir) }
        for path in paths {
            if command == "/bin/ls \(path)" || command == "/bin/ls -1 \(path)" {
                return "Owner enabled bounded automatic approval for this job: list its folder names with /bin/ls."
            }
        }
        return nil
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
