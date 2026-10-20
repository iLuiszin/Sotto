import Foundation

/// Splits a 16 kHz mono recording into speech segments on silence, so each segment can
/// be transcribed on its own and placed on a timeline. Engine-agnostic: no engine has to
/// return timestamps, and long recordings never reach an engine as one huge buffer.
nonisolated enum SpeechSegmenter {
    struct Configuration: Equatable {
        var sampleRate: Double = 16_000
        var frameDuration: TimeInterval = 0.03
        /// RMS above this counts as speech (about -40 dBFS).
        var speechThreshold: Float = 0.01
        /// Silence this long ends a segment.
        var minSilence: TimeInterval = 0.6
        /// Segments shorter than this are dropped as clicks or breaths.
        var minSegment: TimeInterval = 0.4
        /// Longer speech is cut here, which keeps every engine within its comfortable window.
        var maxSegment: TimeInterval = 25
        /// Kept on both sides so word onsets and endings are not clipped.
        var padding: TimeInterval = 0.2
    }

    static func segments(in samples: [Float], configuration: Configuration = .init()) -> [Range<Int>] {
        let frameLength = max(1, Int(configuration.frameDuration * configuration.sampleRate))
        let silenceFrames = Int((configuration.minSilence / configuration.frameDuration).rounded(.up))
        let maxFrames = Int(configuration.maxSegment / configuration.frameDuration)
        let minSamples = Int(configuration.minSegment * configuration.sampleRate)
        let padding = Int(configuration.padding * configuration.sampleRate)

        var ranges: [Range<Int>] = []
        var startFrame: Int?
        var lastSpeechFrame = 0
        let frameCount = (samples.count + frameLength - 1) / frameLength

        func close(through endFrame: Int) {
            guard let start = startFrame else { return }
            startFrame = nil
            guard (endFrame - start + 1) * frameLength >= minSamples else { return }
            let lower = max(0, start * frameLength - padding)
            let upper = min(samples.count, (endFrame + 1) * frameLength + padding)
            ranges.append(lower..<upper)
        }

        for frame in 0..<frameCount {
            let lower = frame * frameLength
            let upper = min(samples.count, lower + frameLength)
            let isSpeech = rms(samples[lower..<upper]) > configuration.speechThreshold

            if isSpeech {
                if startFrame == nil { startFrame = frame }
                lastSpeechFrame = frame
            } else if startFrame != nil, frame - lastSpeechFrame >= silenceFrames {
                close(through: lastSpeechFrame)
            }

            if let start = startFrame, frame - start + 1 >= maxFrames {
                close(through: frame)
            }
        }
        close(through: lastSpeechFrame)

        return merged(ranges, maxLength: maxFrames * frameLength + 2 * padding)
    }

    static func isSilent(_ samples: [Float], configuration: Configuration = .init()) -> Bool {
        segments(in: samples, configuration: configuration).isEmpty
    }

    /// Padding can make neighbours overlap; overlapping audio would be transcribed twice.
    /// Overlapping neighbours are joined, unless that would undo a `maxSegment` cut, in
    /// which case the later one starts where the earlier one ends.
    private static func merged(_ ranges: [Range<Int>], maxLength: Int) -> [Range<Int>] {
        ranges.reduce(into: []) { result, range in
            if let last = result.last, range.lowerBound <= last.upperBound {
                let upper = max(last.upperBound, range.upperBound)
                if upper - last.lowerBound <= maxLength {
                    result[result.count - 1] = last.lowerBound..<upper
                } else if range.upperBound > last.upperBound {
                    result.append(last.upperBound..<range.upperBound)
                }
            } else {
                result.append(range)
            }
        }
    }

    private static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        return sqrt(frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count))
    }
}

/// A transcript of a call: the microphone is "me", system audio is "others".
nonisolated struct CallTranscript: Equatable {
    enum Speaker: Equatable {
        case me, others
    }

    struct Line: Equatable {
        let speaker: Speaker
        let start: TimeInterval
        let text: String
    }

    let lines: [Line]

    /// Lines from both sources, in the order they were spoken. Ties keep "me" first.
    init(lines: [Line]) {
        self.lines = lines
            .filter { !$0.text.isEmpty }
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.start == rhs.element.start ? lhs.offset < rhs.offset : lhs.element.start < rhs.element.start
            }
            .map(\.element)
    }

    /// One line per segment: "[01:05] Me: text". Consecutive segments from the same
    /// speaker are joined so the transcript reads as turns, not as silence-split fragments.
    func formatted(meLabel: String, othersLabel: String) -> String {
        var turns: [Line] = []
        for line in lines {
            if let last = turns.last, last.speaker == line.speaker {
                turns[turns.count - 1] = Line(speaker: last.speaker, start: last.start, text: last.text + " " + line.text)
            } else {
                turns.append(line)
            }
        }
        return turns.map { line in
            let label = line.speaker == .me ? meLabel : othersLabel
            return "[\(Self.timestamp(line.start))] \(label): \(line.text)"
        }
        .joined(separator: "\n\n")
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
