import Foundation
import TildeKit

// Drives tilde's brain headless against a real repo: one utterance in, then
// prints what the manager says, asks and does until the jobs settle.
//
//   TILDE_HOME=/tmp/tilde-smoke tilde-smoke <repo> "<what to say>" [--land] [--answer <text>]

let args = CommandLine.arguments

// `tilde-smoke --dream`: consolidate today into the notebook and print the result.
// `tilde-smoke --recall "<query>" [--path <dir>]`: print the briefing a manager turn would get.
if let i = args.firstIndex(of: "--recall") {
    let memory = try Memory(home: .default, projects: ProjectIndex(roots: ProjectIndex.defaultRoots))
    try await memory.prepare()
    _ = await memory.briefing(for: "warm-up")  // the core rides along once; show only what's relevant
    let paths = args.firstIndex(of: "--path").map { [args[$0 + 1]] } ?? []
    print(await memory.briefing(for: args[i + 1], paths: paths) ?? "(nothing)")
    exit(0)
}

// `tilde-smoke --initiative [repo]`: what tilde would notice right now (read-only).
if args.contains("--initiative") {
    let initiative = Initiative(home: .default, projects: ProjectIndex(roots: ProjectIndex.defaultRoots))
    let focused = args.firstIndex(of: "--initiative").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    _ = await initiative.look(jobs: [], focusedRepo: focused)  // baseline
    print("waiting agents:")
    for notice in await initiative.look(jobs: [], focusedRepo: focused) { print(" -", notice.urgency, notice.summary) }
    exit(0)
}

if args.contains("--introduce") {
    var config = Conductor.Config()
    if let roots = args.firstIndex(of: "--roots").map({ args[$0 + 1] }) { config.projectRoots = roots.split(separator: ",").map(String.init) }
    let conductor = try Conductor(config: config)
    try await conductor.start()
    let started = Date()
    await conductor.introduce()
    print(String(format: "introduced in %.0fs", Date().timeIntervalSince(started)))
    exit(0)
}

if args.contains("--dream") {
    let conductor = try Conductor()
    try await conductor.start()
    let started = Date()
    await conductor.dream(about: .now)
    print(String(format: "dreamt in %.0fs", Date().timeIntervalSince(started)))
    exit(0)
}

guard args.count >= 3 else {
    print("usage: tilde-smoke <repo> \"<utterance>\" [--land] [--answer <text>]")
    exit(2)
}
let repo = (args[1] as NSString).standardizingPath
let utterance = args[2]
let land = args.contains("--land")
let scripted = args.firstIndex(of: "--answer").map { args[$0 + 1] }

var config = Conductor.Config()
config.projectRoots = [(repo as NSString).deletingLastPathComponent]
let conductor = try Conductor(config: config)
try await conductor.start()
let started = Date()
func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }

Task { @MainActor in
    for await signal in conductor.signals {
        switch signal {
        case .asked(let item):
            let recommended = item.recommended.flatMap { item.options.indices.contains($0) ? item.options[$0] : nil }
            print("\(stamp()) ASK  \(item.question) \(item.options) recommended=\(recommended ?? "-") \(item.detail ?? "")")
            let reply = scripted ?? recommended ?? item.options.first ?? "yes"
            print("\(stamp()) ANSWER \(reply)")
            conductor.answer(item.id, with: reply)
        case .said(let text, let job): print("\(stamp()) SAY  [\(job ?? "-")] \(text)")
        case .noted(let written): written.forEach { print("\(stamp()) NOTED \($0.path): \($0.fact)\($0.replaced.map { " (replaced: \($0))" } ?? "")") }
        case .jobChanged(let job): print("\(stamp()) JOB  \(job.id) \(job.phase.rawValue): \(job.ticker)")
        case .trouble(let text): print("\(stamp()) TROUBLE \(text)")
        case .resolved: break
        }
    }
}

conductor.tap(utterance, context: TapContext(app: "Ghostty", windowTitle: (repo as NSString).lastPathComponent, cwd: repo, repo: repo))

var lastCaption = ""
var settledAt: Date?
while Date().timeIntervalSince(started) < 900 {
    try await Task.sleep(for: .milliseconds(500))
    if let caption = conductor.caption, caption.done, caption.text != lastCaption {
        lastCaption = caption.text
        print("\(stamp()) CAPTION \(caption.text)")
    }
    let open = conductor.jobs.contains { $0.phase.isActive }
    let settled = conductor.caption?.done == true && !open && conductor.attention.isEmpty
    if settled {
        settledAt = settledAt ?? Date()
        // Give the manager a moment to react to the last event before calling it.
        if Date().timeIntervalSince(settledAt!) > 8 { break }
    } else {
        settledAt = nil
    }
}

for job in conductor.jobs {
    print("\(stamp()) RESULT \(job.id) \(job.phase.rawValue) \(job.diff?.label ?? "") :: \(job.summary ?? "")")
    if land, job.phase == .ready {
        do {
            try await conductor.land(job.id)
            print("\(stamp()) LANDED \(job.id)")
        } catch {
            print("\(stamp()) LAND FAILED \(error)")
        }
    }
}
try await Task.sleep(for: .seconds(20))  // let the scribe finish
exit(0)
