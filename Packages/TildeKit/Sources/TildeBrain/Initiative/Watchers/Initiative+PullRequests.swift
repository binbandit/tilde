import Foundation
import TildeWork

/// Pull requests: what changed since the last poll, and what's pending where the owner just looked.
extension Initiative {
    /// Takes in a fresh read of GitHub and returns what changed since the last one.
    func saw(_ fresh: [PullRequestWatch.Pull], at now: Date = .now) -> [Notice] {
        polledAt = now
        pulls = fresh
        return transitions(fresh)
    }

    /// PR state changes worth a word. Open PRs change state; merged ones only matter if main broke after.
    func transitions(_ pulls: [PullRequestWatch.Pull]) -> [Notice] {
        var found: [Notice] = []
        for pull in pulls where !pull.merged {
            let subject = pull.id
            let previous = seen.states[subject].map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) } ?? []
            let state = [pull.checks ?? "", pull.review ?? "", pull.mergeable ?? "", "\(pull.conversation)"]
            seen.states[subject] = state.joined(separator: "|")
            guard previous.count == 4 else { continue }
            let local = localPath(for: pull)

            if pull.isMine, pull.checks == "FAILURE", previous[0] != "FAILURE" {
                let failing = pull.failingChecks.prefix(4).joined(separator: ", ")
                found.append(Notice(
                    key: "\(subject):checks:\(pull.headOID)", subject: subject, urgency: .soon,
                    summary: "Checks failed on \(pull.label) \"\(pull.title)\"\(failing.isEmpty ? "" : ": \(failing)").",
                    url: pull.url, project: local, suggestion: "fix the failing checks on branch \(pull.branch)"))
            }
            if pull.isMine, pull.review == "CHANGES_REQUESTED", previous[1] != "CHANGES_REQUESTED" {
                found.append(Notice(
                    key: "\(subject):changes:\(pull.conversation)", subject: subject, urgency: .now,
                    summary: "Changes were requested on \(pull.label) \"\(pull.title)\"\(pull.lastComment.map { ": \($0)" } ?? ".")",
                    url: pull.url, project: local, suggestion: "address the review feedback on branch \(pull.branch)"))
            } else if Int(previous[3]).map({ pull.conversation > $0 }) ?? false, let comment = pull.lastComment, !pull.lastCommentIsMine {
                found.append(Notice(
                    key: "\(subject):comment:\(pull.conversation)", subject: subject, urgency: .soon,
                    summary: "New comment on \(pull.label) \"\(pull.title)\": \(comment)", url: pull.url, project: local,
                    suggestion: pull.isMine ? "reply to or address the comment" : nil))
            }
            if pull.isMine, pull.mergeable == "CONFLICTING", previous[2] != "CONFLICTING" {
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
            let day = Date.now.formatted(.iso8601.year().month().day())
            return Notice(
                key: "\(pull.id):nudge:\(day)", subject: pull.id, urgency: .soon,
                summary: "You're in \(pull.repoName); \(pull.label) \"\(pull.title)\" has \(pending.joined(separator: " and ")).",
                url: pull.url, project: focusedRepo, suggestion: "sort it out on branch \(pull.branch)")
        }
    }

    private func localPath(for pull: PullRequestWatch.Pull) -> String? {
        let fm = FileManager.default
        for root in ProjectIndex.defaultRoots {
            guard let walker = fm.enumerator(atPath: root) else { continue }
            while let entry = walker.nextObject() as? String {
                if walker.level > 3 { walker.skipDescendants(); continue }
                if (entry as NSString).lastPathComponent.lowercased() == pull.repoName.lowercased(),
                    fm.fileExists(atPath: "\(root)/\(entry)/.git")
                {
                    return "\(root)/\(entry)"
                }
            }
        }
        return nil
    }
}
