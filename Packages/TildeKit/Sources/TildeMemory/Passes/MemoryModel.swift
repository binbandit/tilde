import TildeSupport

/// Whatever runs the scribe's and the dream's passes over the notebook. Memory only
/// describes a pass; the app decides which model runs it (a Codex thread, in TildeBrain).
public protocol MemoryModel: Sendable {
    /// Runs one pass in a fresh, throwaway session, to the end of its turn.
    func run(_ pass: ModelPass) async throws -> ModelReply
}

/// One self-contained model turn.
public struct ModelPass: Sendable {
    /// The system prompt.
    public var instructions: String
    public var prompt: String
    /// Where the model works. It may read anywhere, but only a `writable` pass may change anything, and only here.
    public var workdir: String
    public var writable: Bool
    /// A JSON Schema the final message must match, for passes whose reply is parsed.
    public var outputSchema: JSON?

    public init(instructions: String, prompt: String, workdir: String, writable: Bool = false, outputSchema: JSON? = nil) {
        self.instructions = instructions
        self.prompt = prompt
        self.workdir = workdir
        self.writable = writable
        self.outputSchema = outputSchema
    }
}

public struct ModelReply: Sendable {
    /// The turn completed, rather than failing or the model going away.
    public var ok: Bool
    /// The model's last message, if it said anything.
    public var text: String?

    public init(ok: Bool, text: String?) {
        self.ok = ok
        self.text = text
    }
}
