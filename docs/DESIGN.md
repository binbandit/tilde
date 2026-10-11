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

It reads like texting someone. tilde writes in grey bubbles on the left, you in blue on the right; a run of messages from one side sits close together, the last with a tail. Under the last thing you said, a receipt says whether tilde has it: Delivered, then Read and when. Anything that never reached tilde's model says Not delivered, with Try again. While tilde writes back, its bubble shows the typing dots, with what it's doing underneath ("Checking GitHub…"). Hover a bubble for its time.

What you say never waits behind tilde's own work: it's brought into whatever tilde is in the middle of, and answered first. Questions are answered by tilde itself, in a few seconds (what it knows about your PRs comes along with any question that mentions them); only work goes to agents. While tilde's question is the last thing said, what you type answers it; once you've said something since, it's a new message.

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
| Job | Wide: the agent's conversation, its changes, and what you can do | Click an agent's chip or dot |

The `~` mark is tilde's face. It breathes when idle, travels while agents work, follows your voice, glows amber when something needs you, and settles green when work is ready.

Notifications are only for when you're away (no input for a minute). While you're at the Mac, the Inlet does the talking.

Motion: the black is drawn from the bezel itself, so it never leaves the screen's edge. Opening, it grows out of the edge and content surfaces in it; closing, content is drawn back into the edge (shrinking, softening, fading) a beat ahead of the black, which lands with a small give, like a drop meeting a surface. One message replaces another by going back in as the next comes out.

## Answering

Every question tilde brings you has:

- one short line,
- 2 to 4 options, with **tilde's pick in amber**: short ones in a row, longer ones stacked as full-width rows, never wrapped inside a button,
- for an agent's request, "Always answer this way", which turns your answer into a standing rule in `rules.md`,
- a free-text field for anything else.

Answers to a worker's question go straight to the worker. The manager is told, and the scribe learns from what you chose.

A question waits until it's answered or stops mattering. tilde's own questions survive a restart and carry into the next day. One about a PR withdraws itself once the PR merges, closes, or recovers from what was wrong with it, and stays in the thread, dimmed, with why ("No longer needed: oh-fx#713 merged").

Coming back after a while away, tilde says what happened meanwhile, if anything did: work that finished, and how many new questions are waiting and what about (they're already on screen, so it doesn't repeat them).

## A job, opened

Click an agent (its chip in the conversation or its dot) and it opens wide out of the edge:

- **Conversation**: everything between the agent and the people directing it, the same for every harness. The agent speaks on the left; tilde's brief and every follow-up, tilde's or yours, sit in wells on the right. Its steps fold into one line, and what it asked, who answered, and where each turn ended are marked in between.
- **Changes**: the diff file by file, numbered on both sides, each file's name pinned while you read it. Big and generated files (lockfiles, snapshots) start folded. Clicking a line opens the file there in your editor. Work waiting for review opens here.
- **Talk to it**: what you type goes straight to the agent (tilde hears it too, and won't contradict you). When it's waiting on you, what you type answers it. A stopped agent picks its session back up. While it works, the button at the end of the field stops it.

Agents and tilde write Markdown, and it reads as written: lists, code, tables. While an agent works, what it's doing now shimmers.

Only the actions that fit where the job is:

| While it's | You can |
|---|---|
| Working or waiting | Stop (in the field), take over, open in your editor |
| Ready | Discard, take over, open in your editor, open its PR once there is one, **bring it in** (⌘↩); work done in place or in scratch is just **Done** |
| Stopped or failed | Discard, take over, open in your editor, or tell it how to carry on |
| Landed | Open its PR |

- **Bring it in**: rebase onto your current branch and fast-forward your checkout (never into a dirty tree).
- **Take over**: stops the worker and resumes its session in your terminal.

## Look

AMOLED: true black (#000) surfaces that melt into the bezel, white type, and colour only where it means something.

| Colour | Meaning |
|---|---|
| Amber | Needs you, or tilde's recommendation |
| Green | Ready, passing, added lines |
| Red | Failed, removed lines, destructive actions |
| Blue | You: what you say, and what you're pointing at |

Motion is spring-based: the shape morphs, it doesn't fade between screens. Text is pixel-aligned and crisp on Retina and on 1x external displays.

## Trust

- Every job gets its own git worktree; nothing touches your checkout until you bring it in.
- Rails: pushes, PRs, deploys, deletes outside the worktree, cloud and cluster commands, and sensitive apps under computer use always surface as explicit decisions, to you unless `rules.md` allows them.
- Every decision the manager makes is logged with its reason in `tasks/<job>.md`.
- Everything tilde knows is markdown in a git repo you own.
