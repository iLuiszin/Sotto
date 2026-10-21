import Foundation
import Testing
@testable import Sotto

struct EchoDetectorTests {
    private let system: [(start: TimeInterval, text: String)] = [
        (130, "O que a gente precisa na Azure, que eu já solicito para o Thiago aqui."),
    ]

    @Test func dropsAMicrophoneLineThatRepeatsTheCall() {
        #expect(EchoDetector.repeatsSystem(
            "Vamos ver o que a gente precisa na Azure, que eu já solicito pro Thiago aqui.",
            at: 136, system: system
        ))
    }

    @Test func keepsTheUsersOwnWords() {
        #expect(!EchoDetector.repeatsSystem(
            "É porque eu que comi bola, o épico 1 tem tarefas tipo 9.1 e 9.2.",
            at: 136, system: system
        ))
    }

    @Test func ignoresSystemLinesFarAway() {
        #expect(!EchoDetector.repeatsSystem(
            "O que a gente precisa na Azure, que eu já solicito para o Thiago aqui.",
            at: 400, system: system
        ))
    }

    @Test func flagsAnEnvelopeThatFollowsTheSystemAudio() {
        // Bursts of "speech" every 200 ms; the microphone hears them 100 ms later, quieter.
        let system = (0..<32_000).map { Float(($0 / 3_200) % 2) * 0.3 * sin(Float($0) / 5) }
        let microphone = (0..<24_000).map { 0.3 * system[$0 + 8_000 - 1_600] }
        #expect(EchoDetector.isEcho(microphone: microphone[...], system: system[...], leading: 8_000))
    }

    @Test func keepsSpeechWhileTheSystemIsSilent() {
        let microphone = (0..<24_000).map { Float(($0 / 2_400) % 2) * 0.3 * sin(Float($0) / 5) }
        let silence = [Float](repeating: 0, count: 32_000)
        #expect(!EchoDetector.isEcho(microphone: microphone[...], system: silence[...], leading: 8_000))
    }
}
