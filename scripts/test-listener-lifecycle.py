#!/usr/bin/env python3
"""Compile actual voice lifecycle methods with fixture speech/audio APIs. Never opens a microphone."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
baseline = sys.argv[2] if len(sys.argv) == 3 and sys.argv[1] == '--baseline' else None

def source(path):
    if baseline:
        return subprocess.check_output(['git', 'show', f'{baseline}:{path}'], cwd=root, text=True)
    return (root / path).read_text()

listener = source('Tilde/Input/Listener.swift')
listener = listener[listener.index('/// Live'):listener.index('    // MARK: Audio')]
app = source('Tilde/App/AppDelegate.swift')
delegate = app[app.index('    /// When the current hold began'):app.index('    // MARK: tilde:// routes')]
update = app[app.index('        listener.onUpdate ='):app.index('        inlet.show()')]
modern = 'private final class Session' in listener
controller = source('Tilde/Inlet/InletController.swift')
handoff = '// MARK: Voice ownership' in controller

def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        end += 1
    return text[start:end] + '\n'


prefix = r'''import Foundation
import CoreGraphics

enum Media { case audio }
enum Authorization { case authorized }
enum AVCaptureDevice {
    static func requestAccess(for: Media) async -> Bool { true }
    static func authorizationStatus(for: Media) -> Authorization { .authorized }
}
struct AnalyzerInput: Sendable {}
struct AVAudioFormat: Sendable {}
final class AVAudioEngine {}
struct SpeechResult: Sendable { var text: AttributedString; var isFinal: Bool }
@MainActor final class SpeechTranscriber {
    enum Preset { case progressiveTranscription }
    static var latest: SpeechTranscriber?
    let results: AsyncThrowingStream<SpeechResult, Error>
    let continuation: AsyncThrowingStream<SpeechResult, Error>.Continuation
    init(locale: Locale, preset: Preset) {
        (results, continuation) = AsyncThrowingStream.makeStream()
        Self.latest = self
    }
    static func supportedLocale(equivalentTo: Locale) async -> Locale? { equivalentTo }
}
@MainActor final class InstallRequest { func downloadAndInstall() async throws {} }
@MainActor enum AssetInventory {
    static func assetInstallationRequest(supporting: [SpeechTranscriber]) async throws -> InstallRequest? { nil }
}
@MainActor final class SpeechAnalyzer {
    static var latest: SpeechAnalyzer?
    static var pauseNextStart = false
    var gate: CheckedContinuation<Void, Never>?
    var startGate: CheckedContinuation<Void, Error>?
    init(modules: [SpeechTranscriber]) { Self.latest = self }
    static func bestAvailableAudioFormat(compatibleWith: [SpeechTranscriber]) async -> AVAudioFormat? { AVAudioFormat() }
    func start(inputSequence: AsyncStream<AnalyzerInput>) async throws {
        if Self.pauseNextStart {
            Self.pauseNextStart = false
            try await withCheckedThrowingContinuation { startGate = $0 }
        }
    }
    func finalizeAndFinishThroughEndOfInput() async throws {
        await withCheckedContinuation { gate = $0 }
    }
    func cancelAndFinishNow() async {}
}
'''
modern_audio = r'''
    // Only the audio boundary is replaced. Lifecycle methods above come from Listener.swift.
    private func startAudio(for session: Session, into: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        session.engine = AVAudioEngine()
    }
    private func stopAudio(for session: Session) { session.engine = nil; session.level = 0 }
    var auditLive: Bool {
        guard let session else { return false }
        return session.engine != nil && session.analyzer != nil && session.input != nil && session.results?.isCancelled == false
    }
    var auditText: String { session?.transcript ?? "" }
}
'''
legacy_audio = r'''
    private var level = 0.0
    private func startAudio(into: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws { engine = AVAudioEngine() }
    private func stopAudio() { engine = nil; level = 0 }
    var auditLive: Bool { engine != nil && analyzer != nil && input != nil && results?.isCancelled == false }
    var auditText: String { transcript }
    // Adapters let the same overlap assertion exercise the pre-fix implementation.
    func begin() -> UUID { UUID() }
    func start(_ id: UUID) async { await start() }
    func stop(_ id: UUID) {}
    func finish(_ id: UUID) async -> String? { await finish() }
    func cancel() {}
}
'''
delegate_prefix = r'''
@MainActor enum NSEvent {
    enum EventMask { case mouseMoved }
    static let mouseLocation = CGPoint.zero
    static func addGlobalMonitorForEvents(matching: EventMask, handler: @escaping (Int) -> Void) -> Any? { 1 }
    static func removeMonitor(_ monitor: Any) {}
}
@MainActor final class AppModel {
    struct Listening { var transcript = ""; var level = 0.0 }
    var listening: Listening?
    var missedYou = false
    var draft = ""
    struct Message { enum Sender { case tilde }; var id: String; var from: Sender }
    var thread: [Message] = []
    var delivered: [(String, Int)] = []
    func send(_ text: String, about target: Int?) { delivered.append((text, target ?? 0)) }
}
typealias Referent = Int
@MainActor final class Inlet {
    enum Mode: Equatable { case rest, open, compose, listening, job(String), peek(String) }
    struct Preferences { var minimizeAfterSending = true }
    var preferences = Preferences()
    var mode = Mode.rest
}
@MainActor final class LensFixture {
    var visible = false
    func hide() { visible = false }
    func flash(on: Int) { visible = true }
    func show(on: Int) { visible = true }
}
@MainActor enum Pointing { struct Request {} }
@MainActor final class ContextCapture {
    var cancellations = 0
    var starts = 0
    var completion: ((Referent?) -> Void)?
    static func snapshot(at: CGPoint, includeSelection: Bool, fallbackToFrontmost: Bool) -> Pointing.Request? { Pointing.Request() }
    func start(_ request: Pointing.Request?, completion: @escaping (Referent?) -> Void) {
        starts += 1
        self.completion = completion
    }
    func cancel() { cancellations += 1; completion = nil }
}
@MainActor final class InletFixture {
    let model: AppModel
    let inlet = Inlet()
    let lens = LensFixture()
    let contextCapture = ContextCapture()
    var exchangeTarget: Referent?
    private var nextTarget = 0
    private var seen: Set<String> = []
    var target: Int { get { exchangeTarget ?? 0 } set { exchangeTarget = newValue } }
    var delivered: [(String, Int)] { model.delivered }
    init(model: AppModel) { self.model = model }
    func minimizeFixture() { set(.rest) }
    func jobFixture() { set(.job("fixture")) }
    func minimize() { set(.rest) }
    func submittedFixture() { afterSending() }
'''
if '    private func afterSending()' in controller:
    delegate_prefix += method(controller, '    private func afterSending()')
else:
    # Earlier overlap baselines predate the shared submission helper.
    delegate_prefix += '    private func afterSending() { set(.rest) }\n'
if handoff:
    voice = controller[controller.index('    // MARK: Voice ownership'):controller.index('    // MARK: Talking')]
    delegate_prefix += voice.replace('@ObservationIgnored ', '')
    for signature in ['    func compose(about ', '    func listen(about ', '    func send(_ text:', '    func unpoint()', '    func reaim(at ', '    private func captureListeningContext(']:
        delegate_prefix += method(controller, signature)
    delegate_prefix += r'''
    func set(_ mode: Inlet.Mode, focus: Bool = true) {
        leaveVoicePresentation(for: mode)
        inlet.mode = mode
        if mode == .rest { exchangeTarget = nil }
    }
    func listenCapturingContext(at: CGPoint, session: UUID) {
        nextTarget += 1
        listen(about: nextTarget, session: session)
    }
'''
else:
    delegate_prefix += r'''
    func reaim(at: CGPoint) {}
    func set(_ mode: Inlet.Mode, focus: Bool = true) {
        inlet.mode = mode
        if mode == .rest { exchangeTarget = nil }
    }
    func compose(about target: Int?, focus: Bool = true) { exchangeTarget = target; set(.compose) }
    func listenCapturingContext(at: CGPoint) { nextTarget += 1; exchangeTarget = nextTarget; set(.listening) }
    func send(_ text: String) { model.send(text, about: exchangeTarget); afterSending() }
    func unpoint() { exchangeTarget = nil }
    func heard(_ text: String, cancelled: Bool) {
        if !text.isEmpty && !cancelled { model.send(text, about: exchangeTarget); afterSending() }
    }
'''
delegate_prefix += r'''
}
@MainActor final class DelegateFixture {
    let listener = Listener()
    let model = AppModel()
    lazy var inlet = InletFixture(model: model)
    private var lensTracking: Any?
    private var tapPoint = CGPoint.zero
    init() {
'''
delegate_suffix = r'''
    func beginFixture() { beginListening(at: .zero) }
    func triedFixture() { holdBegan = .now.addingTimeInterval(-2); loudest = 1 }
'''
if modern:
    delegate_suffix += '    func endFixture() { endListening(send: true) }\n    func cancelFixture() { cancelListening() }\n}\n'
else:
    delegate_suffix += '    func endFixture() { Task { await endListening(send: true) } }\n    func cancelFixture() {}\n}\n'

tests = r'''
struct Failure: Error, CustomStringConvertible { let description: String }
@main struct LifecycleChecks {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    @MainActor static func wait(_ value: () -> Bool) async throws {
        for _ in 0..<400 {
            if value() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure(description: "Fixture did not reach its expected checkpoint")
    }
    @MainActor static func words(_ text: String) {
        SpeechTranscriber.latest!.continuation.yield(SpeechResult(text: AttributedString(text), isFinal: true))
    }
    @MainActor static func run() async throws {
        let listener = Listener()
        let first = listener.begin()
        await listener.start(first)
        let firstAnalyzer = SpeechAnalyzer.latest!
        words("first hold")
        try await wait { listener.auditText == "first hold" }
        let finishing = Task { await listener.finish(first) }
        try await wait { firstAnalyzer.gate != nil }
        let second = listener.begin()
        await listener.start(second)
        words("second hold")
        try await wait { listener.auditText == "second hold" }
        firstAnalyzer.gate!.resume()
        let oldResult = await finishing.value
        try check(oldResult == nil, "RED: old finish returned a newer hold's transcript: \(oldResult ?? "nil")")
        try check(listener.auditLive, "Old finish cleared or canceled the newer hold's resources")
        words(" keeps recording")
        try await wait { listener.auditText == "second hold keeps recording" }
        listener.cancel()

        // An old analyzer start can resume successfully, or throw, after its replacement starts.
        for fail in [false, true] {
            SpeechAnalyzer.pauseNextStart = true
            let old = listener.begin()
            let starting = Task { await listener.start(old) }
            try await wait { SpeechAnalyzer.latest?.startGate != nil }
            let oldAnalyzer = SpeechAnalyzer.latest!
            let next = listener.begin()
            await listener.start(next)
            if fail { oldAnalyzer.startGate!.resume(throwing: Failure(description: "Fixture setup failed")) }
            else { oldAnalyzer.startGate!.resume() }
            await starting.value
            try check(listener.auditLive, "Stale setup stopped or canceled the newer session")
            listener.cancel()
        }

        // Release before the scheduled start must never open audio.
        let before = SpeechTranscriber.latest
        let stopped = listener.begin()
        listener.stop(stopped)
        await listener.start(stopped)
        try check(SpeechTranscriber.latest === before && !listener.auditLive, "A released hold still started")
        listener.cancel()

        // Exercise the actual AppDelegate voice methods against the actual Listener lifecycle.
        let delegate = DelegateFixture()
        delegate.beginFixture()
        try await wait { delegate.listener.auditLive }
        delegate.triedFixture()
        words("old spoken request")
        try await wait { delegate.listener.auditText == "old spoken request" }
        let delegateAnalyzer = SpeechAnalyzer.latest!
        delegate.endFixture()
        try await wait { delegateAnalyzer.gate != nil }
        delegate.beginFixture()
        try await wait { delegate.listener.auditLive }
        words("new spoken request")
        try await wait { delegate.model.listening?.transcript == "new spoken request" }
        delegateAnalyzer.gate!.resume()
        try await Task.sleep(for: .milliseconds(180))
        try check(delegate.model.listening?.transcript == "new spoken request", "Old finish cleared the new listening UI")
        try check(delegate.inlet.delivered.isEmpty && delegate.inlet.target == 2, "Old finish submitted against the new target")
        try check(delegate.listener.auditLive, "Delegate overlap stopped the new microphone")

        // The surviving hold still finalizes and submits exactly once, including a repeated release.
        delegate.triedFixture()
        let survivingAnalyzer = SpeechAnalyzer.latest!
        delegate.endFixture()
        delegate.endFixture()
        try await wait { survivingAnalyzer.gate != nil }
        survivingAnalyzer.gate!.resume()
        try await wait { delegate.inlet.delivered.count == 1 }
        try check(delegate.inlet.delivered[0].0 == "new spoken request" && delegate.inlet.delivered[0].1 == 2,
            "The surviving hold lost its words or target")
        try check(delegate.model.listening == nil, "Completed listening did not clear its own UI")

        let cancelled = DelegateFixture()
        cancelled.beginFixture()
        try await wait { cancelled.listener.auditLive }
        cancelled.triedFixture()
        let cancelledAnalyzer = SpeechAnalyzer.latest!
        let cancelledTranscriber = SpeechTranscriber.latest!
        cancelled.endFixture()
        try await wait { cancelledAnalyzer.gate != nil }
        cancelled.cancelFixture()
        cancelledTranscriber.continuation.yield(SpeechResult(text: AttributedString("late words"), isFinal: true))
        cancelledAnalyzer.gate!.resume()
        try await Task.sleep(for: .milliseconds(180))
        try check(cancelled.model.listening == nil && cancelled.inlet.delivered.isEmpty && !cancelled.listener.auditLive,
            "Cancelled voice restored its UI or submitted late words")

        // UI navigation during finalization must never retarget speech or move the new surface.
        // New input cancels it; a released request may finish after navigation with its frozen target.
        for destination in ["minimize", "job", "compose", "composeAfterMinimize", "send", "submitted", "unpoint"] {
            let changing = DelegateFixture()
            changing.beginFixture()
            try await wait { changing.listener.auditLive }
            changing.triedFixture()
            words("released request")
            try await wait { changing.listener.auditText == "released request" }
            let changingAnalyzer = SpeechAnalyzer.latest!
            changing.inlet.reaim(at: .zero)
            let lateCapture = changing.inlet.contextCapture.completion
            let beforeRelease = changing.inlet.contextCapture.cancellations
            changing.endFixture()
            try await wait { changingAnalyzer.gate != nil }
            let frozeCapture = changing.inlet.contextCapture.cancellations > beforeRelease
            let captureStarts = changing.inlet.contextCapture.starts
            changing.inlet.reaim(at: .zero)
            lateCapture?(999)
            try check(changing.inlet.contextCapture.starts == captureStarts && changing.inlet.target == 1 && !changing.inlet.lens.visible,
                "Queued re-aim or a late context result revived capture after release")
            switch destination {
            case "minimize":
                changing.inlet.minimizeFixture()
                changing.inlet.set(.open)
                changing.inlet.target = 41
            case "job":
                changing.inlet.jobFixture()
                changing.inlet.target = 42
            case "compose": changing.inlet.compose(about: 77)
            case "composeAfterMinimize":
                changing.inlet.minimizeFixture()
                changing.inlet.set(.open)
                changing.inlet.compose(about: 78)
            case "send": changing.inlet.send("typed request")
            case "submitted": changing.inlet.submittedFixture()
            default: changing.inlet.unpoint()
            }
            changing.model.draft = "new draft"
            let mode = changing.inlet.inlet.mode
            let target = changing.inlet.target
            changingAnalyzer.gate!.resume()
            try await Task.sleep(for: .milliseconds(180))
            if destination == "minimize" || destination == "job" {
                try check(changing.inlet.delivered.count == 1 && changing.inlet.delivered[0].1 == 1,
                    "RED: released voice lost its frozen target after \(destination)")
            } else if destination == "send" {
                try check(changing.inlet.delivered.count == 1 && changing.inlet.delivered[0].0 == "typed request",
                    "Released voice submitted after newer typed input")
            } else {
                try check(changing.inlet.delivered.isEmpty, "Released voice submitted after newer \(destination) input")
            }
            try check(changing.inlet.inlet.mode == mode && changing.inlet.target == target && changing.model.draft == "new draft",
                "Voice completion moved or cleared the newer UI after \(destination)")
            try check(frozeCapture, "Key release did not cancel its pending context capture")
        }

        let lensCleanup = DelegateFixture()
        lensCleanup.inlet.lens.visible = true
        lensCleanup.inlet.compose(about: nil)
        try check(!lensCleanup.inlet.lens.visible, "Nil-context compose left an old Lens visible")
        lensCleanup.inlet.lens.visible = true
        lensCleanup.cancelFixture()
        try check(!lensCleanup.inlet.lens.visible, "Voice cancellation left an old Lens visible")

        let rapid = DelegateFixture()
        let priorTranscriber = SpeechTranscriber.latest
        rapid.beginFixture()
        rapid.endFixture()
        try await Task.sleep(for: .milliseconds(180))
        try check(SpeechTranscriber.latest === priorTranscriber, "A queued delegate start outlived release")
        try check(rapid.model.listening == nil && rapid.inlet.delivered.isEmpty, "Quick release left listening or submitted words")
        print("Listener lifecycle checks passed: overlapping finish, stale setup success/failure, early release, delegate ownership, cancellation, single submission, frozen handoff, UI ownership, lens cleanup")
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { print("Listener lifecycle check failed: \(error)"); exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='tilde-listener-lifecycle-', dir='/tmp') as temp:
    temp = Path(temp)
    combined = prefix + listener + (modern_audio if modern else legacy_audio)
    combined += delegate_prefix + update + '\n    }\n' + delegate + delegate_suffix + tests
    generated = temp / 'ListenerLifecycleChecks.swift'
    generated.write_text(combined)
    binary = temp / 'listener-lifecycle-checks'
    command = ['xcrun', 'swiftc', '-module-cache-path', '/tmp/tilde-listener-lifecycle-module-cache',
               '-swift-version', '6', '-default-isolation', 'MainActor', '-strict-concurrency=complete',
               '-warnings-as-errors', '-parse-as-library', str(generated), '-o', str(binary)]
    subprocess.run(command, cwd=root, check=True)
    result = subprocess.run([str(binary)], cwd=root)
    sys.exit(result.returncode)
