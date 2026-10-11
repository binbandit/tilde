# Harnesses

tilde drives the agent CLIs you already use, unmodified and with your own logins, through their documented machine interfaces. It never reads or stores credentials. Each harness is a `HarnessSpec` in its family's module (`ClaudeHarnesses`, `CodexHarnesses`, `ACPHarnesses`, `StreamHarnesses`), gathered by `HarnessCatalog` in the `Harnesses` module; the manager sees the installed ones, each with a one-line `strengths`, and picks per job.

| Family | Harnesses | Doc |
|---|---|---|
| Claude Code control protocol | Claude Code | below |
| Codex app-server (JSON-RPC) | Codex, Codex Computer Use | below |
| Agent Client Protocol | see `harnesses/acp.md` | `docs/harnesses/acp.md` |
| Headless JSON streams | see `harnesses/stream.md` | `docs/harnesses/stream.md` |

Everything below was verified against the installed CLIs (Claude Code 2.1.294, Codex 0.160.1) with throwaway repos on 2026-10-08.

## Claude Code

`claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --permission-prompt-tool stdio --permission-mode auto --session-id <uuid>`, plus `--append-system-prompt` with the supervision brief.

- **Control protocol over stdio.** With `--permission-prompt-tool stdio`, every permission prompt arrives on stdout as `{"type":"control_request","request":{"subtype":"can_use_tool","tool_name",...,"input",...}}` and tilde answers on stdin with `{"type":"control_response","response":{"subtype":"success","request_id",...,"response":{"behavior":"allow","updatedInput":{...}}}}` (or `deny` + `message`).
- **AskUserQuestion** comes through the same channel. Answer by allowing with `updatedInput` = the input plus `answers: {question: label}`.
- **In-process tools.** Sending `initialize` with `sdkMcpServers: ["tilde"]` and passing `--mcp-config '{"mcpServers":{"tilde":{"type":"sdk","name":"tilde"}}}'` makes Claude call tilde's MCP server as `control_request` `mcp_message`, so no helper binary or socket is needed.
- **Hooks.** `initialize` with `hooks: {"PreToolUse": [{"hookCallbackIds": ["tilde.pretool"]}]}` sends every tool call to tilde first (`hook_callback`). tilde answers `permissionDecision: "ask"` for anything crossing a rail, which forces it into `can_use_tool` even in auto mode.
- **Why auto mode plus rails.** `--permission-mode auto` lets Claude's classifier approve ordinary work instantly. In testing it also approved `git push` with no prompt, so the rails hook is what keeps outward actions explicit.
- **The sandbox.** Rails can't see what a shell line writes (a plugin reinstall rewrote `~/.claude/settings.json` without tripping one), so workers run with Claude Code's sandbox via `--settings` (`ClaudeSandbox`): Bash writes only to the worktree, the repo's `.git` (a worktree's commits land there) and build caches, and reaches only registries and source hosts. Blocked, Claude retries with `dangerouslyDisableSandbox: true` or `allowed_domains`, and auto mode approves both without asking, so the first is a rail and the second goes to the manager.
- **Startup commands.** Plugins can run a local command when a session starts, which reports its own `result` before tilde's turn has begun. `command_lifecycle` events name the command being run (`command_uuid` is the uuid of the user message that started it), so a `result` only ends tilde's turn when it belongs to a message tilde sent.
- **Session ids** are minted by tilde (`--session-id`), so "take over" is exactly `claude --resume <id>` in the worktree.
- **Auth.** Your normal Claude Code login. The Agent SDK is API-key only, which is why tilde speaks the CLI's own protocol instead.

## Codex

`codex app-server` (JSON-RPC 2.0 over stdio, `initialize` with `capabilities.experimentalApi: true`).

- `thread/start` takes `cwd`, `model`, `sandbox` (`workspace-write` for workers: no network, no writes outside the worktree plus `sandbox_workspace_write.writable_roots`, which tilde sets to the repo's `.git` so commits land), `approvalPolicy` (`on-request`), `developerInstructions` or `baseInstructions`, `dynamicTools` (experimental) and `config` overrides. Thread `config` takes nested objects, which Codex merges into `config.toml`, so any server name works.
- `turn/start` / `turn/steer` / `turn/interrupt`. Events: `item/started`, `item/completed`, `item/agentMessage/delta`, `turn/completed`.
- Server requests tilde answers: `item/commandExecution/requestApproval` and `item/fileChange/requestApproval` (`accept`/`decline`), `item/tool/requestUserInput`, `item/tool/call` (dynamic tools), `item/permissions/requestApproval` (grant the requested profile or nothing), and `mcpServer/elicitation/request` (computer use asks this way).
- **The manager is a Codex thread** using the owner's configured model and provider (see [gateways](GATEWAYS.md)): `sandbox: read-only`, `approvalPolicy: never`, `ephemeral`, tilde's tools as `dynamicTools`. A first `delegate` call lands in about 8s.
  - Read-only also means no network, and with `approvalPolicy: never` a networked shell could run `gh pr merge` unasked, so it stays off. GitHub reaches the manager through two tools tilde runs itself: `pull_requests` (what the watcher last saw, instantly) and `github` (live `gh`, only reading subcommands, `api` with GET or a GraphQL query without a mutation).
  - A sampling request can hang on a connection that never answers: Codex waits out its 300s stream idle timeout (twice, seen at 600s) before retrying, and the retry answers in seconds. Built-in providers can't be reconfigured per process, so tilde watches instead: 45s with nothing at all from Codex while no tool or command is running, and it interrupts the turn and asks the same thread to carry on; if the turn won't stop within 10s, a fresh process gets the turn again, with the tool calls already made listed so they aren't repeated.
  - What the owner says mid-turn is sent with `turn/steer` into the running turn, not queued behind it (background turns can take minutes).
- **tilde's own threads** (the manager, memory passes, the review) don't load what the owner set up for their own Codex sessions (`CodexSession.ownProcess`): `features.plugins=false` and `features.hooks=false`, `features.apps=false` except for the review, and every configured MCP server turned off per thread (`serversOff`). `-c mcp_servers={}` does not do this: Codex merges an override into the configured servers, so before this the manager, under `approvalPolicy: never`, had the owner's MCP servers, account connectors and the computer-use plugin.
- **Computer use** (`codex-computer`): the bundled computer-use plugin works through a `cua_repl` MCP tool and asks before touching apps via `mcpServer/elicitation/request` (form mode, `_meta.codex_approval_kind`). tilde routes each ask to the manager and marks sensitive apps as rails. Codex's own `computer_use.macos.bundle_ids` config denies mail, messages, password managers, wallets and System Settings outright.
