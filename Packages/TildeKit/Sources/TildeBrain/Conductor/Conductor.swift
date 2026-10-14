import Foundation
import Observation
import TildeMemory
import TildeSupport
import TildeWork
import WorkerKit

/// The hub: owns jobs, workers and open questions, routes worker events to the
/// manager, carries out the manager's tool calls, and publishes state for the UI.
///
/// This file holds its state and lifecycle. The rest is split by responsibility:
/// talking with the owner (`+Conversation`), running workers (`+Workers`), review
/// actions (`+Review`), speaking up unprompted (`+Initiative`, `+Briefing`), the memory
/// passes (`+Memory`), state on disk (`+Persistence`), and the manager's tools (`Tools/`).
@MainActor @Observable
public final class Conductor {
    /// Things the app turns into notifications, sounds, or surfaces.
    public enum Signal: Sendable {
        case asked(Attention)
        case resolved(attentionID: String)
        case said(String, jobID: String?)
        /// tilde finished writing back to something you said.
        case replied(String)
        case noted([Memory.Written])
        case jobChanged(Job)
        case trouble(String)
    }

    /// Today's conversation with tilde, oldest first.
    public internal(set) var thread: [Message] = []
    /// The last few messages of the previous conversation, shown above today's.
    public internal(set) var earlier: [Message] = []
    public internal(set) var jobs: [Job] = []
    public internal(set) var attention: [Attention] = []
    public internal(set) var trouble: String?
    /// The conversations of jobs someone is looking at (`loadTranscript`), by job id.
    public internal(set) var transcripts: [String: [JobEntry]] = [:]
    /// The owner's own coding agents in terminals, as the watchers last saw them.
    public internal(set) var terminalAgents: [TerminalAgent] = []

    @ObservationIgnored public let signals: AsyncStream<Signal>
    @ObservationIgnored let signal: AsyncStream<Signal>.Continuation
    @ObservationIgnored public let home: TildeHome
    @ObservationIgnored public let memory: Memory
    @ObservationIgnored public let projects: ProjectIndex
    @ObservationIgnored var manager: Manager!
    @ObservationIgnored var scribe: Scribe!
    @ObservationIgnored var dreamer: Dreamer!
    @ObservationIgnored var initiative: Initiative!
    /// The app sets this while the Inlet is open, so held news can be told.
    @ObservationIgnored public var looking = false
    @ObservationIgnored public weak var perception: (any Perception)?
    /// Each job's worker and the turn it's on, by job id (see `WorkerRun`).
    @ObservationIgnored var runs: [String: WorkerRun] = [:]
    /// Open worker requests: request id -> (job id, what was asked).
    @ObservationIgnored var requests: [String: (job: String, request: WorkerRequest)] = [:]
    @ObservationIgnored let log: TaskLog
    @ObservationIgnored let threads: ThreadStore
    @ObservationIgnored let transcriptStore: TranscriptStore
    /// The tilde message a tap's reply is being written into, while it's being written.
    @ObservationIgnored var replying: String?
    /// Taps whose reply only appears if tilde actually says something (welcome-backs).
    @ObservationIgnored var quietTaps: Set<String> = []
    @ObservationIgnored let initiativeEnabled: Bool
    /// The day `thread` belongs to.
    @ObservationIgnored var threadDay = Date.now
    /// What you said, by the id of tilde's reply to it, until tilde has it.
    @ObservationIgnored var unread: [String: (message: String, context: TapContext)] = [:]
    /// Replies to your answers: shown while tilde writes, and gone if it has nothing to add.
    @ObservationIgnored var optionalReplies: Set<String> = []
    /// Turns carrying your answers, whose exchange the scribe has already seen.
    @ObservationIgnored var answerTaps: Set<String> = []
    /// What the watchers last saw of your PRs, kept here so a message can take it along without waiting.
    @ObservationIgnored var watching = ""

    public struct Config: Sendable {
        public var manager = Manager.Config()
        /// The model behind the scribe, which files lasting facts after each exchange.
        public var scribe = CodexMemoryModel(effort: "low")
        /// The model behind the dream and the first meeting.
        public var dream = CodexMemoryModel(effort: "medium")
        /// The background review's model: read-only, with the owner's connected apps.
        public var review = CodexReviewModel()
        /// Watch PRs, agents and jobs, keep goals and the agenda, review in the background,
        /// brief each morning, and speak up when it matters.
        public var initiative = true
        public var projectRoots = ProjectIndex.defaultRoots
        public init() {}
    }

    public init(home: TildeHome = .default, config: Config = Config()) throws {
        self.home = home
        Log.use(home)
        projects = ProjectIndex(roots: config.projectRoots)
        memory = try Memory(home: home, projects: projects)
        log = TaskLog(notebook: memory.notebook)
        threads = ThreadStore(home: home)
        transcriptStore = TranscriptStore(folder: home.state.appending(path: "jobs"))
        initiativeEnabled = config.initiative
        (signals, signal) = AsyncStream<Signal>.makeStream(bufferingPolicy: .unbounded)
        manager = Manager(memory: memory, tools: makeTools(), config: config.manager, repositories: { [weak self] ids in
            await MainActor.run { ids.compactMap { self?.job($0) }.filter { $0.isolation != .scratch }.map(\.repoPath) }
        })
        scribe = Scribe(memory: memory, model: config.scribe)
        dreamer = Dreamer(memory: memory, home: home, model: config.dream) { [home, projects, notebook = memory.notebook] day in
            await Evidence.gather(day: day, home: home, notebook: notebook, projects: projects)
        }
        initiative = Initiative(home: home, review: config.review, projects: projects)
        // Everything tilde had open, loaded before the app is up, so nothing said in the first moments
        // lands on (and is saved over) an empty conversation.
        restore()
        thread = threads.load()
        earlier = threads.earlier(than: .now, last: Self.earlierShown)
        settleInterrupted()
        reconcileQuestions()
    }

    public func start() async throws {
        resumeActive()
        // Memory being unready (its index busy, a full disk) mustn't keep tilde from listening.
        do {
            try await memory.prepare()
        } catch {
            Log.info("memory", "couldn't prepare: \(error)")
            signal.yield(.trouble("My memory isn't ready (\(error)); I'll work without it for now."))
        }
        // The day's manager thread is kept open, so nobody waits for it to start, even on a new day.
        Task { [manager] in
            while !Task.isCancelled {
                await manager?.warm()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        Task { await dreamer.catchUp() }
        // A notebook that knows nothing of its owner starts with the first meeting, as promised.
        if isFirstMeeting { Task { await introduce() } }
        if initiativeEnabled { Task { await watch() } }
        Task { [weak self] in
            guard let outputs = self?.manager.outputs else { return }
            for await output in outputs { self?.handle(output) }
        }
        Task { [weak self] in
            guard let noted = self?.scribe.noted else { return }
            for await written in noted { self?.noteWritten(written) }
        }
    }

    // MARK: State

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    func update(_ jobID: String, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
        jobs[index].updatedAt = .now
        signal.yield(.jobChanged(jobs[index]))
        persist()
    }

    func addJob(_ job: Job) {
        jobs.append(job)
        persist()
    }

    /// Puts a question to the owner.
    func raise(_ item: Attention) {
        // The message first: if the day has just turned, the new thread mustn't carry this question over too.
        append(Message(from: .tilde, text: item.question, jobs: item.jobID.map { [$0] } ?? [], attentionID: item.id))
        attention.append(item)
        if let jobID = item.jobID { update(jobID) { $0.phase = .needsYou } }
        signal.yield(.asked(item))
        persist()
    }

    func dropAttention(for jobID: String) {
        for item in attention where item.jobID == jobID { signal.yield(.resolved(attentionID: item.id)) }
        attention.removeAll { $0.jobID == jobID }
    }

    func emit(_ s: Signal) {
        if case .said(let text, let jobID) = s { append(Message(from: .tilde, text: text, jobs: jobID.map { [$0] } ?? [])) }
        signal.yield(s)
    }

    /// Text from outside tilde (an agent, a PR comment, a CI log) as plain words: it can't open or close
    /// one of the manager's tags and pass itself off as tilde or the owner.
    nonisolated static func untrusted(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
    }

    /// How much of the previous conversation stays in view above today's.
    static let earlierShown = 6

    /// Makes text safe inside a double-quoted attribute of the manager's tags.
    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    }
}
