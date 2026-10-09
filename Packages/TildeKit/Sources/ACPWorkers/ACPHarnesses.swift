import Foundation
import TildeSupport
import WorkerKit

/// Harnesses that speak the Agent Client Protocol, each driven by `ACPWorker`.
/// Launch commands are verified against each vendor's docs and the ACP
/// registry; see docs/harnesses/acp.md. Resume commands are listed only where
/// the ACP session id is known to be the id the CLI resumes.
public enum ACPHarnesses {
    public static let specs: [HarnessSpec] = [
        acp(
            "gemini", "Gemini CLI", executable: "gemini",
            strengths: "Google's Gemini models with a very large context window; good for understanding big codebases and long documents.",
            resume: { "gemini --resume \($0)" }, selectsModel: false
        ) { model in
            // `default` asks before edits and shell, whatever the user's settings say, so rails apply.
            ["--acp", "--approval-mode", "default"] + option("--model", model)
        },
        acp(
            "qwen", "Qwen Code", executable: "qwen",
            strengths: "Qwen3-Coder (or any OpenAI-compatible model) in a Gemini CLI fork; a low-cost option for routine, well-specified changes.",
            resume: { "qwen --resume \($0)" }, selectsModel: false
        ) { model in
            ["--acp", "--approval-mode", "default"] + option("--model", model)
        },
        acp(
            "goose", "Goose", executable: "goose",
            strengths: "Open-source, provider-agnostic agent built around MCP extensions; good when the task needs the user's own tools and integrations.",
            resume: { "goose session --resume --session-id \($0)" }, selectsModel: false,
            // Goose approves everything by default; `approve` makes it ask, so rails apply.
            environment: { model in ["GOOSE_MODE": "approve"].merging(model.map { ["GOOSE_MODEL": $0] } ?? [:]) { $1 } }
        ) { _ in ["acp"] },
        acp(
            "opencode", "OpenCode", executable: "opencode",
            strengths: "Open-source, provider-agnostic agent with LSP-aware edits; runs whichever models the user has signed in to.",
            resume: { "opencode --session \($0)" },
            environment: { _ in ["OPENCODE_CONFIG_CONTENT": openCodeConfig] }
        ) { _ in ["acp"] },
        acp(
            "kimi", "Kimi CLI", executable: "kimi",
            strengths: "Moonshot's Kimi models; inexpensive and capable for well-scoped coding tasks.",
            resume: { "kimi --session \($0)" }
        ) { _ in ["acp"] },
        acp(
            "copilot", "GitHub Copilot CLI", executable: "copilot",
            strengths: "GitHub-native, with several model families under a Copilot subscription; strong on repository, issue and Actions work.",
            selectsModel: false
        ) { model in
            ["--acp"] + (model.map { ["--model=\($0)"] } ?? [])
        },
        acp(
            "auggie", "Auggie", executable: "auggie",
            strengths: "Augment's Context Engine gives it strong semantic retrieval across very large codebases.",
            selectsModel: false
        ) { model in
            ["--acp"] + option("--model", model)
        },
        acp(
            "vibe", "Mistral Vibe", executable: "vibe-acp",
            strengths: "Mistral's Devstral models in an open-source agent; another model family for everyday coding.",
            resume: { "vibe --resume \($0)" }
        ) { _ in [] },
        acp(
            "cursor", "Cursor", executable: "cursor-agent",
            strengths: "Cursor's agent with the user's Cursor rules and model lineup."
        ) { _ in ["acp"] },
        acp(
            "droid", "Factory Droid", executable: "droid",
            strengths: "Model-agnostic agent tuned for long, multi-step engineering tasks.",
            selectsModel: false
        ) { model in
            ["exec", "--output-format", "acp"] + option("--model", model)
        },
        acp(
            "cline", "Cline", executable: "cline",
            strengths: "Open-source, bring-your-own-provider agent with separate plan and act modes.",
            resume: { "cline --id \($0)" }, selectsModel: false,
            environment: { model in model.map { ["CLINE_MODEL": $0] } ?? [:] }
        ) { _ in ["--acp"] },
        acp(
            "grok", "Grok Build", executable: "grok",
            strengths: "xAI's Grok models with subagents; a fast, different model family for a second attempt.",
            resume: { "grok --resume \($0)" }, selectsModel: false
        ) { model in
            ["agent"] + option("--model", model) + ["stdio"]
        },
        acp(
            "junie", "Junie", executable: "junie",
            strengths: "JetBrains' agent; strongest on JVM and Kotlin projects."
        ) { _ in ["--acp", "true"] },
        acp(
            "kiro", "Kiro CLI", executable: "kiro-cli",
            strengths: "AWS's spec-driven agent; suited to AWS-heavy work and plan-first changes."
        ) { _ in ["acp"] },
    ]

    /// One ACP harness. `arguments` and `environment` receive the requested
    /// model, for agents that take it at launch (`selectsModel: false`).
    private static func acp(
        _ id: String, _ label: String, executable: String, strengths: String,
        resume: (@Sendable (String) -> String)? = nil, selectsModel: Bool = true,
        environment: @escaping @Sendable (_ model: String?) -> [String: String] = { _ in [:] },
        arguments: @escaping @Sendable (_ model: String?) -> [String]
    ) -> HarnessSpec {
        HarnessSpec(id: Harness(rawValue: id), label: label, executable: executable, strengths: strengths, resumeCommand: resume) { launch in
            ACPWorker(
                ACPCommand(
                    label: label, executable: executable, arguments: arguments(launch.model),
                    environment: UserEnvironment.shared.variables.merging(environment(launch.model)) { $1 },
                    selectsModel: selectsModel),
                launch: launch)
        }
    }

    private static func option(_ flag: String, _ value: String?) -> [String] {
        value.map { [flag, $0] } ?? []
    }

    /// OpenCode allows every tool by default, so it never asks. Shell and edits
    /// ask instead, so tilde can apply its rails; its `question` tool is off
    /// because it has no ACP surface and would hang the turn. Merged over any
    /// inline config the user already sets.
    static var openCodeConfig: String {
        var config = UserEnvironment.shared.variables["OPENCODE_CONFIG_CONTENT"].flatMap { JSON.parse($0)?.object } ?? [:]
        let ours: [String: JSON] = ["bash": "ask", "edit": "ask", "external_directory": "ask", "question": "deny"]
        config["permission"] = .object((config["permission"]?.object ?? [:]).merging(ours) { $1 })
        return JSON.object(config).compact
    }
}
