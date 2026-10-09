# Initiative: tilde as an executive assistant

A good EA doesn't wait to be asked. They know your goals and your day, notice what's slipping, connect things you haven't connected, and bring you a short list with a proposed next step for each. They never bring noise. tilde does that for your work, locally, with read-only eyes and nothing done without your yes (unless `rules.md` says it can).

## Abilities

| Ability | What it means |
|---|---|
| **Goals** | Standing objectives you hand off ("ship paradise's checkout this week", "keep my PRs green"). tilde plans the next step, delegates, follows up, and reports, until done. |
| **Follow-ups** | Commitments with a time: "check on the nav bar at 5", "remind me to review Sam's PR after lunch". |
| **Routines** | Things on a schedule: a morning brief, a Friday "what shipped", a nightly test run on main. |
| **Watchers** | Cheap, deterministic, read-only checks that notice state changes: PRs (checks, reviews, conflicts, ready to merge, review requests), main going red after your merge, your own agent sessions waiting on you, tilde's jobs stalled or forgotten. |
| **Background review** | A periodic read-only model pass that connects the dots across every source and proposes a few genuinely useful things. |
| **Briefings** | The morning brief at your first sit-down, and a short "while you were away" when you come back. |

## Sources (all read-only)

- **Calendar and Reminders**: EventKit, from the app. Today's and the next few hours' events with attendees and notes, and reminders due.
- **GitHub**: through your `gh` login. Your PRs, review requests, notifications, CI on default branches.
- **Connected apps**: the MCP servers you already configured for Codex (Linear, docs, Slack, ...). The review pass may call only read-only tools: names that get/list/search/read/query/fetch, or tools annotated read-only.
- **Your agents**: Claude Code and Codex sessions on this Mac, inside tilde or not.
- **Your focus**: which apps, windows and repos your time went to. Titles and paths only.
- **The notebook**: goals, rules, project notes, recent journal, open tasks.

## The pipeline

```
sources ─▶ watchers ─────────────┐
       └─▶ background review ────┼─▶ notices ─▶ delivery policy ─▶ manager ─▶ notch (peek) / notification (away)
goals, follow-ups, routines (due) ┘
```

- **Notice**: a key (dedupe), a subject (cooldown), urgency `now` / `soon` / `fyi`, the facts, a URL or local path, and a suggested action.
- **Delivery policy**:
  - `now` interrupts.
  - `soon` waits for a natural break (not typing).
  - `fyi` waits until you look (the Inlet opens) or come back.
  - At most 4 interruptions an hour.
  - Each key once, and each subject at most every 30 minutes.
  - Bot-authored PRs (dependabot, renovate) are `fyi`.
- **Manager**: decides whether a notice deserves a word at all. It phrases it in tilde's voice and offers one-tap actions ("Fix it" / "Not now"). It delegates on a yes, or acts directly where rules allow. Silence is the default.

## Background review

- **When:**
  - the first activity of the day (that becomes the morning brief)
  - when you return after 15 minutes or more
  - every 90 minutes or so while you're active but not typing
- **How:** a separate ephemeral Codex thread, read-only sandbox, never `approvalPolicy` escalation, with your MCP connectors and only read-only tool calls allowed.
- **It gets:**
  - goals with their status
  - open loops: unanswered questions, unlanded work, stale branches, follow-ups due soon
  - today's calendar
  - recent focus
  - the latest watcher state
  - the core notebook (`me.md`, `rules.md`)
- **It returns** structured JSON: up to 3 notices. Each has evidence ("Sam commented on #12 an hour ago; your 3pm with Sam is about pricing"), a proposed action, and urgency.
- **It is told:**
  - connect sources rather than restate them
  - prefer things blocked on you or time-sensitive
  - never repeat what tilde already said today (it gets the day's thread)
  - return nothing when nothing is worth it

## Goals, follow-ups, routines in the notebook

- `goals/<slug>.md`:
  - frontmatter: `status` (active / paused / done), `check-in` (next time to review), `project` (path)
  - sections: Objective, Done when, Plan, Log
- Follow-ups and routines live in `agenda.md`, one bullet each, with a machine-readable time:
  - `- 2026-10-09 17:00 check on the nav bar (j-n8v3)`
  - `- every weekday 09:00 morning brief`
- The manager gets tools to set, update and close goals, add and remove follow-ups and routines, and read the agenda. When something comes due, tilde posts `<due>` to the manager, which acts.

## Trust

Everything above is read-only until you say yes. Offers carry tilde's recommendation and an "Always" box that turns the answer into a rule. "Not now" teaches the Scribe what you don't care about, and the morning brief stays short.
