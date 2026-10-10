import Foundation
import TildeMemory
import TildeSupport
import WorkerKit

/// Talking with the owner: what they say and answer, and tilde's side of the day's thread.
extension Conductor {
    // MARK: Brayden

    /// Brayden said something. Returns the id of tilde's reply in the thread.
    @discardableResult
    public func tap(_ text: String, context: TapContext = TapContext()) -> String {
        let id = IDs.make("t")
        Task { await dreamer.catchUp() }
        append(Message(from: .you, text: text, pointing: context.pointing, jobs: context.jobID.map { [$0] } ?? []))
        append(Message(id: id, from: .tilde, text: "", streaming: true))
        replying = id
        let attributes = ([("at", Date.now.formatted(date: .omitted, time: .shortened))] + context.attributes)
            .map { "\($0.0)=\"\(Self.escape($0.1))\"" }.joined(separator: " ")
        var body = text
        if let selected = context.text, !selected.isEmpty {
            body += "\n<selection>\n\(selected.clipped(to: 4_000, keepLines: true))\n</selection>"
        }
        Task {
            await manager.post(.init(
                "<tap \(attributes)>\n\(body)\n</tap>", tap: id,
                paths: [context.repo, context.cwd, context.document].compactMap { $0 },
                jobs: context.jobID.map { [$0] } ?? []))
        }
        return id
    }

    /// Brayden answered an escalation. `always` turns the answer into a standing rule.
    public func answer(_ attentionID: String, with reply: String, always: Bool = false) {
        guard let index = attention.firstIndex(where: { $0.id == attentionID }) else { return }
        let item = attention.remove(at: index)
        signal.yield(.resolved(attentionID: item.id))
        persist()

        var forwarded = false
        if let requestID = item.requestID, let pending = requests[requestID] {
            let answer: WorkerAnswer =
                switch pending.request.kind {
                case .permission: WorkerAnswer.isYes(reply) ? .allow : .deny("\(Owner.firstName) said: \(reply)")
                case .question: .reply(reply)
                }
            resolve(requestID, answer, by: .you)
            forwarded = true
        }
        if let jobID = item.jobID { update(jobID) { if $0.phase == .needsYou { $0.phase = .working } } }

        let job = item.jobID.flatMap { id in jobs.first { $0.id == id } }
        if always, let job {
            Task { try? await memory.notebook.addRule("\(reply) when asked \"\(item.question)\" in \(job.projectName).") }
        }
        if let jobID = item.jobID {
            log.append(jobID, "\(Owner.firstName) answered \"\(item.question)\": \(reply)")
            if !forwarded { record(jobID, .you, .decision, "answered tilde: \(reply)") }
        }
        if let i = thread.firstIndex(where: { $0.attentionID == item.id }) { thread[i].attentionID = nil }
        append(Message(from: .you, text: reply + (always ? " (always)" : ""), jobs: item.jobID.map { [$0] } ?? []))

        let tag = "<answer to=\"\(item.id)\"\(item.jobID.map { " job=\"\($0)\"" } ?? "")\(forwarded ? " delivered-to-worker=\"yes\"" : "")>"
        Task {
            await manager.post(.init(
                "\(tag)\nQuestion: \(item.question)\nAnswer: \(reply)\(always ? "\n(They asked to always do this.)" : "")\n</answer>",
                jobs: item.jobID.map { [$0] } ?? []))
        }
        Task {
            await scribe.reflect(on: "tilde asked \(Owner.firstName): \(item.question) Options: \(item.options.joined(separator: " / ")).\n\(Owner.firstName) answered: \(reply)\(always ? " (always)" : "")")
        }
    }

    /// Takes back a question that no longer needs an answer, leaving it in the thread with why.
    func withdraw(_ attentionID: String, because reason: String) {
        guard let index = attention.firstIndex(where: { $0.id == attentionID }) else { return }
        let item = attention.remove(at: index)
        signal.yield(.resolved(attentionID: item.id))
        persist()
        Log.info("initiative", "withdrew \"\(item.question)\": \(reason)")
        guard let i = thread.firstIndex(where: { $0.attentionID == item.id }) else { return }
        thread[i].attentionID = nil
        thread[i].settled = reason
        saveThread()
    }

    // MARK: Manager output

    func handle(_ output: Manager.Output) {
        switch output {
        case .reply(let taps, let text):
            for tap in taps { writeReply(tap, text, done: false) }
        case .replyDone(let taps, let text):
            for tap in taps { writeReply(tap, text, done: true) }
            replying = nil
            Task {
                if let transcript = await manager.takeTranscript() {
                    await scribe.reflect(on: "\(Owner.firstName): \(transcript.said)\ntilde: \(transcript.replied)")
                }
            }
        case .trouble(let text):
            trouble = text
            signal.yield(.trouble(text))
            if let replying, let i = thread.firstIndex(where: { $0.id == replying }), thread[i].text.isEmpty {
                thread[i].text = text
                thread[i].trouble = true
                thread[i].streaming = false
                self.replying = nil
                saveThread()
            } else {
                append(Message(from: .tilde, text: text, trouble: true))
            }
        }
    }

    func noteWritten(_ written: [Memory.Written]) {
        signal.yield(.noted(written))
        written.forEach { appendNoted($0.fact) }
    }

    /// Shows a fact tilde filed under the reply being written, or else what it said last.
    func appendNoted(_ fact: String) {
        let reply = replying.flatMap { id in thread.firstIndex { $0.id == id } }
        guard let i = reply ?? thread.lastIndex(where: { $0.from == .tilde }), !thread[i].noted.contains(fact) else { return }
        thread[i].noted.append(fact)
        saveThread()
    }

    // MARK: Thread

    /// Adds a message, starting a new thread when the day has turned.
    func append(_ message: Message) {
        if !Calendar.current.isDateInToday(threadDay) {
            thread = []
            threadDay = .now
            reconcileQuestions()
        }
        thread.append(message)
        saveThread()
    }

    /// Keeps the thread honest about open questions: the ones still waiting are in it (carried
    /// over from an earlier day if need be), and the ones a restart dropped no longer look open.
    func reconcileQuestions() {
        for i in thread.indices where thread[i].attentionID.map({ id in !attention.contains { $0.id == id } }) ?? false {
            thread[i].attentionID = nil
        }
        let shown = Set(thread.compactMap(\.attentionID))
        let carried = attention.filter { !shown.contains($0.id) }.map { item in
            Message(from: .tilde, text: item.question, at: item.createdAt, jobs: item.jobID.map { [$0] } ?? [], attentionID: item.id)
        }
        thread.insert(contentsOf: carried, at: 0)
    }

    private func saveThread() { threads.save(thread) }

    /// Streams a reply into its message. Quiet taps (welcome-backs) only appear if tilde says something.
    private func writeReply(_ tap: String, _ text: String, done: Bool) {
        if quietTaps.contains(tap), thread.firstIndex(where: { $0.id == tap }) == nil {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if done { quietTaps.remove(tap) }
                return
            }
            append(Message(id: tap, from: .tilde, text: "", streaming: true))
        }
        guard let i = thread.firstIndex(where: { $0.id == tap }) else { return }
        if !text.isEmpty { thread[i].text = text }
        if done {
            thread[i].streaming = false
            if thread[i].text.isEmpty { thread[i].text = thread[i].jobs.isEmpty ? "Done." : "On it." }
            quietTaps.remove(tap)
            saveThread()
        }
    }

    /// Ties a job to the reply being written, so it shows as a chip under tilde's words.
    func mention(_ jobID: String) {
        guard let replying, let i = thread.firstIndex(where: { $0.id == replying }), !thread[i].jobs.contains(jobID) else { return }
        thread[i].jobs.append(jobID)
    }
}
