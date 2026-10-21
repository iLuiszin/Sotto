import Foundation

/// Tells whether a microphone segment is only the call coming back out of the speakers.
///
/// With speakers instead of headphones the microphone hears everyone else, and all of it
/// would be transcribed as the user. The system audio Sotto records is exactly what the
/// speakers played, so it is the reference: when the microphone's loudness rises and
/// falls with the system audio's, a fraction of a second later, the segment is an echo.
/// When the user speaks, their voice follows a shape the system audio does not have,
/// even while someone else is talking, and the segment is kept.
nonisolated enum EchoDetector {
    static let sampleRate = 16_000
    /// 20 ms frames: fine enough to follow syllables.
    static let frameLength = 320
    /// The speakers-to-microphone delay searched, past the start of the microphone segment.
    static let maximumLag = 0.5
    /// Correlation of the two loudness curves above which the segment is an echo.
    static let echoCorrelation: Float = 0.6
    /// The system audio must carry speech in at least this share of the frames.
    static let minimumSystemSpeech: Float = 0.3
    static let speechLevel: Float = -50
    static let silenceLevel: Float = -80

    /// - Parameters:
    ///   - microphone: the microphone segment.
    ///   - system: system audio starting `maximumLag` before the segment (or at the start
    ///     of the recording, with `leading` saying how much earlier it starts) and running
    ///     to its end.
    ///   - leading: samples of `system` before the segment starts.
    static func isEcho(microphone: ArraySlice<Float>, system: ArraySlice<Float>, leading: Int) -> Bool {
        let mic = envelope(microphone)
        let reference = envelope(system)
        let leadingFrames = leading / frameLength
        guard mic.count >= 10, reference.count >= mic.count else { return false }

        let speechFrames = reference.dropFirst(leadingFrames).filter { $0 > speechLevel }.count
        guard Float(speechFrames) / Float(max(1, reference.count - leadingFrames)) >= minimumSystemSpeech else {
            return false
        }

        // The echo trails what was played: microphone frame i matches system frame
        // i + leadingFrames - lag.
        let maxLagFrames = min(leadingFrames, Int(maximumLag * Double(sampleRate)) / frameLength)
        var best: Float = -1
        for lag in 0...maxLagFrames {
            let start = leadingFrames - lag
            let count = min(mic.count, reference.count - start)
            guard count >= 10 else { continue }
            best = max(best, correlation(Array(mic.prefix(count)), Array(reference[start..<(start + count)])))
        }
        return best >= echoCorrelation
    }

    /// Loudness per frame in dBFS, floored so silence does not dominate.
    static func envelope(_ samples: ArraySlice<Float>) -> [Float] {
        var levels: [Float] = []
        var start = samples.startIndex
        while start + frameLength <= samples.endIndex {
            let frame = samples[start..<(start + frameLength)]
            let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frameLength)
            levels.append(max(silenceLevel, meanSquare > 0 ? 10 * log10(meanSquare) : silenceLevel))
            start += frameLength
        }
        return levels
    }

    /// Pearson correlation; 0 when either curve is flat.
    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var covariance: Float = 0, varianceA: Float = 0, varianceB: Float = 0
        for i in a.indices {
            let da = a[i] - meanA, db = b[i] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 0, varianceB > 0 else { return 0 }
        return covariance / (varianceA * varianceB).squareRoot()
    }
}
