import Foundation
import TildeSupport

/// The scribe reads each finished exchange and files what's worth keeping:
/// preferences, corrections, decisions, project facts. Each pass is its own
/// short-lived model session so it never crowds the manager's context, and it
/// sees the notes it might be updating so it can replace instead of repeat.
public actor Scribe {
    private let memory: Memory
    private let model: any MemoryModel
    private var queue: [String] = []
    private var running = false
    /// Facts filed, for the caption's "Noted" chip.
    public nonisolated let noted: AsyncStream<[Memory.Written]>
    private let emit: AsyncStream<[Memory.Written]>.Continuation

    public init(memory: Memory, model: any MemoryModel) {
        self.memory = memory
        self.model = model
        (noted, emit) = AsyncStream<[Memory.Written]>.makeStream()
    }

    /// Queues an exchange (a tap and its reply, an answer, a finished job) for reflection.
    public func reflect(on exchange: String) {
        queue.append(exchange)
        guard !running else { return }
        running = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            // Batch whatever piled up into one pass.
            let exchange = queue.joined(separator: "\n\n---\n\n")
            queue = []
            if let ops = await extract(from: exchange) {
                let written = await apply(ops)
                if !written.isEmpty { emit.yield(written) }
            }
        }
        running = false
    }

    struct Ops: Decodable {
        struct Remember: Decodable {
            var about: String
            var kind: Memory.Kind
            var section: String
            var fact: String
            var replaces: String?
        }

        struct Forget: Decodable {
            var about: String
            var fact: String
        }

        var remember: [Remember]
        var forget: [Forget]
    }

    func apply(_ ops: Ops) async -> [Memory.Written] {
        var written: [Memory.Written] = []
        for op in ops.remember {
            if let w = try? await memory.remember(
                op.fact, about: op.about, kind: op.kind, section: op.section, replaces: op.replaces, source: "noticed")
            {
                written.append(w)
            }
        }
        for op in ops.forget { _ = try? await memory.forget(op.fact, about: op.about) }
        return written
    }

    private func extract(from exchange: String) async -> Ops? {
        let context = await memory.briefing(for: exchange) ?? ""
        let prompt = """
            \(context)

            <exchange>
            \(exchange)
            </exchange>
            """
        // A fresh session per pass: the scribe is occasional and in the background,
        // and a clean thread means one exchange never colours the next.
        do {
            let reply = try await model.run(ModelPass(
                instructions: Self.instructions(owner: Owner.firstName), prompt: prompt, workdir: memory.notebook.path,
                outputSchema: Self.schema))
            guard let text = reply.text, let data = text.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(Ops.self, from: data)
        } catch {
            return nil
        }
    }

    static func instructions(owner: String) -> String {
        """
        You maintain the long-term memory of tilde, \(owner)'s assistant for agent work. You read one exchange (or a few) \
        between \(owner) and tilde, or the outcome of a delegated job, plus the notes tilde already has. You decide what \
        is worth remembering for months, not minutes.

        Remember:
        - Preferences and taste ("prefers sticky nav bars", "wants PR titles in conventional-commit style").
        - Corrections and disambiguations ("'the paradise app' means ~/Developer/frontend/paradise").
        - Decisions with lasting effect, and the reason when given.
        - Project facts: what it is, stack, build and test commands, conventions, which harness works well there.
        - Standing instructions about how agents should work.

        Do not remember:
        - Anything already in the notes, unless it changed (then set `replaces` to the old fact's text).
        - Transient task details, status updates, or what a single job did (tilde logs jobs separately).
        - Guesses. Only what was said, chosen, or clearly shown.
        - Secrets of any kind.

        Write each fact as one short, standalone sentence in the third person about \(owner) or the project, e.g. \
        "Prefers Bun over pnpm." `about` is "me" for \(owner), a project name (or path) for project facts, or a short \
        topic name ("swiftui", "pull requests"). `kind` matches: me, project, or topic. `section` is a short heading such \
        as Preferences, Facts, How to build, Conventions, Decisions. Use `forget` only when \(owner) retracts something. \
        Most exchanges contain nothing worth keeping: return empty arrays then.
        """
    }

    static let schema: JSON = [
        "type": "object",
        "additionalProperties": false,
        "required": ["remember", "forget"],
        "properties": [
            "remember": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["about", "kind", "section", "fact", "replaces"],
                    "properties": [
                        "about": ["type": "string"],
                        "kind": ["type": "string", "enum": ["me", "project", "topic"]],
                        "section": ["type": "string"],
                        "fact": ["type": "string"],
                        "replaces": ["type": ["string", "null"]],
                    ],
                ],
            ],
            "forget": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["about", "fact"],
                    "properties": ["about": ["type": "string"], "fact": ["type": "string"]],
                ],
            ],
        ],
    ]
}
