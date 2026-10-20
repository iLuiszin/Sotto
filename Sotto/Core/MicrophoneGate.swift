import Foundation

/// Learns, while a call is recorded, how loud the user's own voice is in the microphone,
/// so that quieter sound — the call leaking from headphones, typing, the room — is not
/// transcribed as if the user said it. A model fed only noise tends to invent words,
/// often in another language.
///
/// Levels are in dBFS per 30 ms frame. The voice level is a high percentile of the frames
/// that are clearly above the noise floor, so it follows the user's actual speaking level
/// (and microphone gain) instead of a fixed number.
nonisolated struct MicrophoneGate {
    static let sampleRate = 16_000
    static let frameLength = 480

    /// Before the user has spoken enough to measure, accept what the old fixed threshold did.
    static let defaultThreshold: Float = -40
    /// Never treat anything quieter than this as speech, however quiet the room is.
    static let absoluteFloor: Float = -50
    /// Speech must clear the noise floor by this much.
    static let aboveNoise: Float = 12
    /// A frame this far below the user's voice is not the user.
    static let belowVoiceFrame: Float = 18
    /// A whole segment this far below the user's voice is leakage, not the user.
    static let belowVoiceSegment: Float = 10
    /// Frames needed before the levels are trusted: about 6 seconds of audio.
    static let minimumFrames = 200
    /// Roughly the last 10 minutes are kept, so the levels follow a changing room.
    static let maximumFrames = 20_000

    private var levels: [Float] = []

    /// Measures newly recorded samples. Pass each sample once.
    mutating func learn(_ samples: ArraySlice<Float>) {
        var start = samples.startIndex
        while start + Self.frameLength <= samples.endIndex {
            levels.append(Self.decibels(samples[start..<(start + Self.frameLength)]))
            start += Self.frameLength
        }
        if levels.count > Self.maximumFrames {
            levels.removeFirst(levels.count - Self.maximumFrames)
        }
    }

    var noiseFloor: Float? {
        levels.count >= Self.minimumFrames ? Self.percentile(levels, 0.2) : nil
    }

    /// How loud the user speaks; `nil` until they have said enough to measure.
    var voiceLevel: Float? {
        guard let noiseFloor else { return nil }
        let speech = levels.filter { $0 >= noiseFloor + Self.aboveNoise }
        guard speech.count >= Self.minimumFrames / 4 else { return nil }
        return Self.percentile(speech, 0.8)
    }

    /// The frame level, in dBFS, above which the microphone counts as speech.
    var threshold: Float {
        guard let noiseFloor else { return Self.defaultThreshold }
        var threshold = max(Self.absoluteFloor, noiseFloor + Self.aboveNoise)
        if let voiceLevel { threshold = max(threshold, voiceLevel - Self.belowVoiceFrame) }
        return threshold
    }

    /// `threshold` as the linear RMS value `SpeechSegmenter` expects.
    var speechThreshold: Float { pow(10, threshold / 20) }

    /// Whether a segment is loud enough, overall, to be the user speaking.
    func accepts(_ segment: ArraySlice<Float>) -> Bool {
        guard let voiceLevel else { return true }
        var frames: [Float] = []
        var start = segment.startIndex
        while start + Self.frameLength <= segment.endIndex {
            frames.append(Self.decibels(segment[start..<(start + Self.frameLength)]))
            start += Self.frameLength
        }
        guard !frames.isEmpty else { return false }
        // The louder part of the segment: pauses between words would drag a mean down.
        return Self.percentile(frames, 0.75) >= voiceLevel - Self.belowVoiceSegment
    }

    static func decibels(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return -120 }
        let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
        return meanSquare > 0 ? 10 * log10(meanSquare) : -120
    }

    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}
