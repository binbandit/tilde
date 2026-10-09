import Foundation
import TildeKit

/// A plausible day with tilde: a conversation, a crew in every state, and a diff.
@MainActor
enum Fixtures {
    static func make() -> AppModel.Fixture {
        let home = NSHomeDirectory()
        func job(_ id: String, _ title: String, _ project: String, _ harness: Harness, _ phase: Job.Phase, _ ticker: String, minutes: Double) -> Job {
            let slug = title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
            var job = Job(
                id: id, title: title, brief: "", projectName: project, repoPath: "\(home)/Developer/frontend/\(project)",
                workdir: "\(home)/.tilde/worktrees/\(project)/\(slug)", harness: harness, isolation: .worktree)
            job.phase = phase
            job.ticker = ticker
            job.branch = "tilde/\(slug)"
            job.createdAt = .now.addingTimeInterval(-minutes * 60)
            job.updatedAt = .now
            job.sessionID = "6f1c2a9e-0b7d-4f53-9a51-2d3e4f5a6b7c"
            return job
        }
        var ready = job("j-r4k2", "Pricing page copy", "paradise", .claude, .ready, "Ready for review", minutes: 23)
        ready.summary = "Rewrote the pricing tiers' copy to match the new plans and tightened the FAQ. `pnpm build` and the page's tests pass."
        ready.diff = DiffStat(files: 3, insertions: 48, deletions: 19)
        let jobs = [
            job("j-n8v3", "Navigation bar", "paradise", .claude, .working, "Running xcodebuild for the preview", minutes: 6),
            job("j-q2m7", "Cart tests", "paradise", .codex, .needsYou, "Waiting on you", minutes: 11),
            ready,
            job("j-z5x9", "Fix flaky login spec", "sayso-web", .codex, .deciding, "tilde is deciding", minutes: 2),
        ]
        let ask = Attention(
            id: "a-7h3d", jobID: "j-q2m7", question: "Mock Stripe in the cart tests, or hit the test-mode API?",
            options: ["Mock it", "Test-mode API"], recommended: 0,
            detail: "The suite runs in CI on every push; network calls would slow it and can flake.", requestID: "r-1", isApproval: false)
        let offer = Attention(
            id: "a-9k2f", jobID: nil, question: "oh-fx#513 failed lint and now conflicts with main. Want me to sort it out?",
            options: ["Fix it", "Not now"], recommended: 0, detail: nil, requestID: nil, isApproval: false)
        let ago = { (minutes: Double) in Date.now.addingTimeInterval(-minutes * 60) }
        let thread = [
            Message(from: .you, text: "create the navigation bar in the paradise app", at: ago(26), pointing: "~/Developer/frontend/paradise · Ghostty"),
            Message(from: .tilde, text: "On it. Claude Code is building it on its own branch, sticky like your other headers.", at: ago(26), jobs: ["j-n8v3"]),
            Message(from: .you, text: "and get codex to cover the cart with tests", at: ago(12)),
            Message(from: .tilde, text: "Codex has the cart tests.", at: ago(12), jobs: ["j-q2m7"]),
            Message(
                from: .tilde, text: "Codex wants to know whether to mock Stripe in the cart tests or hit the test-mode API. I'd mock it: CI runs on every push.",
                at: ago(9), jobs: ["j-q2m7"], attentionID: "a-7h3d"),
            Message(
                from: .tilde, text: "The pricing copy is ready. Tiers rewritten, FAQ tightened, and the build and tests pass.", at: ago(4),
                jobs: ["j-r4k2"], noted: ["Wants pricing copy short and plain."]),
            Message(from: .tilde, text: offer.question, at: ago(1), attentionID: offer.id),
        ]
        return AppModel.Fixture(thread: thread, jobs: jobs, attention: [ask, offer], diff: sampleDiff)
    }

    static let sampleDiff = """
        diff --git a/app/pricing/page.tsx b/app/pricing/page.tsx
        index 3b1f2a0..9c4e1d2 100644
        --- a/app/pricing/page.tsx
        +++ b/app/pricing/page.tsx
        @@ -12,9 +12,11 @@ export default function Pricing() {
           return (
             <main className="mx-auto max-w-5xl px-6">
        -      <h1 className="text-3xl font-semibold">Plans for every team</h1>
        +      <h1 className="text-3xl font-semibold tracking-tight">Simple pricing</h1>
        +      <p className="mt-2 text-muted-foreground">Start free. Upgrade when your team does.</p>
               <Tiers>
        -        <Tier name="Starter" price="$9" />
        +        <Tier name="Free" price="$0" note="For side projects" />
        +        <Tier name="Team" price="$12" note="Per seat, billed yearly" highlighted />
               </Tiers>
             </main>
           )
        diff --git a/app/pricing/faq.ts b/app/pricing/faq.ts
        index 51aa0d1..6e7f2b9 100644
        --- a/app/pricing/faq.ts
        +++ b/app/pricing/faq.ts
        @@ -1,6 +1,6 @@
         export const faq = [
        -  { q: "Can I cancel anytime?", a: "Yes, you can cancel your subscription at any time from settings." },
        +  { q: "Can I cancel anytime?", a: "Yes. Cancel from Settings and you keep access until the period ends." },
           { q: "Do you offer refunds?", a: "Within 14 days, no questions asked." },
         ]
        """
}
