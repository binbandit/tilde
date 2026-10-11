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
        var said = Message(from: .you, text: text, pointing: context.pointing, jobs: context.jobID.map { [$0] } ?? [])
        said.delivery = .sent
        unread[id] = (said.id, context)
        append(said)
        append(Message(id: id, from: .tilde, text: "", streaming: true))
        replying = id
        let attributes = ([("at", Date.now.formatted(date: .omitted, time: .shortened))] + context.attributes)
            .map { "\($0.0)=\"\(Self.escape($0.1))\"" }.joined(separator: " ")
        var body = text
        if let selected = context.text, !selected.isEmpty {
            body += "\n<selection>\n\(selected.clipped(to: 4_000, keepLines: true))\n</selection>"
        }
        Task {
            // Questions about PRs are common enough that what tilde last saw rides along, so most need no tool.
            // Only what it already has: the message never waits on GitHub.
            if initiativeEnabled, text.contains(/(?i)\b(PRs?|pull requests?|reviews?|CI|checks)\b/) {
                let watching = await initiative.watching()
                if !watching.isEmpty { body += "\n<pull_requests>\n\(watching)\n</pull_requests>" }
            }
            await manager.post(.init(
                "<tap \(attributes)>\n\(body)\n</tap>", tap: id,
                paths: [context.repo, context.cwd, context.document].compactMap { $0 },
                jobs: context.jobID.map { [$0] } ?? []))
        }
        return id
    }

    /// Says again something that never reached tilde, with what you were pointing at then.
    public func retry(_ messageID: String) {
        guard let i = thread.firstIndex(where: { $0.id == messageID }), case .failed = thread[i].delivery else { return }
        let said = thread.remove(at: i)
        let context = unread.first { $0.value.message == messageID }
        if let context { unread[context.key] = nil }
        tap(said.text, context: context?.value.context ?? TapContext(pointing: said.pointing))
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
        if let jobID = item.jobID {
            // An answer that went to the worker sets it going again; any other is tilde's to act on.
            update(jobID) {
                guard $0.phase == .needsYou else { return }
                $0.phase = forwarded ? .working : .deciding
                if !forwarded { $0.ticker = "Acting on your answer" }
            }
        }

        let job = item.jobID.flatMap { id in jobs.first { $0.id == id } }
        if always, let job {
            Task { try? await memory.notebook.addRule("\(reply) when asked \"\(item.question)\" in \(job.projectName).") }
        }
        if let jobID = item.jobID {
            log.append(jobID, "\(Owner.firstName) answered \"\(item.question)\": \(reply)")
            if !forwarded { record(jobID, .you, .decision, "answered tilde: \(reply)") }
        }
        if let i = thread.firstIndex(where: { $0.attentionID == item.id }) { thread[i].attentionID = nil }
        // Your answer is a message like any other: tilde reads it and says what happens now. An answer
        // that went straight to an agent usually needs no word, so its reply only appears if there is one.
        let id = IDs.make("t")
        var said = Message(from: .you, text: reply + (always ? " (always)" : ""), jobs: item.jobID.map { [$0] } ?? [])
        said.delivery = .sent
        unread[id] = (said.id, TapContext(jobID: item.jobID))
        append(said)
        if forwarded {
            quietTaps.insert(id)
        } else {
            optionalReplies.insert(id)
            append(Message(id: id, from: .tilde, text: "", streaming: true))
            replying = id
        }

        let tag = "<answer to=\"\(item.id)\"\(item.jobID.map { " job=\"\($0)\"" } ?? "")\(forwarded ? " delivered-to-worker=\"yes\"" : "")>"
        Task {
            // Everything the question carried, so the answer can be acted on even by a manager thread that never saw it asked.
            let about = await initiative.subjects(of: item.id)
            let context = [item.detail.map { "Detail: \($0)" }, about.isEmpty ? nil : "About: \(about.joined(separator: ", "))"]
            await manager.post(.init(
                "\(tag)\nQuestion: \(item.question)\n" + context.compactMap { $0 }.map { "\($0)\n" }.joined()
                    + "Answer: \(reply)\(always ? "\n(They asked to always do this.)" : "")\n</answer>",
                tap: id, jobs: item.jobID.map { [$0] } ?? []))
        }
        answerTaps.insert(id)
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
            if let last = gather(taps) { writeReply(last, text, done: false) }
        case .read(let taps):
            for tap in taps {
                guard let said = unread.removeValue(forKey: tap)?.message, let i = thread.firstIndex(where: { $0.id == said }) else { continue }
                thread[i].delivery = .read(.now)
            }
            _ = gather(taps)
            saveThread()
        case .activity(let taps, let text):
            if let last = taps.last, let i = thread.firstIndex(where: { $0.id == last }), thread[i].streaming { thread[i].activity = text }
        case .replyDone(let taps, let text):
            if let last = gather(taps) { writeReply(last, text, done: true) }
            replying = nil
            // Answers were already reflected on, with the question's options.
            let answers = taps.allSatisfy(answerTaps.contains)
            answerTaps.subtract(taps)
            Task {
                if let transcript = await manager.takeTranscript(), !answers {
                    await scribe.reflect(on: "\(Owner.firstName): \(transcript.said)\ntilde: \(transcript.replied)")
                }
            }
        case .trouble(let text):
            trouble = text
            signal.yield(.trouble(text))
            // What you said never reached the model: it says so under your words, with a way to try again.
            if let replying, let said = unread[replying]?.message, let i = thread.firstIndex(where: { $0.id == said }),
                let reply = thread.firstIndex(where: { $0.id == replying }), thread[reply].text.isEmpty
            {
                thread[i].delivery = .failed(text)
                thread.remove(at: reply)
                self.replying = nil
                saveThread()
                return
            }
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

    /// Saved under the day it belongs to, even when that day has just ended.
    private func saveThread() { threads.save(thread, day: threadDay) }

    /// Streams a reply into its message. Quiet taps (welcome-backs) only appear if tilde says something.
    /// One reply answers everything said in a turn, under the last of it: earlier replies still
    /// waiting to be written go, and any already under way stop there. Returns the one to write to.
    private func gather(_ taps: [String]) -> String? {
        for tap in taps.dropLast() {
            optionalReplies.remove(tap)
            guard let i = thread.firstIndex(where: { $0.id == tap }), thread[i].streaming else { continue }
            if thread[i].text.isEmpty {
                thread.remove(at: i)
            } else {
                thread[i].streaming = false
                thread[i].activity = nil
            }
        }
        if let last = taps.last, replying.map(taps.contains) ?? false { replying = last }
        return taps.last
    }

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
            thread[i].activity = nil
            if thread[i].text.isEmpty {
                if optionalReplies.contains(tap) {
                    thread.remove(at: i)
                } else {
                    thread[i].text = thread[i].jobs.isEmpty ? "Done." : "On it."
                }
            }
            if let reply = thread.first(where: { $0.id == tap }), !reply.trouble { signal.yield(.replied(reply.text)) }
            quietTaps.remove(tap)
            optionalReplies.remove(tap)
            saveThread()
        }
    }

    /// Ties a job to the reply being written, so it shows as a chip under tilde's words.
    func mention(_ jobID: String) {
        guard let replying, let i = thread.firstIndex(where: { $0.id == replying }), !thread[i].jobs.contains(jobID) else { return }
        thread[i].jobs.append(jobID)
    }
}
