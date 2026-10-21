import SwiftUI
@preconcurrency import AVFoundation
import CoreAudio
import os
import UniformTypeIdentifiers

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Recorder")

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
    /// Segments done and total while the rest of a call recording is transcribed.
    private(set) var segmentProgress: (done: Int, total: Int)?
    /// While a call is recorded: what Sotto sees of it, and the transcript so far.
    private(set) var liveContext: CallContext?
    private(set) var liveTranscript = ""

    enum SummaryState: Equatable { case none, working, done(String), failed(String) }
    /// The AI summary of the last call, written after its transcript.
    private(set) var summaryState: SummaryState = .none
    /// Where the last call's transcript was saved.
    private(set) var savedFile: URL?
    var aiService: AIService?

    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var liveTranscriber: LiveCallTranscriber?
    private var liveTimer: Timer?
    private let livePanel = LiveCallPanelController()
    private static let livePollInterval: TimeInterval = 3
    /// A long call takes several model passes; past this the summary is given up.
    private static let summaryTimeout: TimeInterval = 180

    // Reusable capture service for recording (separate from the dictation one
    // so we don't interfere with an active push-to-talk session).
    private let captureService = AudioCaptureService()
    private let systemCaptureService = SystemAudioCaptureService()
    private let callObserver = CallContextObserver()

    var canTranscribe: Bool { modelManager?.isModelReady ?? false }
    var activeModelName: String? { modelManager?.activeModelName }

    weak var modelManager: ModelManager?
    /// The input chosen in Settings, shared with dictation. `nil` means the system default.
    var resolveInputDevice: () -> AudioDeviceID? = { nil }

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
        // A call is transcribed while it is recorded, so the model must be ready up front.
        if includeSystemAudio, !(modelManager?.isModelReady ?? false) {
            phase = .error(String(localized: "No model loaded. Please download and select a model in Settings."))
            return
        }
        do {
            captureService.selectedDeviceID = resolveInputDevice()
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
                startLiveTranscription()
            }
            recordingStartTime = Date()
            phase = .recording
            startTimer()
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func startLiveTranscription() {
        guard let mm = modelManager else { return }
        let language = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedLanguage)
        let transcriber = LiveCallTranscriber { samples in
            try await mm.transcribe(samples: samples, language: language).text
        }
        transcriber.onChange = { [weak self] in self?.refreshLiveTranscript() }
        transcriber.systemAudio = { [weak self] since in
            self?.systemCaptureService.getBufferDelta(since: since).samples ?? []
        }
        transcriber.systemSpeakerChanges = { [weak self, weak transcriber] start, end in
            guard let context = self?.callObserver.context, let transcriber else { return [] }
            return SpeakerAttribution.speakerChanges(
                from: start,
                to: end,
                context: context,
                microphoneSpeech: transcriber.microphoneSpeech
            )
        }
        liveTranscriber = transcriber
        liveContext = nil
        liveTranscript = ""
        summaryState = .none
        savedFile = nil
        liveTimer = Timer.scheduledTimer(withTimeInterval: Self.livePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollLiveTranscription() }
        }
        livePanel.show(self)
    }

    private func pollLiveTranscription() {
        guard let liveTranscriber else { return }
        liveTranscriber.poll(.microphone, fetch: captureService.getBufferDelta(since:))
        liveTranscriber.poll(.system, fetch: systemCaptureService.getBufferDelta(since:))
        if liveContext != callObserver.context { liveContext = callObserver.context }
        refreshLiveTranscript()
    }

    private func refreshLiveTranscript() {
        guard let liveTranscriber else { return }
        liveTranscript = Self.transcriptText(liveTranscriber, context: liveContext)
        if let total = segmentProgress?.total {
            segmentProgress = (max(0, total - liveTranscriber.pendingCount), total)
        }
    }

    func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        liveTimer?.invalidate()
        liveTimer = nil
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
            let file = CallTranscriptFile.url(startedAt: recordingStartTime ?? Date(), context: callContext)
            finishCall(microphone: samples, system: systemSamples, context: callContext, header: header, file: file)
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

    /// Most of the call was transcribed while it was recorded; this transcribes what is
    /// left and names the speakers again with everything the call app showed.
    private func finishCall(microphone: [Float], system: [Float], context: CallContext?, header: String, file: URL) {
        guard let liveTranscriber else {
            phase = .error(String(localized: "No speech detected."))
            return
        }
        phase = .transcribing
        liveContext = context
        summaryState = .none
        savedFile = nil
        liveTranscriber.queueRemaining(microphone: microphone, system: system)
        segmentProgress = (0, liveTranscriber.pendingCount)
        Task {
            await liveTranscriber.waitUntilDone()
            segmentProgress = nil
            self.liveTranscriber = nil

            let text = Self.transcriptText(liveTranscriber, context: context)
            if !text.isEmpty {
                phase = .done(header + "\n\n" + text)
                save(header: header, summary: nil, transcript: text, to: file)
                await summarize(header: header, transcript: text, file: file)
            } else if let error = liveTranscriber.lastError {
                phase = .error(error.localizedDescription)
            } else {
                // A denied permission makes the tap deliver silence rather than fail.
                phase = .error(SpeechSegmenter.isSilent(system)
                    ? String(localized: "No system audio was captured. Check that Sotto is allowed under Screen & System Audio Recording in System Settings.")
                    : String(localized: "No speech detected."))
            }
        }
    }

    private static var fileLabels: CallTranscriptFile.Labels {
        .init(
            summary: String(localized: "Summary"),
            keyPoints: String(localized: "Key points"),
            decisions: String(localized: "Decisions"),
            nextSteps: String(localized: "Next steps"),
            transcript: String(localized: "Transcript")
        )
    }

    /// The transcript is saved first, so it is kept even if the summary fails.
    private func save(header: String, summary: String?, transcript: String, to file: URL) {
        let markdown = CallTranscriptFile.markdown(header: header, summary: summary, transcript: transcript, labels: Self.fileLabels)
        do {
            try CallTranscriptFile.write(markdown, to: file)
            savedFile = file
        } catch {
            logger.error("Could not save the call transcript: \(error.localizedDescription)")
        }
    }

    /// Summarizes on device with Apple Intelligence when it is available, then saves the
    /// file again with the summary above the transcript.
    private func summarize(header: String, transcript: String, file: URL) async {
        guard let aiService, aiService.isAvailable else { return }
        summaryState = .working
        do {
            let summary = try await withAITimeout(seconds: Self.summaryTimeout) { [aiService] in
                try await aiService.summarizeCall(transcript, language: Self.summaryLanguage)
            }
            let text = CallTranscriptFile.formatted(summary, labels: Self.fileLabels)
            summaryState = .done(text)
            save(header: header, summary: text, transcript: transcript, to: file)
        } catch {
            logger.error("Call summary failed: \(error.localizedDescription)")
            summaryState = .failed(error.localizedDescription)
        }
    }

    /// The microphone is "Me"; a system segment gets a name when the call app showed who
    /// was speaking then.
    private static func transcriptText(_ transcriber: LiveCallTranscriber, context: CallContext?) -> String {
        let microphoneSpeech = transcriber.microphoneSpeech
        let system = transcriber.entries.filter { $0.source == .system }.map { (start: seconds($0.range.lowerBound), text: $0.text) }
        let entries = transcriber.entries.filter {
            $0.source == .system || !EchoDetector.repeatsSystem($0.text, at: seconds($0.range.lowerBound), system: system)
        }
        let lines = entries.map { entry -> CallTranscript.Line in
            let start = seconds(entry.range.lowerBound)
            let speaker: CallTranscript.Speaker
            switch entry.source {
            case .microphone:
                speaker = .me
            case .system:
                let name = context.flatMap {
                    SpeakerAttribution.speaker(
                        from: start,
                        to: seconds(entry.range.upperBound),
                        context: $0,
                        microphoneSpeech: microphoneSpeech
                    )
                }
                speaker = name.map(CallTranscript.Speaker.named) ?? .others
            }
            return .init(speaker: speaker, start: start, text: entry.text)
        }
        return CallTranscript(lines: lines).formatted(
            meLabel: String(localized: "Me"),
            othersLabel: String(localized: "Others")
        )
    }

    /// The spoken language picked in Settings, else the app's, named in English for the
    /// summary prompt: the on-device model answers in English unless told otherwise.
    private static var summaryLanguage: String {
        let code = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedLanguage)
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
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
