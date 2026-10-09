import Foundation
import TildeMemory
import TildeSupport

/// The background review: one read-only model pass over everything tilde can see (goals, open
/// loops, the day's calendar, recent focus, what the watchers saw, the owner's connected apps)
/// that proposes at most three things worth a word. Watchers notice single changes; the review
/// connects them ("Sam commented on #12 an hour ago; your 3pm with Sam is about pricing").
///
/// It runs on any `MemoryModel` (the one-turn model contract the memory passes use);
/// `CodexReviewModel` is the real one.
enum Review {
    struct Inputs: Sendable {
        var now: Date = .now
        /// me.md and rules.md.
        var core = ""
        var goals = ""
        /// Questions waiting on the owner, work waiting to land, stale worktrees, follow-ups due soon.
        var openLoops = ""
        var schedule = ""
        var focus = ""
        /// The latest PR state, agents waiting, notices held back.
        var watchers = ""
        /// Everything tilde said today, so the review never repeats it.
        var thread = ""
    }

    static let limit = 3

    static func pass(_ inputs: Inputs, workdir: String) -> ModelPass {
        ModelPass(
            instructions: instructions(owner: Owner.firstName), prompt: prompt(inputs), workdir: workdir, outputSchema: schema)
    }

    static func prompt(_ inputs: Inputs) -> String {
        let now = inputs.now.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
        let sections = [
            ("core", inputs.core), ("goals", inputs.goals), ("open-loops", inputs.openLoops), ("schedule", inputs.schedule),
            ("focus", inputs.focus), ("watchers", inputs.watchers), ("said-today", inputs.thread),
        ]
        return "It is \(now).\n\n" + sections.map { name, body in
            "<\(name)>\n\(body.isEmpty ? "(nothing)" : body.trimmingCharacters(in: .whitespacesAndNewlines))\n</\(name)>"
        }.joined(separator: "\n\n")
    }

    static func instructions(owner: String) -> String {
        """
        You are the background review for tilde, \(owner)'s chief of staff for agent work on their Mac. Every so often \
        you look across everything tilde can see and find the few things a great executive assistant would bring up \
        right now. You never act: you only read, and you hand back at most \(limit) notices for tilde to raise.

        You get:
        - <core>: who \(owner) is and their standing rules.
        - <goals>: the standing objectives tilde is working toward, with status and next check-in.
        - <open-loops>: questions waiting on \(owner), finished work waiting to be landed, stale worktrees, \
        follow-ups due soon.
        - <schedule>: their calendar for the next hours (with attendees and notes) and reminders due.
        - <focus>: where their time went recently (apps, windows, repos).
        - <watchers>: the latest pull request state, coding agents waiting on them, and things noticed but not yet said.
        - <said-today>: everything tilde has already said to them today.
        You may also read files (the notebook is your working directory; project paths appear above) and use \
        \(owner)'s connected apps (Linear, docs, and so on) to look things up. Only reading tools will work; don't \
        try to change anything anywhere.

        What makes a good notice:
        - It connects sources instead of restating one: a PR comment and the meeting it bears on, a goal and the \
        job that stalled it, a reminder and the work it depends on. A single PR or job change on its own is already \
        handled by the watchers; only include one when you add something they can't (why it matters today).
        - It's blocked on \(owner), or time-sensitive (a meeting soon, a deadline, someone waiting).
        - It's specific and true. `summary` carries the evidence in one or two plain sentences, with names, numbers \
        and times. `suggestion` is the one next step tilde could take or propose ("draft a reply to Sam", "rebase \
        nav-bar and rerun CI"), or null.
        - `urgency`: "now" only if something is broken or someone is blocked on \(owner) right now; "soon" for the \
        next natural break; "fyi" for when they next look.
        - `key`: a short, stable slug for the underlying thing (the same thing gets the same key every time), e.g. \
        "paradise-checkout-pricing-call". `url`: a link to it, if there is one. `project`: the absolute path of the \
        local repo it concerns, if any.

        Never:
        - Repeat or rephrase anything in <said-today>, or relay progress, or tell \(owner) what they just did.
        - Guess. If the evidence is thin, leave it out.
        - Pad. Most of the time the right answer is no notices at all: return an empty list.
        """
    }

    static let schema: JSON = [
        "type": "object",
        "additionalProperties": false,
        "required": ["notices"],
        "properties": [
            "notices": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["key", "urgency", "summary", "suggestion", "url", "project"],
                    "properties": [
                        "key": ["type": "string"],
                        "urgency": ["type": "string", "enum": ["now", "soon", "fyi"]],
                        "summary": ["type": "string"],
                        "suggestion": ["type": ["string", "null"]],
                        "url": ["type": ["string", "null"]],
                        "project": ["type": ["string", "null"]],
                    ],
                ],
            ],
        ],
    ]

    private struct Reply: Decodable {
        struct Found: Decodable {
            var key: String
            var urgency: Notice.Urgency
            var summary: String
            var suggestion: String?
            var url: String?
            var project: String?
        }

        var notices: [Found]
    }

    /// The model's JSON as notices: at most `limit`, keyed under `review:`, and about the same
    /// subject as the watchers' notices when it's a pull request they know (so cooldowns are shared).
    static func notices(from text: String?) -> [Notice] {
        guard let data = text?.data(using: .utf8), let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return [] }
        return reply.notices.compactMap { found -> Notice? in
            let summary = found.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = IDs.slug(found.key.isEmpty ? summary : found.key, limit: 48)
            guard !summary.isEmpty else { return nil }
            let url = found.url.flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") ? $0 : nil }
            let project = found.project.map { ($0 as NSString).expandingTildeInPath }.flatMap { $0.hasPrefix("/") ? $0 : nil }
            return Notice(
                key: "review:\(key)", subject: url.flatMap(pullRequest) ?? "review:\(key)", urgency: found.urgency,
                summary: summary, url: url, project: project,
                suggestion: found.suggestion.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
        }
        .prefix(limit).map { $0 }
    }

    /// `https://github.com/owner/repo/pull/12` is the watchers' `owner/repo#12`.
    static func pullRequest(_ url: String) -> String? {
        guard let match = url.firstMatch(of: /github\.com\/([^\/]+\/[^\/]+)\/pull\/(\d+)/) else { return nil }
        return "\(match.1)#\(match.2)"
    }
}
