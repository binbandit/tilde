import Foundation
import TildeSupport

/// Once a day tilde "dreams": it takes the day's evidence (where Brayden's
/// time went, what he committed, every agent session he ran, inside tilde or
/// not, and tilde's own job log) and has a model rewrite the notebook from it:
/// a journal entry for the day, fresher project notes, a tighter profile.
///
/// The scribe captures facts as they happen; the dream is the slower pass that
/// connects them, merges duplicates, and lets stale detail fade.
public actor Dreamer {
    private let memory: Memory
    private let home: TildeHome
    private let model: any MemoryModel
    /// The day's evidence as text for the model. Gathering it is the app's business.
    private let evidence: @Sendable (_ day: Date) async -> String
    private var running = false
    /// When a dream last failed: a day that won't dream is tried again every few hours, not on every message.
    private var failedAt: Date?

    /// Waits for whatever pass is running to finish: one at a time writes the notebook, and a rule the owner
    /// adds meanwhile isn't put back by the pass's guard on rules.md.
    public func whenIdle() async {
        while running { try? await Task.sleep(for: .seconds(2)) }
    }

    public init(
        memory: Memory, home: TildeHome, model: any MemoryModel, evidence: @escaping @Sendable (_ day: Date) async -> String
    ) {
        self.memory = memory
        self.home = home
        self.model = model
        self.evidence = evidence
    }

    /// Dreams about every day since the last one dreamt (up to a week back), once it's past 4am. A day
    /// whose dream fails is tried again next time rather than skipped.
    public func catchUp(now: Date = .now) async {
        let calendar = Calendar.current
        guard !running, calendar.component(.hour, from: now) >= 4, failedAt.map({ now.timeIntervalSince($0) > 3 * 3600 }) ?? true,
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
            let weekAgo = calendar.date(byAdding: .day, value: -6, to: yesterday)
        else { return }
        let after = lastDreamt.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) } ?? yesterday
        var day = max(after, weekAgo)
        while day <= yesterday, await dream(about: day), let next = calendar.date(byAdding: .day, value: 1, to: day) {
            day = next
        }
    }

    /// Consolidates one day into the notebook. Returns whether it's done (a day with nothing to dream about is).
    @discardableResult
    public func dream(about day: Date) async -> Bool {
        running = true
        defer { running = false }
        let evidence = await evidence(day)
        guard !evidence.isEmpty else {
            lastDreamt = day
            return true
        }
        Log.info("dream", "dreaming about \(Notebook.journalName(for: day)) (\(evidence.count) chars of evidence)")

        guard await run(evidence, instructions: Self.instructions(owner: Owner.firstName, day: day), commit: "dream about \(day.day)")
        else {
            failedAt = .now
            return false
        }
        failedAt = nil
        lastDreamt = day
        return true
    }

    // MARK: First meeting

    /// Gets to know someone on day one: distils the agent instructions they already
    /// keep into me.md and writes a note for each of their most active projects.
    /// `evidence` gathers those instructions and projects.
    public func introduce(evidence: @Sendable () async -> String) async {
        await whenIdle()
        running = true
        defer { running = false }
        await run(await evidence(), instructions: Self.meeting(owner: Owner.firstName), commit: "first meeting")
    }

    /// One editing pass over the notebook with `evidence` as the prompt.
    @discardableResult
    private func run(_ evidence: String, instructions: String, commit: String) async -> Bool {
        let rules = memory.notebook.read("rules.md")
        do {
            // It may read anywhere to learn a project; it writes only the notebook.
            let reply = try await model.run(ModelPass(
                instructions: instructions, prompt: evidence, workdir: memory.notebook.path, writable: true))
            keep(rules, after: commit)
            if reply.ok {
                await memory.refresh()
                await memory.notebook.commitChanges(context: commit)
            }
            return reply.ok
        } catch {
            keep(rules, after: commit)
            Log.info("dream", "\(commit) failed: \(error)")
            return false
        }
    }

    /// Rules are permissions, and only the owner adds those: whatever a pass did to them is undone.
    private func keep(_ rules: String?, after pass: String) {
        guard let rules, memory.notebook.read("rules.md") != rules else { return }
        try? rules.write(to: memory.notebook.url.appending(path: "rules.md"), atomically: true, encoding: .utf8)
        Log.info("dream", "\(pass) changed rules.md; put it back")
    }

    static func meeting(owner: String) -> String {
        let date = Date.now.day
        return """
            You are tilde meeting \(owner) for the first time. tilde is their assistant for agent work: it briefs and \
            supervises coding agents for them. Your working directory is tilde's notebook (markdown notes). You are given \
            the instruction files \(owner) already wrote for their coding agents, and their most active projects.

            1. Write me.md: who \(owner) is and how they like agents to work, distilled from the instruction files into \
            short third-person facts grouped under headings like "## Working style", "## Code preferences", "## Tools", \
            "## Pull requests", "## Never". Keep their exact wording where it matters (names of tools, hard rules). \
            Under 60 lines. Every fact ends with `_(\(date), imported)_`.
            2. For each active project, look at it (read-only: README, manifest such as package.json / Package.swift / \
            go.mod / Cargo.toml / justfile / Makefile, and AGENTS.md or CLAUDE.md if present) and write \
            projects/<name>.md: frontmatter (kind: project, aliases, paths: [repo path], updated: \(date)), "# <name>", \
            a one-line description, then "## Facts" (stack, structure, conventions) and "## How to build" (exact \
            commands). Only what you can see. Stamp facts `_(\(date), surveyed)_`. If two projects share a name, say how \
            they differ in each description so tilde can tell them apart.
            3. Leave everything else alone. Never write secrets. No em dashes.
            Reply with one line saying what you wrote.
            """
    }

    // MARK: State

    private var stateURL: URL { home.state.appending(path: "dream.json") }

    private var lastDreamt: Date? {
        get {
            (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }?["last"]
        }
        set {
            if let data = try? JSONEncoder().encode(["last": newValue ?? .distantPast]) { try? data.write(to: stateURL) }
        }
    }

    static func instructions(owner: String, day: Date) -> String {
        let date = day.day
        let pretty = day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return """
            You are tilde's dream: the once-a-day pass that keeps tilde's notebook (your working directory, a folder of \
            markdown notes) true, connected, and small. tilde is \(owner)'s assistant for agent work. You are given the \
            evidence for \(pretty): app and window activity, git commits, coding-agent sessions (inside and outside tilde), \
            and tilde's own log. Edit the notebook files directly. Do not touch anything outside it.

            Do this:
            1. Write journal/\(date).md: a short, specific account of the day in \(owner)'s terms: what they worked on \
            and for roughly how long (when activity shows it), what agents did for them, what shipped or landed, and \
            what's still open. Plain bullets without provenance stamps. Keep the existing "## Log" section if there is \
            one; put your account above it under "## Summary". Under 15 lines.
            2. Update projects/<name>.md for every project with real activity. Layout: the frontmatter (kind: project, \
            aliases, paths, updated: \(date)), "# <name>", a one-line description, then the sections that apply: \
            "## Now" (current focus), "## Facts", "## How to build" (exact commands), "## Decisions" (with the why). \
            Create a note only for a project with meaningful activity, with its repo path in `paths`.
            3. Tend me.md and topics/: merge duplicate facts, resolve contradictions in favour of the newer one, and \
            promote patterns you can see across days (a habit, a recurring preference) into facts. Keep me.md under 60 \
            lines; it is read at the start of every session.
            4. Leave tasks/ and rules.md alone except to fix obvious formatting.

            Rules:
            - Facts in notes are bullets ending with a provenance stamp like `_(\(date), dream)_`; keep existing stamps \
            on facts you keep. Write facts in the third person ("Prefers Bun.", "Builds with `pnpm build`.").
            - Only write what the evidence supports. Never write about what is missing or unknown ("not recorded", "no \
            outcome"): leave it out. No speculation, filler, secrets, or em dashes.
            - Be concise. Notes are read by a busy model before it acts; every line should earn its place.
            - When you're done, reply with one line saying what you changed.
            """
    }
}
