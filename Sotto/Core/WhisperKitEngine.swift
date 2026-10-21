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
        try await transcribe(samples: samples, language: language, context: nil)
    }

    func transcribe(samples: [Float], language: String?, context: String?) async throws -> SottoTranscription {
        guard let whisperKit else { throw TranscriptionError.engineNotConfigured }

        let promptTokens = makePromptTokens(tokenizer: whisperKit.tokenizer, context: context)

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

    /// Whisper reads at most 224 prompt tokens; earlier speech beyond this adds little.
    private static let maximumContextCharacters = 300

    /// The vocabulary keywords, then the end of what was said just before: with the topic
    /// and names in view, Whisper guesses short or unclear phrases far better.
    private func makePromptTokens(tokenizer: WhisperTokenizer?, context: String?) -> [Int]? {
        guard let tokenizer else { return nil }

        let keywords = (UserDefaults.standard.string(forKey: UserDefaultsKeys.vocabularyKeywords) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let recent = context.map { Self.recentWords(of: $0) } ?? ""
        let prompt = [keywords.joined(separator: ", "), recent].filter { !$0.isEmpty }.joined(separator: ". ")

        guard !prompt.isEmpty else { return nil }

        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        let tokens = tokenizer.encode(text: prompt)
            .filter { $0 < specialBegin }
        return tokens.isEmpty ? nil : tokens
    }

    /// The last words of `text`, cut at a word boundary so the prompt never starts mid-word.
    nonisolated static func recentWords(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumContextCharacters else { return trimmed }
        let tail = trimmed.suffix(maximumContextCharacters)
        guard let space = tail.firstIndex(of: " ") else { return String(tail) }
        return String(tail[tail.index(after: space)...])
    }

    private func modelPath(for model: SottoModel) -> URL {
        modelsDirectory
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(model.id)
    }
}
