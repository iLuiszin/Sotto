import Foundation
import Testing
@testable import Sotto

struct MicrophoneGateTests {
    /// A tone at `decibels` dBFS RMS.
    private func tone(_ decibels: Float, seconds: Double) -> [Float] {
        let amplitude = pow(10, decibels / 20) * Float(2).squareRoot()
        let count = Int(seconds * Double(MicrophoneGate.sampleRate))
        return (0..<count).map { amplitude * sin(Float($0) * 0.2) }
    }

    /// A room at -60 dBFS where the user speaks at -20 dBFS.
    private func trainedGate() -> MicrophoneGate {
        var gate = MicrophoneGate()
        let room = tone(-60, seconds: 6)
        let voice = tone(-20, seconds: 4)
        gate.learn((room + voice + room)[...])
        return gate
    }

    @Test func usesTheFixedThresholdUntilItHasHeardEnough() {
        var gate = MicrophoneGate()
        gate.learn(tone(-60, seconds: 1)[...])
        #expect(gate.threshold == MicrophoneGate.defaultThreshold)
        #expect(gate.accepts(tone(-45, seconds: 1)[...]))
    }

    @Test func learnsTheUsersVoiceAndTheRoom() throws {
        let gate = trainedGate()
        let noise = try #require(gate.noiseFloor)
        let voice = try #require(gate.voiceLevel)
        #expect(abs(noise - -60) < 1)
        #expect(abs(voice - -20) < 1)
        // Raised from the fixed -40 to just under the voice.
        #expect(abs(gate.threshold - (voice - MicrophoneGate.belowVoiceFrame)) < 0.01)
    }

    @Test func dropsLeakageButKeepsTheUser() {
        let gate = trainedGate()
        #expect(gate.accepts(tone(-22, seconds: 1)[...]))
        // The call leaking from headphones, well under the user's own voice.
        #expect(!gate.accepts(tone(-38, seconds: 1)[...]))
    }

    @Test func neverGoesBelowTheAbsoluteFloor() {
        var gate = MicrophoneGate()
        gate.learn(tone(-90, seconds: 7)[...])
        #expect(gate.threshold == MicrophoneGate.absoluteFloor)
    }
}
