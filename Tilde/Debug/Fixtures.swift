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
        ready.brief = "Rewrite the pricing page copy to match the new plans."
        ready.summary = "Rewrote the pricing tiers' copy to match the new plans and tightened the FAQ. `pnpm build` and the page's tests pass."
        ready.diff = DiffStat(files: 3, insertions: 48, deletions: 19)
        let jobs = [
            job("j-n8v3", "Navigation bar", "paradise", .claude, .working, "Checking the header in the browser", minutes: 6),
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
        return AppModel.Fixture(thread: thread, jobs: jobs, attention: [ask, offer], transcripts: transcripts(ago), diff: sampleDiff)
    }

    /// What each agent was told, said, did and asked.
    private static func transcripts(_ ago: (Double) -> Date) -> [String: [JobEntry]] {
        func e(_ minutes: Double, _ from: JobEntry.Speaker, _ kind: JobEntry.Kind, _ text: String) -> JobEntry {
            JobEntry(at: ago(minutes), from: from, kind: kind, text: text)
        }
        return [
            "j-r4k2": [
                e(23, .tilde, .message, """
                    Rewrite the pricing page copy in paradise to match the new plans: Free ($0, side projects) and Team ($12 per seat, \
                    billed yearly). Keep it short and plain, the way Brayden writes. Tighten the FAQ answers while you're there. The page \
                    lives in app/pricing. Run `pnpm build` and the page's tests before you finish, and don't push.
                    """),
                e(23, .agent, .message, "I'll start by reading the current pricing page and FAQ to see what's there."),
                e(22, .agent, .step, "Reading app/pricing/page.tsx"),
                e(22, .agent, .step, "Reading app/pricing/faq.ts"),
                e(22, .agent, .step, "Searching for Tier usages"),
                e(21, .agent, .message, "The tiers still say Starter at $9. I'll replace them with Free and Team, add a one-line subtitle, and trim the cancel answer."),
                e(20, .agent, .step, "Editing app/pricing/page.tsx"),
                e(19, .agent, .step, "Editing app/pricing/faq.ts"),
                e(18, .agent, .step, "Running pnpm build"),
                e(16, .agent, .step, "Running pnpm test app/pricing"),
                e(15, .agent, .message, "Done. Both tiers are rewritten, the FAQ is tighter, and `pnpm build` and the pricing tests pass."),
                e(15, .agent, .turnEnded, "3 files +48 −19"),
                e(14, .tilde, .message, "Highlight the Team tier, it's the one most people should pick."),
                e(13, .agent, .step, "Editing app/pricing/page.tsx"),
                e(12, .agent, .step, "Running pnpm test app/pricing"),
                e(11, .agent, .message, "Team is highlighted now. Tests still pass."),
                e(11, .agent, .turnEnded, "3 files +48 −19"),
                e(10, .tilde, .event, "Ready for review: rewrote the pricing tiers' copy and tightened the FAQ."),
            ],
            "j-q2m7": [
                e(11, .tilde, .message, "Cover paradise's cart with tests: adding, removing and changing quantities, totals with tax, and checkout handoff. Use the existing Vitest setup."),
                e(11, .agent, .step, "Reading src/cart/store.ts"),
                e(10, .agent, .step, "Reading src/cart/checkout.ts"),
                e(10, .agent, .step, "Listing src/cart/__tests__"),
                e(9, .agent, .message, "Checkout calls Stripe directly. Before I write those tests: should I mock Stripe, or call the test-mode API?"),
                e(9, .agent, .request, "Mock Stripe in the cart tests, or hit the test-mode API?"),
                e(9, .tilde, .request, "Mock Stripe in the cart tests, or hit the test-mode API?"),
            ],
            "j-n8v3": [
                e(6, .tilde, .message, "Create a navigation bar in paradise: sticky, like the headers in Brayden's other apps, with Home, Pricing and Account."),
                e(6, .agent, .step, "Reading app/layout.tsx"),
                e(5, .agent, .step, "Writing components/nav-bar.tsx"),
                e(4, .agent, .request, "Bash: npm install @radix-ui/react-navigation-menu"),
                e(4, .tilde, .decision, "allowed"),
                e(3, .agent, .step, "Editing app/layout.tsx"),
                e(1, .agent, .step, "Checking the header in the browser"),
            ],
        ]
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
