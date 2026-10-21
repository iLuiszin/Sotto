import Foundation
import Testing
@testable import Sotto

struct CallContextPromptTests {
    @Test func keepsShortContextWhole() {
        #expect(WhisperKitEngine.recentWords(of: "  Vamos tentar no Edge.  ") == "Vamos tentar no Edge.")
    }

    @Test func keepsTheEndOfLongContextFromAWordBoundary() {
        let text = String(repeating: "extensão ", count: 60) + "vou mandar mensagem para ele"
        let recent = WhisperKitEngine.recentWords(of: text)
        #expect(recent.hasSuffix("vou mandar mensagem para ele"))
        #expect(recent.count <= 300)
        #expect(recent.hasPrefix("extensão"))
    }

    @Test func aBreathInsideAnAnswerDoesNotSplitIt() {
        let speech = (0..<16_000).map { 0.3 * sin(Float($0) / 5) }
        let breath = [Float](repeating: 0, count: 16_000)
        var configuration = SpeechSegmenter.Configuration()
        configuration.minSilence = LiveCallTranscriber.callPause
        #expect(SpeechSegmenter.segments(in: speech + breath + speech, configuration: configuration).count == 1)
        // Dictation still cuts there.
        #expect(SpeechSegmenter.segments(in: speech + breath + speech).count == 2)
    }
}
