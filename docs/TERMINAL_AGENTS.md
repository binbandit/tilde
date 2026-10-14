# Agents in your terminals

Not every agent is one tilde started. tilde also keeps an eye on the ones you run yourself, in [herdr](https://herdr.dev) or any other terminal, so you can see them all in one place and hand a job back and forth. There's nothing to set up and nothing is written into your projects.

## Finding them

Every minute, alongside its other watchers, tilde looks in two places:

| Where | How | What tilde learns |
|---|---|---|
| **herdr** | `herdr agent list`, when herdr is installed and its server is running | The agent, its folder, its pane and name, its session id when herdr knows it, and how it's doing: working, blocked, done (finished, not looked at yet) or idle |
| **Any other terminal** | The process table (libproc and `sysctl`): any agent CLI in tilde's catalog with a controlling terminal | The agent, its folder, and the app it runs in (Ghostty, Terminal, VS Code...) |

Agents running inside a herdr pane are left to herdr, agents started by another agent count as part of it, and tilde's own workers are never counted. Outside herdr there's no reliable way to tell whether an agent is working or waiting without reading its transcript, which tilde never does, so those show as simply running.

## What tilde does with them

- **In the Inlet** they follow tilde's crew as rings rather than dots: amber when one is waiting on you, green when it finished and you haven't looked, white while it works. Hover for which and where; click to bring it forward (herdr focuses its pane, any other terminal comes to the front).
- **It speaks up** about herdr's agents only: one that has sat at an approval or a question for a minute or more, and one that finished work you haven't seen. If you get to it first, tilde says nothing.
- **The manager knows** about the ones in the project you're talking about, or all of them when you ask about your agents or terminals. It sees them, but it can't drive them.

## Taking over into herdr

**Take over** stops a job's worker and resumes its session where you can drive it. With herdr installed, that's herdr: a workspace of its own, named after the job and opened in its worktree, running the harness's resume command (`claude --resume <id>`) as an agent herdr knows by the job's id, so it shows its state like any other. If no herdr client is open, tilde opens your terminal (Ghostty when it's installed, else Terminal) running `herdr`, which starts the server too. Taking over the same job again just brings it back to the front.

Without herdr, take over opens a new terminal window running the resume command, as before.

tilde uses the herdr session your shell does: `HERDR_SESSION` when it's set, otherwise the default.
