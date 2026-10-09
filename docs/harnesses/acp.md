# Agent Client Protocol harnesses

Any agent that speaks the [Agent Client Protocol](https://agentclientprotocol.com) (ACP v1, schema 1.24) runs under one worker, `ACPWorker` (the `ACPWorkers` module). Each harness is just a `HarnessSpec` in `ACPHarnesses.specs` with its launch command. The protocol is JSON-RPC 2.0, one message per line on the agent's stdio.

## How ACP maps onto a tilde worker

| ACP | tilde |
|---|---|
| `initialize` | protocol 1; tilde offers `fs.readTextFile`, `fs.writeTextFile` and form `elicitation`, no `terminal` |
| `session/new` (`cwd` = worktree, `mcpServers: []`) | `.session(id:)` with the agent's session id |
| resume | `session/resume` when advertised (no replay), else `session/load` (its history replay is dropped), else a fresh session with a notice. A session that can't be reopened also starts fresh. |
| model | the session's `model` config option (`session/set_config_option`, matched by value or name), or the CLI flag or env var the harness documents |
| supervision brief | ACP has no system prompt, so a new session's first prompt opens with `<instructions from="tilde">...</instructions>` |
| `session/update` `agent_message_chunk` | chunks gather into one `.message` per `messageId`, cut at each tool call and at turn end |
| `tool_call` / `tool_call_update` | merged per `toolCallId`; `.activity` from `kind` + input ("Running swift build", "Editing Nav.swift") |
| `plan` | `.activity` with the entry in progress |
| `agent_thought_chunk` | `.activity("Thinking")` |
| `session/prompt` result | `.turnEnded(ok: stopReason == end_turn, text: last message)`; other stop reasons explain themselves, and a silent turn says what tilde declined |
| `session/request_permission` | triaged (below); answered with an `allow_once` or `reject_once` option, never an `always` one |
| `fs/write_text_file` | written in place inside the worktree; outside it, only after the manager approves (a `Write` request carrying the rail) |
| `fs/read_text_file` | served anywhere, with `line`/`limit`, like the agents' own read tools |
| `elicitation/create` (form) | `.request(.question)`, one question per field; the reply is typed per field (enum titles map to values) |
| `steer` mid-turn | queued, sent as the next `session/prompt` when the turn ends, and reported with it as one turn |
| `stop()` | `session/cancel`, pending requests answered `cancelled`, up to 2s to wind down, then the process group is terminated |

**Permissions are triaged like an auto mode.** ACP agents ask before acting, often for every edit and command. tilde lets through reads, searches and fetches, commands that cross no rail (`Rails.check`, plus commands run outside the worktree), and edits whose every path is inside the worktree. Anything else (a rail, an edit with no visible path, an MCP or unknown tool, a mode switch) becomes a `.request(.permission)` for the manager, with the rail reason attached. This is what Claude Code's auto mode plus the rails hook does, without sending every `ls` to the manager.

**Why steers queue rather than cancel.** ACP v1 has no way to add input to a running turn, and a second `session/prompt` while one runs is undefined (the v2 prompt-lifecycle RFD leaves queueing open). Cancelling would abort in-flight tool calls, leaving half-applied edits or killed builds. Queueing delivers the steer at the next opportunity, as `Worker.steer` promises, and folding it into the same reported turn means the manager never reviews half-finished work.

## Harnesses

All 14 launch commands match the [ACP registry](https://github.com/agentclientprotocol/registry) (checked 2026-10-08) and the vendor's own docs. "Resume" is the terminal take-over command, listed only where the ACP session id is known to be the id that command takes.

| Harness (id) | Command | Model | Resume | Source | Verified |
|---|---|---|---|---|---|
| OpenCode (`opencode`) | `opencode acp` | session option | `opencode --session <id>` | [opencode.ai/docs/acp](https://opencode.ai/docs/acp/), [permissions](https://opencode.ai/docs/permissions/) | Run here (1.18.35): real turns, resume, rail; docs |
| Gemini CLI (`gemini`) | `gemini --acp --approval-mode default` | `--model` | `gemini --resume <id>` | [acp-mode.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/acp-mode.md) | Docs, source (`config.ts`), registry |
| Qwen Code (`qwen`) | `qwen --acp --approval-mode default` | `--model` | `qwen --resume <id>` | [integration-zed.md](https://github.com/QwenLM/qwen-code/blob/main/docs/users/integration-zed.md) | Docs, source, registry |
| Goose (`goose`) | `GOOSE_MODE=approve goose acp` | `GOOSE_MODEL` | `goose session --resume --session-id <id>` | [goose ACP](https://github.com/aaif-goose/goose/blob/main/documentation/docs/gdk/acp/index.md), [env vars](https://github.com/aaif-goose/goose/blob/main/documentation/docs/guides/environment-variables.md) | Docs, source, registry |
| Kimi CLI (`kimi`) | `kimi acp` | session option | `kimi --session <id>` | [kimi-acp.md](https://github.com/MoonshotAI/kimi-cli/blob/main/docs/en/reference/kimi-acp.md) | Docs, registry |
| GitHub Copilot CLI (`copilot`) | `copilot --acp` (public preview) | `--model=` | | [ACP server](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server) | Docs, registry |
| Auggie (`auggie`) | `auggie --acp` | `--model` | | [docs.augmentcode.com/cli/acp](https://docs.augmentcode.com/cli/acp) | Docs, changelog, registry |
| Mistral Vibe (`vibe`) | `vibe-acp` | session option | `vibe --resume <id>` | [acp-setup.md](https://github.com/mistralai/mistral-vibe/blob/main/docs/acp-setup.md) | Docs, source, registry |
| Cursor (`cursor`) | `cursor-agent acp` | session option | | [cursor.com/docs/cli/acp](https://cursor.com/docs/cli/acp) | Docs, registry |
| Factory Droid (`droid`) | `droid exec --output-format acp` | `--model` | | [docs.factory.ai](https://docs.factory.ai/integrations/zed) | Docs, registry |
| Cline (`cline`) | `cline --acp` | `CLINE_MODEL` | `cline --id <id>` | [acp.mdx](https://github.com/cline/cline/blob/main/docs/usage/acp.mdx) | Docs, source, registry |
| Grok Build (`grok`) | `grok agent stdio` | `grok agent --model` | `grok --resume <id>` | [headless-scripting](https://docs.x.ai/build/cli/headless-scripting) | `initialize` handshake here (0.1.219); docs, registry |
| Junie (`junie`) | `junie --acp true` | session option | | [junie-cli-acp](https://junie.jetbrains.com/docs/junie-cli-acp.html) | Docs, registry |
| Kiro CLI (`kiro`) | `kiro-cli acp` | session option | | [kiro.dev/docs/cli/acp](https://kiro.dev/docs/cli/acp/) | Docs, official agents list |

Notes:

- **Cursor** ships its CLI as both `agent` and `cursor-agent`; tilde uses `cursor-agent` because Grok Build also installs an `agent`.
- **Factory's** docs launch `--output-format acp`; the registry uses the newer `acp-daemon`. tilde follows the vendor docs.
- **Claude Code and Codex** have ACP adapters (`claude-agent-acp`, `codex-acp`), but tilde drives both natively. Amp has only community adapters.

## OpenCode specifics (verified)

- OpenCode allows every tool by default, so it never asks and rails could never fire. tilde sets `OPENCODE_CONFIG_CONTENT` (merged over any you already set) to `permission: {bash: ask, edit: ask, external_directory: ask, question: deny}`. `question` is off because that tool has no ACP surface and would hang the turn; the agent asks in its reply instead.
- Its session ids (`ses_...`) are its native ids, and `session/resume` reopens them in a new process with the context intact.
- After an approved edit it also sends `fs/write_text_file` with the result, so writes outside the worktree are checked there too.
- Real run (2026-10-08, default model `opencode/big-pickle`): created and committed a file; a fresh process resumed the session and recalled the file; `git push origin HEAD` surfaced as `Shell: git push origin HEAD [Pushes to a remote]`, and once denied nothing reached the (local, bare) remote. Run it with `TILDE_REAL_ACP=1 swift test --filter ACPRealTests` (`TILDE_REAL_ACP_MODEL` picks the model).

## Known limitations

- **Rails need the agent to ask.** OpenCode and Goose are switched to asking, and Gemini and Qwen are pinned to `--approval-mode default`. The others ask by default, but a user setting that auto-approves (Kimi `default_yolo`, Copilot allow-all, Cline or Cursor auto-approve) means tilde never sees the call. Only OpenCode has been verified end to end.
- **A denial carries no reason.** ACP's permission outcome is just an option id, so the agent sees a plain rejection. The manager can explain with a steer.
- **The brief is a prompt, not a system prompt.** Agents that compact long sessions may summarize it away.
- **No terminal capability.** Agents run commands with their own tools; tilde sees them as tool calls.
- **Elicitation is form mode only**, and one reply answers every field. URL mode isn't offered.
- **Model choice depends on the agent.** A harness with neither a documented flag nor a `model` config option ignores `WorkerLaunch.model`; an unknown model name produces a notice and the agent's default.
- **No MCP servers are passed**; agents use their own configuration.
- **Sign-in is the user's.** tilde never authenticates; an auth error tells the user which CLI to open.
