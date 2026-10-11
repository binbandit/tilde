import Foundation
import WorkerKit

/// Rails are the owner's to cross. The manager can deny a request on a rail, or ask the owner about it,
/// but only the owner allows one: by answering, or once and for all with "Always", which is kept in
/// tilde's state (not in the notebook, where models write) as the exact rail and project it covers.
extension Conductor {
    private var allowedURL: URL { home.state.appending(path: "allowed.json") }

    /// Rails the owner has said always to allow, by project.
    var standingAllows: [String: Set<String>] {
        get { (try? Data(contentsOf: allowedURL)).flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:] }
        set { if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: allowedURL, options: .atomic) } }
    }

    /// The rail a request crosses, if it's one the owner hasn't already allowed for good in its project.
    func unallowedRail(_ request: WorkerRequest, job jobID: String) -> String? {
        guard case .permission(_, _, let rail?) = request.kind else { return nil }
        let project = job(jobID)?.projectName ?? ""
        return standingAllows[project]?.contains(rail) == true ? nil : rail
    }

    /// The owner said Always to a rail in this job's project.
    func allowAlways(_ rail: String, job jobID: String) {
        guard let project = job(jobID)?.projectName else { return }
        standingAllows[project, default: []].insert(rail)
    }
}
