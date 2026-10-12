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
- **Connected apps**: the connectors on your ChatGPT account (GitHub, Gmail, Google Calendar, Linear, ...) and the MCP servers you configured for Codex. The review pass may call only read-only tools: names that get/list/search/read/query/fetch, or tools annotated read-only.
- **Your agents**: Claude Code and Codex sessions on this Mac, inside tilde or not.
- **Your focus**: which apps, windows and repos your time went to. Titles and paths only.
- **The notebook**: goals, rules, project notes, recent journal, open tasks.

## The pipeline

```
sources ─▶ watchers ─────────────┐
       └─▶ background review ────┴─▶ notices ─▶ delivery policy ─┐
goals, follow-ups, routines (due) ───────────────────────────────┴─▶ manager ─▶ notch (peek) / notification (away)
```

- **Notice**: a key (dedupe), a subject (cooldown), urgency `now` / `soon` / `fyi`, the facts, a URL or local path, and a suggested action.
- **Delivery policy**:
  - `now` interrupts.
  - `soon` waits for a natural break (not typing).
  - `fyi` waits until you look (the Inlet opens) or come back.
  - At most 4 interruptions an hour.
  - Each key once, and each subject at most every 30 minutes.
  - Bot-authored PRs (dependabot, renovate) are `fyi`.
- **Due items** skip the policy: a follow-up, a routine run or a goal check-in is a commitment with a time, so it goes straight to the manager as `<due>`, and the manager decides what, if anything, to say.
- **Manager**: decides whether a notice deserves a word at all. It phrases it in tilde's voice and offers one-tap actions ("Fix it" / "Not now"). It delegates on a yes, or acts directly where rules allow. Silence is the default.

## Background review

- **When:**
  - the first activity of the day after 6am (that becomes the morning brief: its findings, held `fyi` notices, today's calendar, overnight changes and today's agenda go to the manager as `<brief>`, and it says nothing if nothing deserves a word)
  - when you return after 15 minutes or more
  - every 90 minutes or so while you're active but not typing
- **How:** a separate ephemeral Codex thread in a read-only sandbox, with your MCP connectors and only read-only tool calls allowed. One at a time, stopped after 4 minutes.
  - `approvalPolicy: never` alone isn't read-only: Codex runs any tool `config.toml` pre-approves (`approval_mode = "approve"`) without asking. So nothing may escalate except connector tool prompts; every app (`apps._default`, which covers the account's connectors, plus each configured one) and every configured server is put in `writes` mode for the thread (tools annotated read-only run; every other call prompts); and tilde answers each prompt itself: allowed only when the tool's name reads as a read (starts with get, list, search, read, query, fetch or view, names what it reads, and has no write verb in it; `gmail.search_emails` is judged by `search_emails`). A read of anything at all (a bare `fetch`, a URL, SQL, the web) is refused: it could write, or carry what the review read somewhere else.
  - Plugins aren't loaded at all (`features.plugins=false`): their servers, like computer use and the browser, act rather than read. Nor are your Codex hooks.
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
- Follow-ups and routines live in `agenda.md` (under `## Follow-ups` and `## Routines`), one bullet each, with a machine-readable time:
  - `- 2026-10-09 17:00 check on the nav bar (j-n8v3)`
  - `- every weekday 09:00 morning brief` (`every day`, `weekday`, `weekend`, or `monday` to `sunday`)
  - A follow-up is handed over once, even if late, and removed only when the manager accepts it. Until then it stays in the agenda; a failed send or a restart leaves it due for retry. A routine first seen waits for its next time, and one missed by more than 6 hours (the Mac was asleep) is skipped. A goal comes due once per `check-in`; the manager sets the next one.
- The manager gets tools to set, update and close goals, add and remove follow-ups and routines, and read the agenda. When something comes due, tilde posts `<due>` to the manager, which acts.

## Trust

Everything above is read-only until you say yes. Offers carry tilde's recommendation and an "Always" box that turns the answer into a rule. "Not now" teaches the Scribe what you don't care about, and the morning brief stays short.
