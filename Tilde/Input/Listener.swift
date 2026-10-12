import AVFoundation
import Speech

/// Live, on-device transcription while the tilde key is held.
@MainActor
final class Listener {
    /// All mutable recording state belongs to one hold, including work still finishing after release.
    private final class Session {
        let id = UUID()
        var engine: AVAudioEngine?
        var analyzer: SpeechAnalyzer?
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var results: Task<Void, Never>?
        var settled = ""
        var volatile = ""
        var level = 0.0
        var stopping = false
        var finalizing = false

        var transcript: String { (settled + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var session: Session?

    /// Called with the owning hold, transcript so far, and mic level (0...1).
    var onUpdate: ((UUID, String, Double) -> Void)?

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Reserve ownership synchronously, before scheduling setup. A queued start from an earlier
    /// hold can then neither replace this session nor open the microphone after its own release.
    func begin() -> UUID {
        cancel()
        let session = Session()
        self.session = session
        return session.id
    }

    func start(_ id: UUID) async {
        guard let session, session.id == id, !session.stopping,
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do {
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
            guard owns(session), !session.stopping else { return }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            guard owns(session), !session.stopping else { return }
            if let request {
                try await request.downloadAndInstall()
                guard owns(session), !session.stopping else { return }
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                owns(session), !session.stopping else { return }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            session.analyzer = analyzer
            session.input = continuation

            let results = Task { [weak self, weak session] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled, let self, let session, self.owns(session) else { return }
                        let text = String(result.text.characters)
                        if result.isFinal {
                            session.settled += text
                            session.volatile = ""
                        } else {
                            session.volatile = text
                        }
                        self.onUpdate?(session.id, session.transcript, session.level)
                    }
                } catch {}
            }
            session.results = results

            try await analyzer.start(inputSequence: stream)
            guard owns(session), !session.stopping else {
                continuation.finish()
                results.cancel()
                return
            }
            try startAudio(for: session, into: continuation, format: format)
        } catch {
            // A failed setup owns only its own audio, even if a newer hold started while awaiting it.
            stopAudio(for: session)
        }
    }

    /// Close audio and invalidate pending setup immediately when the key is released.
    func stop(_ id: UUID) {
        guard let session, session.id == id else { return }
        session.stopping = true
        stopAudio(for: session)
        session.input?.finish()
    }

    /// Finalize only this hold. Superseded holds return nil and cannot submit another hold's words.
    func finish(_ id: UUID) async -> String? {
        guard let session, session.id == id, !session.finalizing else { return nil }
        stop(id)
        session.finalizing = true
        try? await session.analyzer?.finalizeAndFinishThroughEndOfInput()
        guard owns(session) else { return nil }
        // Give this hold's last result a moment to land.
        try? await Task.sleep(for: .milliseconds(120))
        guard owns(session) else { return nil }
        session.results?.cancel()
        session.analyzer = nil
        session.input = nil
        self.session = nil
        return session.transcript
    }

    func cancel() {
        guard let session else { return }
        self.session = nil
        session.stopping = true
        stopAudio(for: session)
        session.input?.finish()
        session.results?.cancel()
        if let analyzer = session.analyzer, !session.finalizing {
            Task { await analyzer.cancelAndFinishNow() }
        }
        session.analyzer = nil
        session.input = nil
    }

    private func owns(_ session: Session) -> Bool { self.session === session }

    // MARK: Audio

    private func startAudio(for session: Session, into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: micFormat, to: format)
        try node.tap(bufferSize: AVAudioFrameCount(micFormat.sampleRate / 10), format: micFormat) { [weak self, weak session] buffer, _ in
            let rms = Listener.rms(buffer)
            Task { @MainActor in
                guard let self, let session, self.owns(session), !session.stopping else { return }
                session.level = session.level * 0.6 + rms * 0.4
                self.onUpdate?(session.id, session.transcript, session.level)
            }
            guard let converter, let converted = Listener.convert(buffer, with: converter, to: format) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
        session.engine = engine
    }

    private func stopAudio(for session: Session) {
        session.engine?.inputNode.removeTap(onBus: 0)
        session.engine?.stop()
        session.engine = nil
        session.level = 0
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, Double(sqrt(sum / Float(buffer.frameLength))) * 8)
    }
}

extension AVAudioNode {
    /// Taps the node's output, throwing instead of raising when it can't. This is the macOS 27
    /// tap underneath its Swift refinement, which the SDK doesn't ship yet (its error comes
    /// through as a throw, leaving an empty `error:` argument).
    fileprivate func tap(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) throws {
        try __installTap(onBus: 0, bufferSize: bufferSize, format: format, error: (), block: block)
    }
}
