import AVFoundation
import Speech

/// Live, on-device transcription while the tilde key is held.
@MainActor
final class Listener {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var settled = ""
    private var volatile = ""

    /// Called with the transcript so far and the mic level (0...1).
    var onUpdate: ((String, Double) -> Void)?

    var transcript: String { (settled + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() async {
        settled = ""
        volatile = ""
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do {
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer
            input = continuation

            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard let self else { return }
                        if result.isFinal {
                            self.settled += text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                        self.onUpdate?(self.transcript, self.level)
                    }
                } catch {}
            }

            try await analyzer.start(inputSequence: stream)
            try startAudio(into: continuation, format: format)
        } catch {
            stopAudio()
        }
    }

    /// Stops listening and returns everything heard.
    func finish() async -> String {
        stopAudio()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // Give the last result a moment to land.
        try? await Task.sleep(for: .milliseconds(120))
        results?.cancel()
        analyzer = nil
        input = nil
        return transcript
    }

    // MARK: Audio

    private var level = 0.0

    private func startAudio(into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: micFormat, to: format)
        node.installTap(onBus: 0, bufferSize: AVAudioFrameCount(micFormat.sampleRate / 10), format: micFormat) { [weak self] buffer, _ in
            let rms = Listener.rms(buffer)
            Task { @MainActor in
                guard let self else { return }
                self.level = self.level * 0.6 + rms * 0.4
                self.onUpdate?(self.transcript, self.level)
            }
            guard let converter, let converted = Listener.convert(buffer, with: converter, to: format) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
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
