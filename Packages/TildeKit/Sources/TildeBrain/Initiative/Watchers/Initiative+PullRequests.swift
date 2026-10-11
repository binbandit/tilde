import Foundation
import TildeWork

/// Pull requests: what changed since the last poll, and what's pending where the owner just looked.
extension Initiative {
    /// Takes in a fresh read of GitHub and returns what changed since the last one.
    func saw(_ fresh: [PullRequestWatch.Pull], at now: Date = .now) -> [Notice] {
        polledAt = now
        pulls = fresh
        return transitions(fresh, now: now)
    }

    /// How long failing checks or a conflict must last before they're worth a word: in a busy repo
    /// (a merge queue, a rebase in flight) most clear up on their own within minutes.
    static let hold: TimeInterval = 15 * 60

    /// Whether a trouble has lasted the hold, noting when it started and forgetting it once it's gone.
    private func lasted(_ key: String, _ active: Bool, now: Date) -> Bool {
        guard active else {
            seen.since[key] = nil
            return false
        }
        let since = seen.since[key] ?? now
        seen.since[key] = since
        return now.timeIntervalSince(since) >= Self.hold
    }

    /// PR state changes worth a word. Open PRs change state; merged ones only matter if main broke after.
    func transitions(_ pulls: [PullRequestWatch.Pull], now: Date = .now) -> [Notice] {
        var found: [Notice] = []
        for pull in pulls where !pull.merged {
            let subject = pull.id
            let previous = seen.states[subject].map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) } ?? []
            let state = [pull.checks ?? "", pull.review ?? "", pull.mergeable ?? "", "\(pull.conversation)"]
            seen.states[subject] = state.joined(separator: "|")
            guard previous.count == 4 else { continue }
            let local = localPath(for: pull)

            // Checks broken (not just waiting on an approval) for a while: one word per head commit.
            if pull.isMine, lasted("\(subject):checks", pull.checksFailing, now: now) {
                let failing = pull.failingChecks.filter { !PullRequestWatch.Pull.isGate($0) }.prefix(4).joined(separator: ", ")
                found.append(Notice(
                    key: "\(subject):checks:\(pull.headOID)", subject: subject, urgency: .soon,
                    summary: "Checks failed on \(pull.label) \"\(pull.title)\"\(failing.isEmpty ? "" : ": \(failing)").",
                    url: pull.url, project: local, suggestion: "fix the failing checks on branch \(pull.branch)"))
            }
            if pull.isMine, pull.review == "CHANGES_REQUESTED", previous[1] != "CHANGES_REQUESTED" {
                found.append(Notice(
                    key: "\(subject):changes:\(pull.conversation)", subject: subject, urgency: .soon,
                    summary: "Changes were requested on \(pull.label) \"\(pull.title)\"\(pull.lastComment.map { ": \($0)" } ?? ".")",
                    url: pull.url, project: local, suggestion: "address the review feedback on branch \(pull.branch)"))
            } else if Int(previous[3]).map({ pull.conversation > $0 }) ?? false, let comment = pull.lastComment, !pull.lastCommentIsMine,
                !pull.lastCommentIsBot
            {
                found.append(Notice(
                    key: "\(subject):comment:\(pull.conversation)", subject: subject, urgency: .soon,
                    summary: "New comment on \(pull.label) \"\(pull.title)\": \(comment)", url: pull.url, project: local,
                    suggestion: pull.isMine ? "reply to or address the comment" : nil))
            }
            if pull.isMine, lasted("\(subject):conflict", pull.mergeable == "CONFLICTING", now: now) {
                found.append(Notice(
                    key: "\(subject):conflict:\(pull.headOID)", subject: subject, urgency: .soon,
                    summary: "\(pull.label) \"\(pull.title)\" now conflicts with its base branch.", url: pull.url, project: local,
                    suggestion: "rebase \(pull.branch) onto its base and resolve the conflicts"))
            }
            if pull.isMine, pull.review == "APPROVED", pull.checks == "SUCCESS", pull.mergeable == "MERGEABLE",
                !(previous[1] == "APPROVED" && previous[0] == "SUCCESS")
            {
                found.append(Notice(
                    key: "\(subject):ready:\(pull.headOID)", subject: subject, urgency: .soon,
                    summary: "\(pull.label) \"\(pull.title)\" is approved and green.", url: pull.url, project: local,
                    suggestion: "merge it"))
            }
        }
        for pull in pulls where pull.reviewRequested {
            // Dependency bumps and other bot PRs can wait until you look.
            found.append(Notice(
                key: "\(pull.id):review-requested", subject: pull.id, urgency: pull.authorIsBot ? .fyi : .soon,
                summary: "\(pull.author) asked for your review on \(pull.label) \"\(pull.title)\".", url: pull.url,
                project: localPath(for: pull), suggestion: "summarise the change and anything that looks risky"))
        }
        for broken in PullRequestWatch.brokenMains(pulls) {
            found.append(Notice(
                key: "main:\(broken.repo):\(broken.oid)", subject: "main:\(broken.repo)", urgency: .now,
                summary: "\(broken.repo) \(broken.branch) is failing after your merge of \"\(broken.title)\".", url: broken.url,
                project: nil, suggestion: "find out why and propose a fix"))
        }
        return found
    }

    /// Context nudges: you just opened a repo that has something pending.
    func nudges(_ pulls: [PullRequestWatch.Pull], focusedRepo: String?) -> [Notice] {
        guard let focusedRepo else { return [] }
        let name = (focusedRepo as NSString).lastPathComponent.lowercased()
        return pulls.filter { $0.isMine && !$0.merged && $0.repoName.lowercased() == name }.compactMap { pull in
            var pending: [String] = []
            if pull.checks == "FAILURE" { pending.append("failing checks") }
            if pull.mergeable == "CONFLICTING" { pending.append("a merge conflict") }
            if pull.review == "CHANGES_REQUESTED" { pending.append("requested changes") }
            guard !pending.isEmpty else { return nil }
            let day = Date.now.day
            return Notice(
                key: "\(pull.id):nudge:\(day)", subject: pull.id, urgency: .soon,
                summary: "You're in \(pull.repoName); \(pull.label) \"\(pull.title)\" has \(pending.joined(separator: " and ")).",
                url: pull.url, project: focusedRepo, suggestion: "sort it out on branch \(pull.branch)")
        }
    }

    /// The owner's checkout of the PR's repo: found by its remote, not its folder name (several folders can
    /// share a name, and the wrong one sends work to the wrong repo).
    private func localPath(for pull: PullRequestWatch.Pull) -> String? {
        checkouts[pull.repo]
    }
}
