# How tilde remembers

A coworker you trust remembers what you told them, notices what you care about, keeps track of what you're working on, and doesn't need reminding. tilde's memory is built for that, and for being inspectable: everything it knows is plain markdown you can read, edit, and revert.

## The four parts

| Part | What it does | Where |
|---|---|---|
| **Notebook** | The source of truth: markdown notes in a git repo. Every change is a commit. | `~/.tilde/notebook` |
| **Index** | Hybrid recall over the notebook: SQLite FTS5 (BM25, porter stemming) fused with on-device transformer embeddings. Derived, and rebuilt whenever it's stale. | `~/.tilde/state/memory.sqlite` |
| **Scribe** | After each exchange, a cheap model reads what was said (plus the notes it touches) and files lasting facts: preferences, corrections, aliases, decisions, project facts. | `TildeMemory/Passes/Scribe.swift` |
| **Dream** | Once a day, a model turns the day's evidence into a journal entry, refreshes project notes, merges duplicates, resolves contradictions, and keeps `me.md` short. | `TildeMemory/Passes/Dreamer.swift` |

## The notebook

```
me.md               who you are and how you like things done (always in context)
rules.md            what agents may do without asking (always in context)
projects/<name>.md  paths, aliases, stack, how to build and test, decisions
topics/<name>.md    anything else worth knowing ("pull requests", "swiftui")
tasks/<job>.md      every delegated job: brief, each decision and why, outcome
goals/<slug>.md     standing goals tilde keeps moving: objective, done when, plan, log
agenda.md           follow-ups and routines, with their times (see docs/INITIATIVE.md)
journal/<date>.md   each day: a summary from the dream, plus tilde's log
```

Notes have light frontmatter (`kind`, `aliases`, `paths`, `updated`) and facts are bullets with a provenance stamp: `- Prefers Bun over pnpm. _(2026-10-08, told)_`. Sources are `told` (you said it), `noticed` (the scribe inferred it from what you said or chose), `imported` (first meeting), `surveyed` (read from a repo), and `dream`.

## Recall is automatic

Before every manager turn, tilde builds a `<memory>` briefing so the model never has to remember to look:

1. **The core** (`me.md`, `rules.md`) whenever it changed since the manager last saw it, and at the start of each day's session.
2. **Notes the message is about**, found by entity resolution: the repo, cwd or document you were pointing at matched against each note's `paths`, then names and aliases mentioned in what you said. "the paradise app" or a terminal sitting in `~/Developer/frontend/paradise` both pull in `projects/paradise.md`.
3. **The job notes** for any job the message concerns.
4. **Recalled chunks**: the best matches from hybrid search, with the long tail dropped.

The manager can also call `recall` with its own phrasing, and `remember` / `forget` when you ask.

### Why hybrid

Keyword search is precise ("notarize" finds "notarized") but misses paraphrase. Embeddings catch meaning ("the PR review app" finds Echo, "the receipts scanner" finds Filed Away) but are fuzzy. Each ranks the chunks and reciprocal rank fusion combines the ranks, with keyword weighted a little higher. Embeddings come from Apple's `NLContextualEmbedding` (on-device, mean-pooled). The older `NLEmbedding` sentence model scored near-identical sentences at 0.36, so it isn't used. Raw contextual vectors are anisotropic (unrelated sentences score about 0.75), so search subtracts the corpus mean first.

## Writing well

`Memory.remember` files a fact under the right note (resolving "me", a project name, alias or path, or a topic) and keeps the notebook from rotting:

- **Supersede, don't stack.** A new fact replaces the old one it updates: explicitly (`replaces`, which the scribe sets when it sees a contradiction in the notes it was shown), by normalized text, or by near-identical meaning (raw similarity of 0.95 or more, which also catches reversals like "prefers X over Y").
- **No secrets.** Tokens, keys, private keys and passwords are refused.
- **Every write is a commit**, described by the files it touched.

The scribe is told to keep only what will matter for months (preferences, corrections, decisions, project facts, standing instructions), never transient task detail, and to return nothing when there's nothing. Facts it files show up in the reply as "Noted", so you always see what was learned.

## Evidence for the dream

The dream reads only what's already on this Mac:

- **Focus time:** app and window spans recorded by tilde (titles and paths only, no screenshots), `~/.tilde/state/activity.jsonl`.
- **Commits:** yours, in repos active that day.
- **Every coding-agent session:** Claude Code transcripts and Codex rollouts, including ones you ran outside tilde. Summarized as directory, number of requests, and first request.
- **tilde's own log:** the day's journal log and job notes.

## First meeting

On first launch, with your consent, tilde reads the instruction files you already keep for agents (`~/AGENTS.md`, `~/.claude/CLAUDE.md`, following `@` includes) and distils them into `me.md`. It also surveys your most active repos (README, manifest, build files, agent instructions) into project notes. On day one it already knows how you work and what "the paradise app" means.

## Trust and control

- Read it: `open ~/.tilde/notebook` in any editor.
- See how it learned: `git -C ~/.tilde/notebook log`.
- Undo a memory: edit the note or `git revert` the commit; the index catches up on its own.
- Ask: "what do you know about paradise?", "forget that I prefer pnpm".
