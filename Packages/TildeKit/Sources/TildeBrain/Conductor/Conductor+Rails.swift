import Foundation
import WorkerKit

/// Rails are the owner's to cross. The manager can deny a request on a rail, or ask the owner about it,
/// but only the owner allows one: by answering, or once and for all with "Always", which is kept in
/// tilde's state (not in the notebook, where models write) as the exact rail and project it covers.
extension Conductor {
    private var allowedURL: URL { home.state.appending(path: "allowed.json") }

    /// Owner UI only. Grants a narrow, runtime-only policy to this running job. There is no manager
    /// tool for this setting; a restart, stop, completed turn, or fresh worker revokes it.
    /// Supported requests only list this exact job folder with /bin/ls; they never expand a sandbox.
    @discardableResult
    public func setAutomaticApproval(_ enabled: Bool, for jobID: String) -> Bool {
        if !enabled {
            automaticApprovalJobs.remove(jobID)
            return true
        }
        guard let job = job(jobID), job.phase.isActive, workers[jobID] != nil else { return false }
        automaticApprovalJobs.insert(jobID)
        for pending in Array(requests.values) where pending.job == jobID {
            if automaticApprovalReason(pending.request, job: jobID) != nil {
                resolve(pending.request.id, .allow, by: .tilde)
            }
        }
        return true
    }

    public func automaticApprovalEnabled(for jobID: String) -> Bool {
        guard let job = job(jobID), job.phase.isActive, workers[jobID] != nil else { return false }
        return automaticApprovalJobs.contains(jobID)
    }

    func automaticApprovalReason(_ request: WorkerRequest, job jobID: String) -> String? {
        guard automaticApprovalEnabled(for: jobID), let job = job(jobID) else { return nil }
        return AutomaticApprovalPolicy.reason(for: request, workdir: job.workdir)
    }

    /// Nil means the owner's standing rail grant or bounded opt-in covers this permission. Missing
    /// rails are not evidence of safety: unknown requests always remain the owner's to allow.
    func approvalBlock(_ request: WorkerRequest, job jobID: String) -> String? {
        guard case .permission(_, _, let rail) = request.kind else { return "This request is a question, not a permission." }
        if rail != nil { return unallowedRail(request, job: jobID).map { "That crosses a rail (\($0))." } }
        if automaticApprovalReason(request, job: jobID) != nil { return nil }
        return "This permission is outside the owner's enabled bounded automatic approval policy."
    }

    /// Rails the owner has said always to allow, by repo (its path: folder names repeat).
    var standingAllows: [String: Set<String>] {
        get { (try? Data(contentsOf: allowedURL)).flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:] }
        set { if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: allowedURL, options: .atomic) } }
    }

    /// The rail a request crosses, if it's one the owner hasn't already allowed for good in its project.
    func unallowedRail(_ request: WorkerRequest, job jobID: String) -> String? {
        guard case .permission(_, _, let rail?) = request.kind else { return nil }
        let repo = job(jobID)?.repoPath ?? ""
        return standingAllows[repo]?.contains(rail) == true ? nil : rail
    }

    /// The owner said Always to a rail in this job's repo. One that would cover anything at all (running
    /// outside the sandbox) is allowed this once only.
    @discardableResult
    func allowAlways(_ rail: String, job jobID: String) -> Bool {
        guard let job = job(jobID), job.isolation != .scratch, !Rails.neverStanding.contains(rail) else { return false }
        standingAllows[job.repoPath, default: []].insert(rail)
        return true
    }
}
