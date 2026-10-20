import SwiftUI
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

@Observable
@MainActor
final class RecorderTranscriberViewModel {
    enum Phase: Equatable { case idle, recording, loading, transcribing, done(String), error(String) }

    var phase: Phase = .idle
    var recordingDuration: TimeInterval = 0
    var audioLevel: Float = 0
    var includeSystemAudio = UserDefaults.standard.bool(forKey: UserDefaultsKeys.recorderIncludeSystemAudio) {
        didSet { UserDefaults.standard.set(includeSystemAudio, forKey: UserDefaultsKeys.recorderIncludeSystemAudio) }
    }
    /// Segments done and total while a call recording is transcribed.
    private(set) var segmentProgress: (done: Int, total: Int)?

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?

    // Reusable capture service for recording (separate from the dictation one
    // so we don't interfere with an active push-to-talk session).
    private let captureService = AudioCaptureService()
    private let systemCaptureService = SystemAudioCaptureService()
    private let callObserver = CallContextObserver()

    var canTranscribe: Bool { modelManager?.isModelReady ?? false }
    var activeModelName: String? { modelManager?.activeModelName }

    weak var modelManager: ModelManager?

    // MARK: - Recording

    func startRecording() {
        // This view model lives as long as the app, so the permission it cached at launch
        // can be stale: check again, and ask, before giving up.
        guard captureService.hasMicrophonePermission else {
            Task {
                if await captureService.requestMicrophonePermission() {
                    startRecording()
                } else {
                    phase = .error(String(localized: "Microphone permission required."))
                }
            }
            return
        }
        do {
            captureService.selectedDeviceID = nil
            try captureService.startCapture()
            if includeSystemAudio {
                do {
                    try systemCaptureService.startCapture()
                } catch {
                    _ = captureService.stopCapture()
                    phase = .error(String(localized: "Could not capture system audio: \(error.localizedDescription)"))
                    return
                }
                callObserver.start()
            }
            recordingStartTime = Date()
            phase = .recording
            startTimer()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        let samples = captureService.stopCapture()
        let systemSamples = systemCaptureService.isCapturing ? systemCaptureService.stopCapture() : nil
        let callContext = systemSamples == nil ? nil : callObserver.stop()
        let timeRange = recordingStartTime.map { Self.timeRange(from: $0, to: Date()) } ?? ""
        recordingDuration = Double(max(samples.count, systemSamples?.count ?? 0)) / 16_000
        audioLevel = 0

        guard recordingDuration >= 0.3 else {
            phase = .error(String(localized: "Recording too short."))
            return
        }
        if let systemSamples {
            let header = CallTranscript.header(
                context: callContext,
                timeRange: timeRange,
                participantsLabel: String(localized: "Participants")
            )
            transcribeCall(microphone: samples, system: systemSamples, context: callContext, header: header)
        } else {
            transcribe(samples: samples)
        }
    }

    // MARK: - File Import

    func transcribeFile(at url: URL) {
        phase = .loading
        Task {
            do {
                let samples = try await loadAudioSamples(from: url)
                guard !samples.isEmpty else {
                    phase = .error(String(localized: "No audio data in file."))
                    return
                }
                recordingDuration = Double(samples.count) / 16_000
                transcribe(samples: samples)
            } catch {
                phase = .error(String(localized: "Could not load audio: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Transcription

    private func transcribe(samples: [Float]) {
        guard let mm = modelManager, mm.isModelReady else {
            phase = .error(String(localized: "No model loaded. Please download and select a model in Settings."))
            return
        }
        phase = .transcribing
        Task {
            do {
                let language = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedLanguage)
                let result = try await mm.transcribe(samples: samples, language: language)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                phase = text.isEmpty ? .error(String(localized: "No speech detected.")) : .done(text)
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    /// Each source is split on silence and every segment transcribed on its own, so the
    /// result can be interleaved as "Me" / "Others" without engine timestamps. A system
    /// segment gets a name when the call app showed who was speaking then.
    private func transcribeCall(microphone: [Float], system: [Float], context: CallContext?, header: String) {
        guard let mm = modelManager, mm.isModelReady else {
            phase = .error(String(localized: "No model loaded. Please download and select a model in Settings."))
            return
        }
        // A denied permission makes the tap deliver silence rather than fail.
        let systemSilent = SpeechSegmenter.isSilent(system)

        let microphoneSegments = SpeechSegmenter.segments(in: microphone)
        let microphoneSpeech = microphoneSegments.map { Self.seconds($0.lowerBound)...Self.seconds($0.upperBound) }
        let jobs: [(CallTranscript.Speaker, [Float], Range<Int>)] =
            microphoneSegments.map { (.me, microphone, $0) }
            + SpeechSegmenter.segments(in: system).map { range in
                let name = context.flatMap {
                    SpeakerAttribution.speaker(
                        from: Self.seconds(range.lowerBound),
                        to: Self.seconds(range.upperBound),
                        context: $0,
                        microphoneSpeech: microphoneSpeech
                    )
                }
                return (name.map(CallTranscript.Speaker.named) ?? .others, system, range)
            }
        guard !jobs.isEmpty else {
            phase = .error(systemSilent
                ? String(localized: "No system audio was captured. Check that Sotto is allowed under Screen & System Audio Recording in System Settings.")
                : String(localized: "No speech detected."))
            return
        }

        phase = .transcribing
        segmentProgress = (0, jobs.count)
        Task {
            defer { segmentProgress = nil }
            do {
                let language = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedLanguage)
                var lines: [CallTranscript.Line] = []
                for (index, (speaker, samples, range)) in jobs.enumerated() {
                    let result = try await mm.transcribe(samples: Array(samples[range]), language: language)
                    lines.append(.init(
                        speaker: speaker,
                        start: Self.seconds(range.lowerBound),
                        text: result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    segmentProgress = (index + 1, jobs.count)
                }
                let text = CallTranscript(lines: lines).formatted(
                    meLabel: String(localized: "Me"),
                    othersLabel: String(localized: "Others")
                )
                phase = text.isEmpty ? .error(String(localized: "No speech detected.")) : .done(header + "\n\n" + text)
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    private static func seconds(_ sampleIndex: Int) -> TimeInterval {
        Double(sampleIndex) / 16_000
    }

    /// "20/10/2026 14:02–14:31" in the user's locale.
    private static func timeRange(from start: Date, to end: Date) -> String {
        let date = start.formatted(date: .numeric, time: .omitted)
        let startTime = start.formatted(date: .omitted, time: .shortened)
        let endTime = end.formatted(date: .omitted, time: .shortened)
        return "\(date) \(startTime)–\(endTime)"
    }

    // MARK: - Utilities

    func copyText() {
        guard case .done(let text) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reset() {
        phase = .idle
        recordingDuration = 0
    }

    var hasResult: Bool { if case .done = phase { return true } else { return false } }

    var resultText: String { if case .done(let t) = phase { return t } else { return "" } }

    var isRecording: Bool { phase == .recording }

    /// For the global recorder shortcut: starts a recording, or stops the current one
    /// and transcribes it. Ignored while a previous recording is still transcribing.
    func toggleRecording() {
        switch phase {
        case .recording: stopRecording()
        case .loading, .transcribing: break
        case .idle, .done, .error: startRecording()
        }
    }

    var isBusy: Bool {
        switch phase {
        case .recording, .loading, .transcribing: true
        default: false
        }
    }

    private func startTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
                self.audioLevel = self.captureService.audioLevel
            }
        }
    }
}

// MARK: - Audio file loading

/// Decodes and resamples the whole file, which can take seconds for long recordings.
/// `@concurrent` keeps it off the MainActor that the target isolates everything to by default.
@concurrent nonisolated private func loadAudioSamples(from url: URL) async throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat

    guard let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ), let converter = AVAudioConverter(from: format, to: targetFormat) else {
        // Already 16kHz mono?
        if format.sampleRate == 16_000 && format.channelCount == 1 {
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return [Float]() }
            try file.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        throw NSError(domain: "Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
    }

    let frameCount = AVAudioFrameCount(file.length)
    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "Recorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate input buffer"])
    }
    try file.read(into: inputBuffer)

    // Headroom for the frames the resampler holds back until it is flushed.
    let ratio = targetFormat.sampleRate / format.sampleRate
    let outputFrameCount = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
        throw NSError(domain: "Recorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate output buffer"])
    }

    var error: NSError?
    var consumed = false
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        // .endOfStream, not .noDataNow, so the resampler flushes its tail.
        if consumed {
            outStatus.pointee = .endOfStream
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return inputBuffer
    }

    if let error { throw error }

    guard let channelData = outputBuffer.floatChannelData?[0] else { return [Float]() }
    return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
}
