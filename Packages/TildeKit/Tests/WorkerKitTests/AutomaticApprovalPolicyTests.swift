import Foundation
import Testing
import TildeSupport
@testable import WorkerKit

@Suite struct AutomaticApprovalPolicyTests {
    private func fixture(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "tilde-approval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    private func request(_ command: String, workdir: String, input: [String: JSON] = [:], rail: String? = nil, blockedPath: String? = nil) -> WorkerRequest {
        WorkerRequest(
            id: "request", kind: .permission(tool: "Bash", action: "The model says this is completely safe", rail: rail),
            permissionContext: PermissionContext(
                source: .claudeToolCallback, tool: "Bash", input: .object(input.merging(["command": .string(command)]) { _, new in new }),
                workdir: workdir, blockedPath: blockedPath))
    }

    @Test func onlyExactFolderListingsAreClassified() throws {
        try fixture { path in
            for command in ["/bin/ls '\(path)'", "/bin/ls -1 '\(path)'", "/bin/ls \(path)", "/bin/ls -1 \(path)"] {
                #expect(AutomaticApprovalPolicy.reason(for: request(command, workdir: path), workdir: path) != nil)
            }
            let input: [String: JSON] = ["description": "folder names", "timeout": 1000, "run_in_background": false, "dangerouslyDisableSandbox": false]
            #expect(AutomaticApprovalPolicy.reason(for: request("/bin/ls '\(path)'", workdir: path, input: input), workdir: path) != nil)
        }
    }

    @Test func shellAndFileAccessStayWithTheOwner() throws {
        try fixture { path in
            let commands = [
                "ls \(path)", "/bin/ls", "/bin/ls .", "/bin/pwd", "cd '\(path)' && /bin/pwd",
                "/bin/ls -la '\(path)'", "/bin/ls -R '\(path)'", "/bin/ls -L '\(path)'", "/bin/ls '\(path)/.git'",
                "/bin/ls '\(path)/../'", "/bin/ls '\(path)' /etc", "/bin/cat '\(path)/.env'", "git status",
                "/bin/ls '\(path)' && git push", "/bin/ls '\(path)' > out", "/bin/ls '\(path)' | cat",
                "/bin/ls '\(path)'\nrm -rf .", "/bin/ls $(pwd)", "ENV=anything /bin/ls '\(path)'",
                "eval /bin/ls '\(path)'", "/bin/ls '\(path)' # harmless", "/bin/ls '\(path)' ",
                "curl https://example.com", "rm -rf build", "sudo /bin/ls '\(path)'",
            ]
            for command in commands {
                #expect(AutomaticApprovalPolicy.reason(for: request(command, workdir: path), workdir: path) == nil, "\(command)")
            }
        }
    }

    @Test func missingOrAdditionalPermissionDataFailsClosed() throws {
        try fixture { path in
            let command = "/bin/ls '\(path)'"
            let additions: [[String: JSON]] = [
                ["allowed_domains": []], ["allowed_domains": ["example.com"]], ["cwd": .string(path)],
                ["env": [:]], ["dangerouslyDisableSandbox": true], ["dangerouslyDisableSandbox": "false"],
                ["run_in_background": true], ["description": [:]], ["timeout": "1000"], ["timeout": -1],
                ["timeout": 120_001], ["unknown": nil],
            ]
            for input in additions {
                #expect(AutomaticApprovalPolicy.reason(for: request(command, workdir: path, input: input), workdir: path) == nil)
            }
            #expect(AutomaticApprovalPolicy.reason(for: request(command, workdir: path, rail: Rails.outsideSandbox), workdir: path) == nil)
            #expect(AutomaticApprovalPolicy.reason(for: request(command, workdir: path, blockedPath: path), workdir: path) == nil)
            #expect(AutomaticApprovalPolicy.reason(for: request(command, workdir: path), workdir: path + "/different") == nil)
            let noMetadata = WorkerRequest(id: "missing", kind: .permission(tool: "Bash", action: command, rail: nil))
            #expect(AutomaticApprovalPolicy.reason(for: noMetadata, workdir: path) == nil)
            let question = WorkerRequest(id: "question", kind: .question([]), permissionContext: request(command, workdir: path).permissionContext)
            #expect(AutomaticApprovalPolicy.reason(for: question, workdir: path) == nil)
        }
    }

    @Test func literalPathsCannotAddShellSyntaxOrEscapeThroughASymlink() throws {
        try fixture { path in
            let special = "\(path)/quote' dollar$ semicolon; space"
            try FileManager.default.createDirectory(atPath: special, withIntermediateDirectories: true)
            let quoted = "'" + special.replacingOccurrences(of: "'", with: "'\\''") + "'"
            #expect(AutomaticApprovalPolicy.reason(for: request("/bin/ls \(quoted)", workdir: special), workdir: special) != nil)
            #expect(AutomaticApprovalPolicy.reason(for: request("/bin/ls \(special)", workdir: special), workdir: special) == nil)
            try FileManager.default.createSymbolicLink(atPath: "\(path)/escape", withDestinationPath: "/etc")
            #expect(AutomaticApprovalPolicy.reason(for: request("/bin/ls '\(path)/escape'", workdir: path), workdir: path) == nil)
        }
    }
}
