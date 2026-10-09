# Working on tilde

tilde is a macOS app (Swift 6, SwiftUI + AppKit, macOS 27) with its logic in a local Swift package. Read `README.md`, then `docs/DESIGN.md` before UI work and `docs/MEMORY.md` before memory work.

## Layout

- `Tilde/` is the app target (MainActor by default). Surfaces are SwiftUI views hosted in non-activating panels; the Inlet is the only home. It imports only `TildeKit`.
- `project.yml` generates the Xcode project (`just gen`); the `.xcodeproj` is not checked in.
- `Packages/TildeKit/` holds all non-UI logic and is tested with `swift test`. Keep it free of AppKit. It is one module per layer, and SwiftPM enforces that dependencies only point down:

```
TildeKit              what the app imports: re-exports the modules below, no code of its own
└─ TildeBrain         the manager, the conductor and its tools, initiative, memory wiring
   ├─ TildeWork       jobs, git worktrees and landing, projects on this Mac
   ├─ TildeMemory     the notebook, its index, the scribe and dream passes
   └─ Harnesses       the catalog: every family's specs in one list
      └─ ClaudeWorkers · CodexWorkers · ACPWorkers · StreamWorkers   one per protocol
         └─ WorkerKit     the worker contract: Worker, HarnessSpec, rails, toolsets, activity
            └─ TildeSupport   processes, JSON, logging, paths, ids; no domain knowledge
```

  - TildeMemory depends only on TildeSupport, and TildeWork only on TildeSupport and WorkerKit (for the `Harness` id). TildeBrain also imports CodexWorkers directly, because the manager and the memory passes run on Codex threads.
  - Harness families never import each other or anything above WorkerKit. Shared behaviour goes down into WorkerKit or TildeSupport.
  - Tests mirror the modules (`Tests/<Module>Tests`); a target's fixtures live in its own `Fixtures/`.

### Adding to it

- **A harness in an existing family**: add a `HarnessSpec` to that family's `specs` (`ACPHarnesses`, `StreamHarnesses`, ...). Nothing else changes.
- **A harness family**: a new `<Name>Workers` module that depends on `WorkerKit` and `TildeSupport`, with its `Worker` and a `public enum <Name>Harnesses { public static let specs }`. Add the target and its test target to `Package.swift`, add it to `Harnesses`' dependencies, and append its specs to `HarnessCatalog.families`.
- **A manager tool**: define the `AgentTool` and its implementation in its group's file in `TildeBrain/Tools/` (delegation, supervision, conversation, memory, agenda), then list it in `makeTools()` in `Tools.swift`. Tell the manager when to use it in `ManagerPrompt` if the description isn't enough.
- **A watcher**: a type in `TildeBrain/Initiative/Watchers/` that turns what it reads into `[Notice]`, called from `Initiative.look`. Watchers only observe; `Initiative.due` decides when anything is said.
- **Something for the background review to see**: a field on `Review.Inputs` with its section in `Review.prompt` and `Review.instructions` (`TildeBrain/Initiative/Review/Review.swift`), gathered in `Conductor.reviewInputs` (`Conductor+Briefing.swift`). The review only reads; its connector calls are fenced by `ReadOnlyTools`.
- **A memory pass**: lives in `TildeMemory/Passes/`, builds a `ModelPass` and runs it on the `MemoryModel` it's given, so memory never knows which model runs it. Anything it needs from outside the notebook (git, transcripts, jobs) is gathered in `TildeBrain/Memory/Evidence.swift` and handed in. The conductor creates it.

## Rules

- Build fresh. Don't copy code from other projects.
- Never test against real repos: use scratch fixtures (`just smoke`), and `TILDE_HOME` to point the brain at a scratch notebook.
- Workers never get more than their worktree. Anything outward-facing is a rail (`WorkerKit/Rails.swift`) and must stay one.
- Never put secrets in the notebook (`Memory.looksSecret`).
- AMOLED design: pure black surfaces, white text, colour only for meaning (amber needs you, green ready, red failed, blue pointing). No glass.
- No em dashes in code, copy, or prompts.
- Check UI changes visually: `just show <surface>` plus `screencapture`, in every state.
