import Foundation

/// Questions tilde asked about PRs remember which PRs they name and what was wrong with them,
/// so they can withdraw themselves once nothing is left to decide: the PR merged, closed, or recovered.
extension Initiative {
    struct Concern: Codable, Sendable, Hashable {
        /// The PR, as `owner/repo#12`.
        var subject: String
        var label: String
        /// What was wrong with it when tilde asked.
        var troubles: Set<PullRequestWatch.Pull.Trouble>

        /// Why the question about this PR no longer needs an answer, if it doesn't.
        func settled(by pull: PullRequestWatch.Pull) -> String? {
            if pull.merged { return "\(label) merged" }
            if pull.closed { return "\(label) was closed" }
            guard !troubles.isEmpty, troubles.allSatisfy(pull.isPast) else { return nil }
            return switch troubles.count == 1 ? troubles.first : nil {
            case .checks: "checks pass on \(label)"
            case .conflict: "\(label) no longer conflicts"
            case .changes: "the review on \(label) is settled"
            case nil: "nothing is left to fix on \(label)"
            }
        }
    }

    /// Ties one of tilde's own questions to the PRs it names: "oh-fx#713" (and a bare "#714" after
    /// it), or a bare "#713" when only one watched PR has that number. Questions for a job or a
    /// worker wait for an answer.
    func link(_ item: Attention) {
        guard item.jobID == nil, item.requestID == nil else { return }
        let text = "\(item.question) \(item.detail ?? "")"
        var concerns: [Concern] = []
        var repoName: Substring?
        for match in text.matches(of: /([\w.-]+)?#(\d+)\b/) {
            guard let number = Int(match.2) else { continue }
            repoName = match.1 ?? repoName
            let inRepo = { (pull: PullRequestWatch.Pull) in repoName.map { pull.repoName.caseInsensitiveCompare($0) == .orderedSame } ?? true }
            let watched = pulls.filter { $0.number == number && inRepo($0) }
            var concern: Concern?
            if watched.count == 1, let pull = watched.first {
                concern = Concern(subject: pull.id, label: pull.label, troubles: pull.troubles)
            } else if watched.isEmpty, repoName != nil, let repo = pulls.first(where: inRepo) {
                // Off the watched lists (merged a while back, say): known by its repo, looked up when it's time.
                concern = Concern(subject: "\(repo.repo)#\(number)", label: "\(repo.repoName)#\(number)", troubles: [])
            }
            if let concern, !concerns.contains(where: { $0.subject == concern.subject }) { concerns.append(concern) }
        }
        guard !concerns.isEmpty else { return }
        seen.asks[item.id] = concerns
        persist()
    }

    /// The PRs a question is about, as `owner/repo#12`, so its answer can say exactly which.
    func subjects(of attentionID: String) -> [String] {
        seen.asks[attentionID]?.map(\.subject) ?? []
    }

    /// Open questions that no longer need an answer, and why (attention id -> "oh-fx#713 merged").
    /// Looks once per GitHub poll; PRs that fell off the watched lists are looked up one by one.
    func moot(_ open: [Attention]) async -> [String: String] {
        seen.asks = seen.asks.filter { ask in open.contains { $0.id == ask.key } }
        guard polledAt > mootCheckedAt else { return [:] }
        mootCheckedAt = polledAt
        // Questions asked before tilde knew their PRs get tied to them now.
        for item in open where seen.asks[item.id] == nil { link(item) }
        var moot: [String: String] = [:]
        var lookedUp: [String: PullRequestWatch.Pull] = [:]
        for (id, concerns) in seen.asks {
            var reasons: [String] = []
            for concern in concerns {
                if lookedUp[concern.subject] == nil {
                    if let watched = pulls.first(where: { $0.id == concern.subject }) {
                        lookedUp[concern.subject] = watched
                    } else {
                        lookedUp[concern.subject] = await PullRequestWatch.fetch(concern.subject)
                    }
                }
                guard let pull = lookedUp[concern.subject], let reason = concern.settled(by: pull) else { break }
                reasons.append(reason)
            }
            if reasons.count == concerns.count { moot[id] = reasons.joined(separator: ", ") }
        }
        seen.asks = seen.asks.filter { moot[$0.key] == nil }
        persist()
        return moot
    }
}
