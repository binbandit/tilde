import Foundation
import TildeMemory

/// The slow memory passes, on demand (normally the dream runs once a day on its own).
extension Conductor {
    /// Consolidates a day into the notebook now.
    public func dream(about day: Date) async { await dreamer.dream(about: day) }

    /// The first meeting: learn from the agent instructions the owner already keeps and their active projects.
    public func introduce() async { await introduce(instructions: Evidence.instructionFiles) }

    public func introduce(instructions: [URL]) async {
        await dreamer.introduce { [projects] in await Evidence.introduction(instructions: instructions, projects: projects) }
    }

    /// True until tilde has learned anything about its owner.
    public var isFirstMeeting: Bool {
        Note(path: "me.md", parsing: memory.notebook.read("me.md") ?? "").facts.isEmpty
    }
}
