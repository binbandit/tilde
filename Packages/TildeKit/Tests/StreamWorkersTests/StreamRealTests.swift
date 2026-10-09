import Foundation
import Testing
import TildeSupport
import WorkerKit
@testable import StreamWorkers

/// Drives the installed `amp` on a throwaway repo: a tiny task, a rail it has to ask
/// about, and a resume in a new process. Opt in with TILDE_REAL_STREAM=1; it spends a
/// little of the user's Amp credit.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TILDE_REAL_STREAM"] == "1"))
struct StreamRealTests {
    @Test(.timeLimit(.minutes(10))) func ampDoesATinyJobUnderTilde() async throws {
        let repo = try await scratchRepo()
        func amp(_ session: String?) -> StreamWorker {
            StreamWorker(
                AmpDialect(userSettings: AmpDialect.userSettings(in: UserEnvironment.shared.variables)),
                launch: WorkerLaunch(
                    workdir: repo, sessionID: session, model: "rush",
                    instructions: Supervision.brief(owner: "the tester")),
                executable: "amp")
        }

        let first = amp(nil)
        let events = StreamEvents(first)
        try await first.start(brief: """
            Create hello.txt containing exactly `hi`, commit it with the message `add hello`, \
            then run `git push origin main`. Reply in one short sentence.
            """)
        let thread = try await events.next(StreamPick.session, within: .seconds(60))
        #expect(thread.hasPrefix("T-"))

        // The push has to reach tilde as a rail; turn it down.
        let asked = try await events.next({ StreamPick.request($0) != nil || StreamPick.turn($0) != nil ? $0 : nil }, within: .seconds(240))
        if let push = StreamPick.request(asked) {
            #expect(push.headline.contains("git push"))
            await first.resolve(push.id, .deny("No pushing in this test."))
        } else {
            Issue.record("Amp ended its turn without trying to push: \(asked)")
        }
        var turn = StreamPick.turn(asked)
        if turn == nil { turn = try await events.next(StreamPick.turn, within: .seconds(240)) }
        #expect(turn?.ok == true, "\(turn?.text ?? "")")
        let hello = try? String(contentsOfFile: repo + "/hello.txt", encoding: .utf8)
        #expect(hello?.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        await first.stop()

        // A new process picks the same thread back up.
        let second = amp(thread)
        let resumed = StreamEvents(second)
        try await second.start(brief: "In one word: what file did you create?")
        #expect(try await resumed.next(StreamPick.session) == thread)
        let answer = try await resumed.next(StreamPick.turn, within: .seconds(240))
        #expect(answer.ok && answer.text.lowercased().contains("hello"), "\(answer.text)")
        await second.stop()
    }

    private func scratchRepo() async throws -> String {
        let repo = FileManager.default.temporaryDirectory.appending(path: "tilde-amp-smoke-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try "# Scratch\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        for command in [
            ["git", "init", "-q", "-b", "main"], ["git", "config", "user.name", "tilde test"],
            ["git", "config", "user.email", "test@tilde.invalid"], ["git", "add", "."], ["git", "commit", "-qm", "init"],
        ] {
            try await Shell.check(command, cwd: repo)
        }
        return repo
    }
}
