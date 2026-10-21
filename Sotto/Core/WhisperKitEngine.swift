import Foundation
import WhisperKit
import os.log

private let logger = Logger(subsystem: "com.sotto.app", category: "WhisperKitEngine")

@MainActor
final class WhisperKitEngine: TranscriptionEngine {
    let engineName = "WhisperKit"

    private var whisperKit: WhisperKit?
    private let modelsDirectory: URL

    init() {
        self.modelsDirectory = AppConstants.appSupportDirectory
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func loadModel(_ model: SottoModel, onPhaseChange: @escaping (LoadPhase) -> Void) async throws {
        let modelPath = modelPath(for: model)

        let modelFolder: URL
        if FileManager.default.fileExists(atPath: modelPath.path) {
            modelFolder = modelPath
        } else {
            modelFolder = try await WhisperKit.download(
                variant: model.id,
                downloadBase: modelsDirectory
            ) { progress in
                onPhaseChange(.downloading(progress: progress.fractionCompleted))
            }
        }
        try Task.checkCancellation()

        onPhaseChange(.loading)

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)
        try Task.checkCancellation()
        try await kit.loadModels()
        try Task.checkCancellation()
        try await kit.prewarmModels()
        try Task.checkCancellation()

        whisperKit = kit
        logger.info("WhisperKit model loaded: \(model.displayName)")
    }

    func unloadModel() {
        whisperKit = nil
    }

    func deleteModel(_ model: SottoModel) {
        let path = modelPath(for: model)
        try? FileManager.default.removeItem(at: path)
    }

    func isModelDownloaded(_ model: SottoModel) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: model).path)
    }

    func transcribe(samples: [Float], language: String?) async throws -> SottoTranscription {
        guard let whisperKit else { throw TranscriptionError.engineNotConfigured }

        let promptTokens = makePromptTokens(tokenizer: whisperKit.tokenizer)

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        // Whisper pads short clips to 30 s and then tends to invent a polite stock phrase
        // ("Permita-me, por favor.") instead of the words spoken. Those segments come out
        // with low confidence, so keep only the ones the model was reasonably sure of.
        let segments = results.flatMap(\.segments).filter {
            $0.avgLogprob >= Self.minimumLogProb && !($0.noSpeechProb > Self.noSpeechProb && $0.avgLogprob < Self.confidentLogProb)
        }
        let text = segments.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = results.first?.language
        let duration = results.flatMap { $0.segments }.last.map { TimeInterval($0.end) } ?? 0

        return SottoTranscription(text: text, detectedLanguage: detectedLanguage, duration: duration)
    }

    /// Below this average log probability a segment is mostly guessed.
    private static let minimumLogProb: Float = -1.0
    /// A segment Whisper thinks is probably silence, kept only when it is confident.
    private static let noSpeechProb: Float = 0.5
    private static let confidentLogProb: Float = -0.5

    private func makePromptTokens(tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer,
              let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.vocabularyKeywords)
        else { return nil }

        let keywords = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !keywords.isEmpty else { return nil }

        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        let tokens = tokenizer.encode(text: keywords.joined(separator: ", "))
            .filter { $0 < specialBegin }
        return tokens.isEmpty ? nil : tokens
    }

    private func modelPath(for model: SottoModel) -> URL {
        modelsDirectory
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(model.id)
    }
}
