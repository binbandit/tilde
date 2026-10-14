import AppKit
import Observation
import TildeKit

/// Everything the Inlet shows, and the actions it can take. Normally a window
/// onto the Conductor; in debug it can show fixtures instead.
@MainActor @Observable
final class AppModel {
    let conductor: Conductor?
    let startupError: String?
    /// Your calendar and reminders, read-only.
    let schedule = Schedule()

    /// Debug-only stand-in state, so every look can be seen in every state.
    var fixture: Fixture?

    /// While the tilde key is held: what you're saying and how loudly.
    var listening: Listening?
    /// The composer's text.
    var draft = ""
    /// You held the key to talk, but tilde isn't allowed to hear you.
    var cantHear = false
    /// You held the key to talk, and nothing was heard.
    var missedYou = false

    struct Listening: Equatable {
        var transcript = ""
        var level = 0.0
    }

    struct Fixture {
        var thread: [Message] = []
        var earlier: [Message] = []
        var jobs: [Job] = []
        var attention: [Attention] = []
        var transcripts: [String: [JobEntry]] = [:]
        var diff = ""
        var terminalAgents: [TerminalAgent] = []
    }

    init() {
        do {
            conductor = try Conductor()
            startupError = nil
        } catch {
            conductor = nil
            startupError = "\(error)"
        }
    }

    var thread: [Message] { fixture?.thread ?? conductor?.thread ?? [] }
    var earlier: [Message] { fixture?.earlier ?? conductor?.earlier ?? [] }
    var jobs: [Job] { fixture?.jobs ?? conductor?.jobs ?? [] }
    var attention: [Attention] { fixture?.attention ?? conductor?.attention ?? [] }
    /// Your own coding agents, running in terminals.
    var terminalAgents: [TerminalAgent] { fixture?.terminalAgents ?? conductor?.terminalAgents ?? [] }

    /// The jobs to keep in view: open ones, and failed ones with a worktree or scratch folder still to look at
    /// or discard (work done in place has nothing of its own to clear).
    var crew: [Job] {
        jobs.filter { $0.phase.isOpen || ($0.phase == .failed && $0.isolation != .inPlace) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func job(_ id: String?) -> Job? { id.flatMap { id in jobs.first { $0.id == id } } }

    /// What's waiting on you about a job, if anything.
    func question(for jobID: String) -> Attention? { attention.last { $0.jobID == jobID } }

    /// The question tilde just asked, while it's the last thing said: anything said since (by either
    /// of you) means what you type is a new message, and the question keeps its own buttons.
    var openQuestion: Attention? {
        guard let id = thread.last?.attentionID else { return nil }
        return attention.first { $0.id == id }
    }

    // MARK: Talking

    func send(_ text: String, about referent: Referent?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if fixture != nil {
            var said = Message(from: .you, text: text, pointing: referent?.label)
            said.delivery = .read(.now)
            fixture?.thread.append(said)
            fixture?.thread.append(Message(from: .tilde, text: "", streaming: true))
            return
        }
        conductor?.tap(text, context: referent?.context ?? TapContext())
    }

    /// Sends again something that never reached tilde.
    func retry(_ message: Message) {
        if let i = fixture?.thread.firstIndex(where: { $0.id == message.id }) {
            fixture?.thread[i].delivery = .read(.now)
            return
        }
        conductor?.retry(message.id)
    }

    func answer(_ item: Attention, with reply: String, always: Bool = false) {
        if fixture != nil {
            fixture?.attention.removeAll { $0.id == item.id }
            if let i = fixture?.thread.firstIndex(where: { $0.attentionID == item.id }) { fixture?.thread[i].attentionID = nil }
            fixture?.thread.append(Message(from: .you, text: reply, jobs: item.jobID.map { [$0] } ?? []))
            return
        }
        conductor?.answer(item.id, with: reply, always: always)
    }

    // MARK: A job's agent

    /// The job's conversation with its agent. Call `loadTranscript` first so it stays current.
    func transcript(_ jobID: String) -> [JobEntry] { fixture?.transcripts[jobID] ?? conductor?.transcripts[jobID] ?? [] }

    func loadTranscript(_ jobID: String) {
        guard fixture == nil else { return }
        conductor?.loadTranscript(jobID)
    }

    /// Talks to the job's agent directly.
    func message(_ job: Job, _ text: String) async throws {
        if fixture != nil {
            fixture?.transcripts[job.id, default: []].append(JobEntry(from: .you, kind: .message, text: text))
            if let i = fixture?.jobs.firstIndex(where: { $0.id == job.id }) {
                fixture?.jobs[i].phase = .working
                fixture?.jobs[i].ticker = "Working on your message"
            }
            return
        }
        try await conductor?.message(job.id, text)
    }

    func stop(_ job: Job) async {
        guard fixture == nil else { return }
        await conductor?.stop(job.id)
    }

    // MARK: Review

    func diff(_ jobID: String) async -> String {
        if let fixture { return fixture.diff }
        return await conductor?.diff(jobID) ?? ""
    }

    func refreshPullRequest(_ jobID: String) async {
        guard fixture == nil else { return }
        await conductor?.refreshPullRequest(jobID)
    }

    func land(_ jobID: String) async throws {
        guard fixture == nil else { return }
        try await conductor?.land(jobID)
    }

    func discard(_ jobID: String) async {
        guard fixture == nil else { return }
        await conductor?.discard(jobID)
    }

    /// Scratch work has nothing to land; this marks it done.
    func dismiss(_ jobID: String) async {
        guard fixture == nil else { return }
        await conductor?.dismiss(jobID)
    }

    /// Stops the worker and resumes its session in your terminal.
    func takeOver(_ job: Job) async {
        guard fixture == nil, let (command, cwd) = await conductor?.takeOver(job.id) else { return }
        await Terminal.takeOver(command, in: cwd, title: job.title, name: job.id)
    }

    /// Brings one of your own agents forward: its herdr pane, or the terminal it runs in.
    func focus(_ agent: TerminalAgent) {
        guard fixture == nil else { return }
        Task { await Terminal.focus(agent) }
    }

    // MARK: Editors

    func editors(for job: Job) -> [Editor] { Editor.installed(for: job.workdir) }

    /// Opens the job's worktree, or one of its files at a line, in the first installed editor.
    func open(_ job: Job, file: String? = nil, line: Int? = nil) {
        guard let editor = editors(for: job).first else { return reveal(job) }
        open(job, in: editor, file: file, line: line)
    }

    func open(_ job: Job, in editor: Editor, file: String? = nil, line: Int? = nil) {
        let path = file.map { (job.workdir as NSString).appendingPathComponent($0) } ?? job.workdir
        Task { try? await editor.open(path, line: line) }
    }

    func reveal(_ job: Job) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.workdir)])
    }
}

/// Your terminal: where a session you take over goes, and where your own agents run.
enum Terminal {
    /// Resumes a session in herdr when it's installed, in a workspace of its own beside your other agents;
    /// otherwise in a new terminal window.
    static func takeOver(_ command: String, in cwd: String, title: String, name: String) async {
        guard Herdr.isInstalled else { return run(command, in: cwd) }
        // With no herdr client open, one is opened first: it starts herdr's server if that isn't running.
        let client = await Herdr.clientApp()
        if client == nil { run("herdr", in: cwd) }
        do {
            try await Herdr.resume(command, in: cwd, label: title, name: name)
            if let client { activate(client) }
        } catch {
            Log.info("terminal", "herdr couldn't take over \(name): \(error)")
            run(command, in: cwd)
        }
    }

    static func focus(_ agent: TerminalAgent) async {
        switch agent.place {
        case .herdr(let pane):
            await Herdr.focus(pane: pane)
            if let client = await Herdr.clientApp() { activate(client) } else { run("herdr", in: agent.cwd) }
        case .terminal(_, let app):
            if let app { activate(app) }
        }
    }

    /// Brings a running app forward, from tilde's non-activating panels too.
    private static func activate(_ app: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: config)
    }

    /// Opens a new terminal window running `command` in `cwd`: Ghostty when it's installed, else Terminal.
    static func run(_ command: String, in cwd: String) {
        if let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--working-directory=\(cwd)", "-e", "/bin/zsh", "-lc", command]
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: ghostty, configuration: config)
            return
        }
        let script = TerminalCommand.appleScript(command, in: cwd)
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}
