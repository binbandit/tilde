# Headless JSON-stream harnesses

For agents whose best machine interface is a headless mode with a JSON event stream rather than ACP. One worker, `StreamWorker` (the `StreamWorkers` module), runs them all; each harness is a `StreamDialect` (launch arguments, the stdin line for a prompt, a decoder from stdout lines to signals, its tool names in Claude Code's vocabulary, and how its gate works) plus a `HarnessSpec` in `StreamHarnesses.specs`.

## How a stream maps onto a tilde worker

| | Amp | Pi |
|---|---|---|
| Process | `amp --execute --stream-json --stream-json-input --settings-file <copy> --no-ide`, one per thread | `pi --mode rpc --extension <tilde-gate.ts> --append-system-prompt <brief> --session-id <id>` |
| Session | learned from `system`/`init` `session_id` (`T-...`) | minted by tilde (`mintsSessionID`); `--session-id` opens or creates it |
| Resume | `amp threads continue <id>` with the same flags | the same command |
| Model | `--mode <smart, rush, deep, ...>` on a new thread; a continued thread keeps its mode | `--model <pattern>` |
| Supervision brief | no system-prompt flag, so a new thread's first prompt opens with it, then `---` | `--append-system-prompt` |
| Prompt | `{"type":"user","message":{"role":"user","content":[...]}}`; follow-ups received while busy are queued until the current turn ends | `{"id":...,"type":"prompt","message":...,"streamingBehavior":"steer"}` (Pi ignores the steering mode when idle) |
| `.submitted` | just before the prompt is written; combined follow-ups report the latest ID | the prompt's matching response |
| `.activity` | top-level `assistant` `tool_use` blocks | `tool_execution_start` |
| `.message` | top-level `assistant` text; subagent messages (with a `parent_tool_use_id`) are dropped | `message_end` text from the assistant |
| `.turnEnded` | a top-level `assistant` with `stop_reason: end_turn` and no tool use (Amp's own test); an error `result` ends it failed; successful `result` summaries are ignored | `agent_settled` (failed if `aborted`); a refused `prompt` or a `stopReason: error` message fails it |
| `.notice` | error `system` and `result` messages | `auto_retry_start`, `compaction_start`, `extension_error`, warning and error `notify` |
| Questions | none in headless mode | other extensions' `select`, `confirm`, `input` and `editor` dialogs become `.request(.question)` |
| `stop()` | close stdin and SIGTERM the group (Amp's handler ends the run cleanly), SIGKILL after 5s | `{"type":"abort"}`, up to 3s to settle, then the same |

**One process, many turns.** Follow-ups go down stdin. If the process exits between turns (Amp does after an error result), the worker stays and the next `steer` starts a new process on the same session. An exit mid-turn with no result is `.exited("<Harness> exited (<code>). <stderr>")`. A `WorkerLaunch.sessionID` is always resumed: Amp ids only exist once Amp has reported them, so this holds even when a launch says `resume: false`.

**Ordered submissions.** Amp has no correlated prompt acknowledgment, so tilde serializes its prompts. While a follow-up is queued, the preceding completion dispatches the queue instead of reporting success for the new instruction. A later successful `result` is a run summary, which may arrive after that dispatch or only when stdin closes; it cannot complete the next turn. Pi echoes the prompt's request ID in its preflight response, allowing mid-turn steering without treating an already buffered `agent_settled` as the new instruction's completion. Exiting while an acknowledgment is pending ends the worker even if the preceding turn has already settled.

Pi must acknowledge a `started` or `queued` model turn. Its `handled` disposition means an extension consumed the prompt without starting one; tilde reports that as unverified rather than using the preceding turn's result. Unknown dispositions also fail verification.

## The gate

Neither harness can show a permission prompt to a headless client, so tilde puts its own gate in front of every shell command and file write. The worker maps each call to Claude Code's vocabulary (`Bash` + `command`, `Write`/`Edit` + `file_path`, relative paths anchored to the worktree) and runs `Rails.check`. A call that crosses no rail is allowed at once; one that does becomes `.request(.permission(tool:action:rail:))`, and the manager's answer, with its reason, goes back to the agent.

**Amp: `delegate` rules.** In stream-json mode a tool that needs approval ends the whole run ("The following tools require user approval, which is not supported in stream JSON mode", read from the installed CLI), so an `ask` rule is never an option. Amp's permission rules can instead `delegate` to a program: Amp runs it with `AGENT_TOOL_NAME` set and the tool input as JSON on stdin; exit 0 allows, 2 rejects and shows stderr to the model. tilde starts Amp with `--settings-file` pointing at a copy of the user's settings (`AMP_SETTINGS_FILE` or `~/.config/amp/settings.json`) with delegate rules for `Bash`, `shell_command`, `create_file`, `edit_file`, `apply_patch`, `delete_file` and `undo_edit` first and `amp.dangerouslyAllowAll` forced off. The program is `tilde-gate`, a shell script tilde writes: it drops the call into a folder the worker watches (`GateMailbox`) and waits for the verdict, rejecting if the request disappears or tilde's process is gone. Both live in a per-worker temp folder that is deleted on stop.

**Pi: an extension.** tilde writes `tilde-gate.ts` and loads it with `--extension`. It hooks `tool_call` for `bash`, `edit` and `write` and calls `ctx.ui.input("tilde:gate", <call as JSON>)`, which RPC mode sends as an `extension_ui_request`. The worker answers with an `extension_ui_response` whose value is `allow` or `deny: <reason>`, and the extension blocks with the reason. Calls made from inside other tools (codemode scripts) pass the same hook.

What the gate does not cover:

- Other tools: MCP tools, Amp's tools beyond the delegated ones, and Pi extension tools run ungated (`Rails` has no rule for them either).
- Amp workspace rules in a repo's `.amp/settings.json` could be evaluated before tilde's; not verified.
- Amp's guarded-files check (paths like `.git` or `.venv`) asks before any rule runs. Headless, that should end the run as a failed turn the manager sees (read from the binary, not exercised).
- `apply_patch` is checked file by file from its `*** Add/Update/Delete File:` and `*** Move to:` headers.
- Amp now calls `amp.permissions` legacy (plugins are the new hook, but load only from config folders tilde must not touch), so a future Amp could drop it.
- The user's own Pi extensions run with full permissions. Untrusted project `.pi` resources are skipped, as Pi does by default in RPC mode.

## Harnesses

| Harness (id) | Command | Permissions | Resume | Source | Verified |
|---|---|---|---|---|---|
| Amp (`amp`) | `amp -x --stream-json --stream-json-input` | `delegate` rules to tilde's gate helper | `amp threads continue <id>` | [Streaming JSON](https://ampcode.com/docs/cli/streaming-json), [Execute mode](https://ampcode.com/docs/cli/execute-mode), [permissions](https://ampcode.com/notes/permissions) | Installed 0.0.1778252358 (2026-05-08): `--help`; delegate protocol run with `amp permissions test`; stdin parsing, turn end and approval handling read from the binary. A real run reached Amp's servers, which reject this version (HTTP 426, "no longer supported"), so no model turn completed; the worker reported that as a failed turn. Fakes for the rest. |
| Pi (`pi`) | `pi --mode rpc` | extension over the RPC extension UI | `pi --session <id>` | [RPC](https://pi.dev/docs/latest/rpc), and `cli.md`, `rpc-commands.md`, `rpc-extension-ui.md`, `json.md`, `extensions.md` in `@earendil-works/pi-coding-agent` 1.1.0 | Not installed here. Flags, prompt queueing and dialog handling checked in the 1.1.0 package's shipped source (`cli/args.js`, `modes/rpc/rpc-mode.js`, `core/agent-session.js`). Fakes. |

**Not here, and why** (checked 2026-10-08):

- ACP-capable, so they belong in [acp.md](acp.md): Cursor (`cursor-agent acp`), Factory Droid (`droid exec --output-format acp`), Cline, Grok Build, and the rest listed there. Also ACP-capable but not yet listed: Devin CLI (`devin acp`), OpenHands (`openhands acp`), Qoder CLI.
- Aider has no event stream; scripting it prints text.
- Charm Crush's `crush run` prints plain text (its JSON output flag was removed).
- Warp's agent CLI documents no headless JSON mode.

## Tests

- `swift test --filter Stream`: fake harnesses (`Tests/StreamWorkersTests/Fixtures/fake_amp.py`, `fake_pi.py`) for turns, the gate, steering, resume and stop; a recorded Amp stream (`amp-outdated.jsonl`) and representative streams for decoding.
- `TILDE_REAL_STREAM=1 swift test --filter StreamRealTests`: the installed `amp` on a throwaway repo, in `rush` mode: create and commit a file, a `git push` that must surface as a rail and is denied, then a resume in a new process.

## Limitations

- Amp's brief is a prompt, not a system prompt, so compaction may summarize it away.
- Amp follow-ups wait for the current turn to end before being sent. Several waiting follow-ups are combined into one prompt, and only the latest submission ID is reported when it is dispatched.
- Amp has no headless question tool; agents ask in their reply.
- The settings copy can hold whatever the user keeps in Amp's settings (an MCP server's env, a Bitbucket token). It is written 0600 and deleted on stop, but a crash leaves it in the temp folder until macOS cleans it.
- tilde passes no MCP servers; agents use their own configuration. Sign-in is the user's.
