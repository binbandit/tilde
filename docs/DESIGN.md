# tilde: design

## The idea

tilde is a coworker, not an app. You don't open it, you talk to it. It doesn't show you a chat log, it tells you what you need to know. It doesn't need supervising: it supervises the agents doing the work, makes the calls a trusted senior engineer would make, and brings you only what is genuinely yours to decide. Each decision comes with its recommendation, so you can answer in one tap.

Three things make it feel native rather than bolted on:

1. **It lives in the hardware.** One pure-black shape, the **Inlet**, merges with the bezel: on the right edge by default, on the left, or in the MacBook's notch.
2. **It understands pointing.** "Make *this* sticky" works because tilde sees what's under your cursor while you talk.
3. **It remembers.** Your preferences, your projects, what you did yesterday, every decision it made on your behalf. All of it lives in a notebook you can read (`docs/MEMORY.md`).

## Talking to it

| Gesture | What happens |
|---|---|
| Double-tap ⌥ | The Inlet opens with a text field. The thing under your cursor is noted as "this". |
| Double-tap ⌥ and hold the second press | The **Lens**, a blue outline, appears around what you're pointing at, and the Inlet shows what tilde hears as you speak. Move the pointer to re-aim. Release to send. |
| ⌥ with any other key | Just Option. tilde stays out of the way. |

The trigger is configurable (double-tap ⌘ or ⌃, hold right ⌥ or right ⌘, or Fn), because not every keyboard has a right Option key.

What gets captured with each request: the frontmost app and window, the document it shows (AXDocument), a terminal's working directory (read from its shell processes), the git repo that contains them, any selected text, and the job whose row you pointed at.

## The Inlet

States, each a morph of the same black shape:

| State | Looks like | When |
|---|---|---|
| Dormant | A hairline sliver with concave "ears" | Nothing on |
| Compact | The living `~`, with a dot per open job | Agents are working |
| Peek | Opens just enough to say one thing | A reply, a heads-up, a new question |
| Open | Everything: questions, jobs, ready work | Hover |
| Compose | Text field on top, everything below | Double-tap |
| Listening | Live transcript and what "this" is | Holding the trigger |
| Review | Wide: summary, diff, actions | Review a ready job |

The `~` mark is tilde's face. It breathes when idle, travels while agents work, follows your voice, glows amber when something needs you, and settles green when work is ready.

Notifications are only for when you're away (no input for a minute). While you're at the Mac, the Inlet does the talking.

## Answering

Every question tilde brings you has:

- one short line,
- 2 to 4 options, with **tilde's pick in amber**,
- an "Always" box that turns your answer into a standing rule in `rules.md`,
- a free-text field for anything else.

Answers to a worker's question go straight to the worker. The manager is told, and the scribe learns from what you chose.

## Review

A ready job opens wide out of the edge, with tilde's summary and the diff. Actions:

- **Bring it in**: rebase onto your current branch and fast-forward your checkout (never into a dirty tree).
- **Open in editor**: the worktree, or the exact file and line you click in the diff.
- **Pull request**: opens the job's PR if there is one, or asks tilde to open one your way.
- **Take over**: stops the worker and resumes its session in your terminal.
- **Discard**.

## Look

AMOLED: true black (#000) surfaces that melt into the bezel, white type, and colour only where it means something.

| Colour | Meaning |
|---|---|
| Amber | Needs you, or tilde's recommendation |
| Green | Ready, passing, added lines |
| Red | Failed, removed lines, destructive actions |
| Blue | What you're pointing at |

Motion is spring-based: the shape morphs, it doesn't fade between screens. Text is pixel-aligned and crisp on Retina and on 1x external displays.

## Trust

- Every job gets its own git worktree; nothing touches your checkout until you bring it in.
- Rails: pushes, PRs, deploys, deletes outside the worktree, cloud and cluster commands, and sensitive apps under computer use always surface as explicit decisions, to you unless `rules.md` allows them.
- Every decision the manager makes is logged with its reason in `tasks/<job>.md`.
- Everything tilde knows is markdown in a git repo you own.
