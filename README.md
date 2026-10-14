# tilde

**Say it once. It's handled.**

tilde is a coworker that lives in your Mac. Point at something, say what you want, and it briefs the right coding agent, watches it work, answers its questions the way you would, and only interrupts you when something is genuinely yours to decide. It remembers how you like things done, what you're working on, and what you've been working on.

tilde lives in a black shape that sinks into the edge of your display, like a notch on its side. Its `~` menu-bar item opens Settings or quits the app; there's no Dock icon or main window.

## How it feels

- **Double-tap ⌥, hold the second tap, and talk** while pointing at anything: a terminal, a file in Finder, a selection in your editor. "Make *this* sticky." Release to send. (Double-tap without holding to type instead. The key is configurable.)
- **The Inlet** on the right edge is tilde's home. A hairline when there's nothing to say, a living `~` while agents work, amber when something needs you. Hover to see everything; questions are answerable right there, with tilde's recommendation already in amber.
- **Review** opens wide out of the edge: what was done, the diff, and one click to bring it into your checkout, ask for a PR, open it in your editor, take over the session in your terminal, or discard it.
- **Memory you can read.** Everything tilde knows is plain markdown in `~/.tilde/notebook`, a git repo. `git log` is how it learned; `git revert` is how you make it forget.
- **Start when you choose.** Launch at login is off by default. Enable it in Settings; tilde reports when macOS needs your approval in Login Items.

## How it works

- The **manager** is a Codex thread using your configured model and provider, with tilde's orchestration tools, briefed before every turn with the notes relevant to what you said. [Portkey and work gateways](docs/GATEWAYS.md) use the same Codex configuration.
- **Workers** are the agent CLIs you already use, with your own logins: Claude Code, Codex, and the ACP and stream-JSON harnesses (see `docs/harnesses/`). Each job gets its own git worktree, so agents never touch your checkout until you bring the work in.
- **Hard rails** in code: pushes, pull requests, deploys, and anything outside a job's worktree always come to the manager as explicit requests, and to you unless your rules allow them.
- **Memory** has four parts: the notebook (truth), a hybrid index (SQLite FTS5 plus on-device embeddings), a **scribe** that files lasting facts after each exchange, and a nightly **dream** that turns the day's evidence into a journal and fresher notes. See `docs/MEMORY.md`.

## Develop

```sh
just run        # generate the Xcode project, build, launch
just install    # build, replace and launch in /Applications (fallback: ~/Applications)
just install ~/Applications # choose an explicit destination
just test-install # test installation with scratch app bundles
just test       # the brain's unit tests (Packages/TildeKit)
just smoke ~/some/scratch/repo "add a CONTRIBUTING.md"   # headless end-to-end run
just show inlet "?mode=open"   # any surface, any state, with fixture data
just log        # follow ~/.tilde/state/tilde.log
```

Installation stages the build before stopping registered tilde app instances, replaces the complete bundle, and launches the exact installed path. Shutdown allows 10 seconds for a normal quit, then up to 3 seconds after force termination; if tilde still cannot stop, replacement aborts. Failed replacement or launch attempts restore the previous installation and restart previously running apps where possible. Installation prints the final path, and an explicit destination never falls back to another directory.

Requires macOS 27, Xcode 27, and at least one of `claude` / `codex` signed in. tilde needs Accessibility (to see what you point at), Microphone and Speech Recognition (to hear you), and Notifications (for when you're away).

| Path | What |
|---|---|
| `Tilde/` | The app: input, perception, the Inlet, review, notifications |
| `Packages/TildeKit/` | The brain: harnesses, manager, conductor, memory, git |
| `docs/DESIGN.md` | Product and interaction design |
| `docs/MEMORY.md` | How tilde remembers |
| `docs/HARNESSES.md` | How tilde drives Claude Code and Codex, verified against the installed CLIs |
| `docs/TERMINAL_AGENTS.md` | The agents you run yourself, in herdr or any terminal |

### Bounded automatic approvals

Automatic approval of worker permission requests is **off by default**. For an active job, its review panel offers “Automatically allow folder listings this turn.” This is an owner control, not a manager tool or a notebook rule. It expires at turn completion, a new follow-up, stop, exit, worker replacement, and app restart; it is never enabled by installation.

The exact supported scope is deliberately narrow: a Claude `Bash` permission callback for `/bin/ls '<job workdir>'` or `/bin/ls -1 '<job workdir>'`. The exact absolute job path may also be unquoted when it contains only shell-safe characters. No other arguments, commands, redirects, substitutions, environment changes, or current-directory assumptions are accepted. Listing folder names does not read file contents. An unsupported command still needs approval even if the manager calls it safe.

Only original structured Claude permission data can qualify. Requests without that data, blocked-path requests, sandbox escalation, network, credentials, writes, deletes, arbitrary scripts, builds, tests, and commands outside the exact scope still require the owner. Existing explicitly granted standing rails retain their existing behavior. This policy handles permission requests surfaced to tilde; it does not change the harness's native permissions or sandbox and cannot grant additional access.

Approval buttons are control actions. Decisions remain in the job transcript (`state/jobs/<job>.jsonl`) and task log, without adding “Allow” messages to the ordinary conversation. Successful jobs with a verified empty diff announce completion and offer **Done**. Code changes offer **Bring it in**. A missing or unreadable diff is not evidence of no changes, and failed or cancelled turns cannot be signed off. Acknowledgement retains the worktree for inspection or explicit discard.

The manager reads the root `AGENTS.md` for repository context. Before delegation it checks for new or changed instructions, and every launched or resumed worker gets the current root instructions scoped to its workdir, with a reminder to inspect more-specific files. Repository guidance remains below explicit owner instructions and permission rails. Worker output, external content, and passive observations cannot grant instruction authority or approval.
