import Foundation
import TildeMemory
import TildeWork

/// Episodic memory tilde writes itself, deterministically: a note per job
/// (brief, every decision, outcome) and a line per notable event in today's
/// journal. The scribe and the dream build on these; recall searches them.
struct TaskLog: Sendable {
    let notebook: Notebook

    func open(_ job: Job) {
        var note = Note(path: path(job.id), kind: "task", title: "\(job.title) (\(job.id))")
        note.set("project", [job.projectName])
        note.set("paths", [job.repoPath])
        note.set("harness", [job.harness.rawValue])
        if let branch = job.branch { note.set("branch", [branch]) }
        note.set("created", [LocalTime.format(job.createdAt)])
        note.sections = [("Brief", job.brief), ("Log", "")]
        write(note)
    }

    func append(_ jobID: String, _ line: String) {
        guard var note = load(jobID) else { return }
        let entry = "- \(Date.now.formatted(date: .omitted, time: .shortened)) \(line.replacingOccurrences(of: "\n", with: " "))"
        if let i = note.sections.firstIndex(where: { $0.heading == "Log" }) {
            note.sections[i].body += note.sections[i].body.isEmpty ? entry : "\n" + entry
        } else {
            note.sections.append(("Log", entry))
        }
        write(note)
    }

    func outcome(_ jobID: String, _ text: String) {
        guard var note = load(jobID) else { return }
        note.sections.removeAll { $0.heading == "Outcome" }
        note.sections.append(("Outcome", text))
        write(note)
    }

    func journal(_ line: String, on date: Date = .now) {
        let url = notebook.url.appending(path: Notebook.journalName(for: date))
        var text = (try? String(contentsOf: url, encoding: .utf8))
            ?? "# \(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))\n\n## Log\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += "- \(date.formatted(date: .omitted, time: .shortened)) \(line)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func path(_ jobID: String) -> String { "tasks/\(jobID).md" }

    private func load(_ jobID: String) -> Note? {
        notebook.read(path(jobID)).map { Note(path: path(jobID), parsing: $0) }
    }

    private func write(_ note: Note) {
        let url = notebook.url.appending(path: note.path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? note.render().write(to: url, atomically: true, encoding: .utf8)
    }
}
