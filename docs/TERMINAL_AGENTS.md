# Terminal agent discovery

Terminal discovery is off until you explicitly enable a supported harness for one project in Settings. It observes lifecycle metadata from the CLI's documented hooks. It does not attach to the CLI, control a terminal, send prompts, make permission decisions, call a model, or read transcripts or credentials. Existing terminal sessions are discovered only after they emit a hook event.

## Supported adapters

The adapters below follow official documentation checked on 2026-10-12. These are documented interfaces, not a claim of live CLI verification. Use a CLI release that supports the listed project hook file and events; older versions or disabled/managed hooks can leave the inbox empty. Registration deliberately does not enable hooks or bypass their trust review.

| Harness | Project file | Lifecycle events |
|---|---|---|
| Claude Code | `.claude/settings.local.json` | `SessionStart`, `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` |
| Codex | `.codex/hooks.json` | `SessionStart`, `UserPromptSubmit`, `Stop`, `Interrupt`, `SessionEnd` |
| Gemini CLI | `.gemini/settings.json` | `SessionStart`, `BeforeAgent`, `AfterAgent`, `SessionEnd` |

Claude's [hook reference](https://code.claude.com/docs/en/hooks) documents the common `session_id`, `cwd`, and `hook_event_name` input fields and project-local settings. Codex's [hooks](https://developers.openai.com/codex/hooks) use the same fields and require trust of the exact hook definition through `/hooks` in a trusted project. Gemini's [hook reference](https://geminicli.com/docs/hooks/reference/) and [configuration](https://geminicli.com/docs/hooks/) document the equivalent input and project settings; its timeout unit is milliseconds, while Claude and Codex use seconds.

These adapters track main sessions only. Events identifying a subagent through `agent_id` are rejected so a child cannot overwrite the parent's state. Codex Computer Use shares Codex's terminal CLI and hook adapter; it is not a separate discoverable process type.

## Catalog boundaries

Terminal observation is separate from tilde's ability to launch and supervise a worker. [ACP](https://agentclientprotocol.com/protocol/v1/overview) delivers updates to the client that owns the agent's protocol connection. Likewise, the [stream harnesses](harnesses/stream.md) expose events on their launched process's stream. Neither interface supplies a generic passive subscription to another terminal's existing session.

| Catalog harnesses | Passive terminal coverage in this version |
|---|---|
| Claude Code, Codex, Codex Computer Use | Claude/Codex adapters above |
| Gemini CLI (ACP family) | Gemini adapter above |
| OpenCode, Qwen, Goose, Kimi, Copilot, Auggie, Vibe, Cursor, Droid, Cline, Grok, Junie, Kiro | No terminal adapter implemented; tilde-launched ACP workers retain their existing supervision |
| Amp, Pi | No terminal adapter implemented; tilde-launched stream workers retain their existing supervision |

“No adapter implemented” does not mean a vendor has no extension interface. For example, [OpenCode plugins](https://opencode.ai/docs/plugins/), [Copilot hooks](https://docs.github.com/en/copilot/reference/hooks-reference), [Cursor hooks](https://cursor.com/docs/hooks), and [Pi extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md) expose vendor-specific events. They need their own validated adapter and config-preservation tests before registration can support them. There is no transcript-scanning fallback.

## Registration and removal

Settings uses the bundled `Contents/Helpers/tilde-agent-hook`. The standalone helper supports the same operations:

```sh
swift build --package-path Packages/TildeKit --product tilde-agent-hook
/absolute/path/to/tilde-agent-hook install claude /absolute/path/to/project
/absolute/path/to/tilde-agent-hook install codex /absolute/path/to/project
/absolute/path/to/tilde-agent-hook install gemini /absolute/path/to/project
/absolute/path/to/tilde-agent-hook list
/absolute/path/to/tilde-agent-hook sessions
/absolute/path/to/tilde-agent-hook remove REGISTRATION_UUID
```

Registration prints the ID, edited project file, and the vendor's review step. Restart the project session and review its hooks as directed. Installing the same project/adapter again updates the helper path without duplicating hooks. Move an installed app only after removing its registrations, or register those projects again at its new path. All generated command arguments are shell-quoted, including paths containing apostrophes.

Only these observer commands are merged into project config. Other settings, hooks, permissions, and trust decisions are preserved. Malformed configuration, symlinks, unsafe ownership or permissions, and oversized files are rejected. The home directory and filesystem root cannot be registered as projects. No user-level hook is installed. Codex may warn when a project has both inline TOML hooks and `hooks.json`; it merges those sources, and tilde does not rewrite the TOML file.

Configuration is rewritten as formatted JSON. Gemini's line and block comments are accepted when reading, but comments and original formatting are not retained; setting values and unrelated hook definitions are preserved.

Removal revokes the registration before touching project configuration. A leftover command after failed cleanup is inert, and its next payload is rejected. If the project file was edited or became unavailable, Settings can report the cleanup failure even though discovery has stopped. Remove the leftover observer command manually after repairing that file. Removal never removes unrelated handlers or deletes a user's configuration file.

## Local ingress and limits

`TildeHome.default` uses `$TILDE_HOME`, falling back to `~/.tilde`. A generated command includes the absolute home used at registration through `--home`, so a terminal with a different environment cannot accidentally send to another notebook. Every CLI command also accepts `--home /absolute/path`. Tests use a scratch home and scratch projects.

The registry and sanitized inbox live in `state/terminal-agents/` inside that home. The directory is private (0700), new files are 0600, file operations reject symlinks and wrong ownership, and updates use a local nonblocking lock and atomic replacement. Event input is at most 64 KiB, stdin waits at most one second, config files are at most 512 KiB, and the registry/inbox hold at most 128 registrations and 512 sessions. Ingress fails closed for unknown or revoked registration IDs, malformed types, unsupported events, invalid session IDs, subagent events, and working directories outside the canonical registered project. Payload fields cannot choose storage paths or an adapter.

Only registration ID, adapter, session ID, registered project, working directory, mapped lifecycle state, and local receipt time enter the inbox. Unknown fields, including prompts, assistant text, tool inputs, transcript paths, model identifiers, and vendor timestamps, are ignored and never persisted or logged. A large prompt carried by a vendor hook can cause the entire event to exceed the input limit and be dropped. The helper always responds to hook calls with `{}` and exit 0, including rejected payloads; it returns no instructions or permission verdict.

Observations are best effort. A busy inbox drops an event instead of delaying the agent, and another hook may continue a turn after a stop event. No heartbeat or process liveness is inferred. Session states become stale after 30 minutes without an event, disappear from summaries after one day, and old stored entries are pruned on subsequent ingress. `SessionEnd` is best effort and may be absent after a crash. These observations cannot prove that an agent is still running, its terminal tab is open, or its work succeeded.

Registration is a local opt-in boundary, not isolation from other programs running as your macOS user. The helper has no network listener. The app does not use hook data as instructions or automatically take over, resume, steer, or approve an observed session.

## Verification

`TerminalAgentTests` checks all supported event mappings, config preservation and idempotence, revocation, isolation between registrations, size/type/path rejection, symlink handling, and omission of sensitive payload fields. Run without agent credentials or model calls:

```sh
swift test --package-path Packages/TildeKit --filter TerminalAgentTests
python3 scripts/test-terminal-hooks.py /absolute/path/to/tilde-agent-hook
```

The app's build copies and signs `tilde-agent-hook` inside its bundle. Full bundle/Xcode verification needs the required Xcode release; the SwiftPM product and scratch CLI workflow can be checked independently.
