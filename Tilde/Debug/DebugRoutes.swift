import AppKit
import TildeKit

/// `tilde://debug/<route>` shows the Inlet in any state with fixture data
/// (fixtures, empty, clear, inlet?mode=&real=1, listen?text=, job?id=&as=conversation, place?edge=, frame, hide),
/// for design work and screenshots without a live agent. Nothing here takes the keyboard.
@MainActor
enum DebugRoutes {
    static func route(_ path: String, value: (String) -> String?, delegate: AppDelegate) {
        let model = delegate.model
        let inlet = delegate.inlet
        let target = Pointing.frontmost()
        func fixtures() { if model.fixture == nil { model.fixture = Fixtures.make() } }

        switch path {
        case "/fixtures":
            model.fixture = Fixtures.make()
        case "/empty":
            model.fixture = AppModel.Fixture()
        case "/clear":
            model.fixture = nil
            model.listening = nil
            inlet.set(.rest)
            delegate.lens.hide()
        case "/inlet":
            // &real=1 shows what's really there.
            if value("real") != "1" { fixtures() }
            switch value("mode") ?? "open" {
            case "rest": inlet.set(.rest)
            case "compose":
                model.draft = value("text") ?? ""
                inlet.compose(about: target, focus: false)
            case "peek":
                let pick = value("message").flatMap(Int.init).map { model.thread.count > $0 ? model.thread[$0] : nil } ?? model.thread.last
                if let pick { inlet.set(.peek(pick.id)) }
            default:
                inlet.set(.open)
                inlet.pinnedOpen = true
            }
        case "/listen":
            fixtures()
            if let target { delegate.lens.show(on: target) }
            model.listening = AppModel.Listening(transcript: value("text") ?? "", level: Double(value("level") ?? "0.4") ?? 0.4)
            inlet.listen(about: target)
        case "/job":
            // ?id=<job id>, a real one if there is one, or the first ready fixture job.
            if model.job(value("id")) == nil { fixtures() }
            // &as=conversation shows a real job's conversation, standing in as a fixture without its diff.
            if value("as") == "conversation", model.fixture == nil, var job = model.job(value("id")) {
                model.loadTranscript(job.id)
                let transcript = model.transcript(job.id)
                job.diff = nil
                model.fixture = AppModel.Fixture(thread: model.thread, jobs: [job], transcripts: [job.id: transcript])
            }
            let job = value("id").flatMap { model.job($0) } ?? model.jobs.first { $0.phase == .ready }
            if let job { inlet.openJob(job, focus: false) }
        case "/place":
            // ?edge=left|right|top forces an edge (none goes back to Settings);
            // &notch=1 pretends the display has a camera housing.
            inlet.forcedEdge = value("edge").flatMap(InletEdge.init)
            inlet.simulatesNotch = value("notch") == "1"
            inlet.place()
        case "/frame":
            // Where the pointer counts as on the Inlet, on screen.
            Log.info("debug", "inlet \(inlet.inlet.mode) \(inlet.hitDescription)")
        case "/hide":
            delegate.lens.hide()
            model.listening = nil
            inlet.set(.rest)
        default:
            break
        }
    }
}
