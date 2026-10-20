import Foundation
import os

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "LiveCallTranscriber")

/// Transcribes a call while it is being recorded: every poll takes the speech segments
/// that have ended (followed by enough silence) from the microphone and system audio,
/// and transcribes them one at a time in the background.
///
/// Only the not-yet-transcribed tail of each buffer is copied on every poll, so a long
/// call does not copy its whole recording every few seconds.
@MainActor
final class LiveCallTranscriber {
    enum Source { case microphone, system }

    struct Entry: Equatable {
        let source: Source
        /// Absolute sample range in that source's recording.
        let range: Range<Int>
        let text: String
    }

    typealias Fetch = (_ since: Int) -> (samples: [Float], nextOffset: Int)

    private static let sampleRate = 16_000
    /// A segment counts as finished once this much audio follows it.
    private static let holdback = sampleRate

    private let transcribe: ([Float]) async throws -> String
    private var committed: [Source: Int] = [.microphone: 0, .system: 0]
    private var queue: [(source: Source, samples: [Float], range: Range<Int>)] = []
    private var worker: Task<Void, Never>?

    private(set) var entries: [Entry] = []
    private(set) var pendingCount = 0
    private(set) var lastError: Error?
    var onChange: (() -> Void)?

    init(transcribe: @escaping ([Float]) async throws -> String) {
        self.transcribe = transcribe
    }

    /// Queues the finished segments recorded so far.
    func poll(_ source: Source, fetch: Fetch) {
        let start = committed[source] ?? 0
        let tail = fetch(start).samples
        take(source, tail: tail, base: start, final: false)
    }

    /// Queues everything left in the complete recordings.
    func queueRemaining(microphone: [Float], system: [Float]) {
        for (source, samples) in [(Source.microphone, microphone), (.system, system)] {
            let start = min(committed[source] ?? 0, samples.count)
            take(source, tail: Array(samples[start...]), base: start, final: true)
        }
    }

    /// Waits until every queued segment is transcribed.
    func waitUntilDone() async {
        await worker?.value
    }

    /// Microphone speech, for recognizing the user's own name in call captions.
    var microphoneSpeech: [ClosedRange<TimeInterval>] {
        entries.filter { $0.source == .microphone }.map {
            Double($0.range.lowerBound) / Double(Self.sampleRate)...Double($0.range.upperBound) / Double(Self.sampleRate)
        }
    }

    private func take(_ source: Source, tail: [Float], base: Int, final: Bool) {
        let segments = SpeechSegmenter.segments(in: tail)
        let finished = final ? segments : segments.filter { $0.upperBound <= tail.count - Self.holdback }
        for range in finished {
            queue.append((source, Array(tail[range]), (base + range.lowerBound)..<(base + range.upperBound)))
        }
        // Resume at the first unfinished segment; with none, keep only the holdback, so
        // silence never piles up in the tail that is copied on every poll.
        let unfinished = segments.dropFirst(finished.count).first
        let next = unfinished?.lowerBound ?? max(finished.last?.upperBound ?? 0, tail.count - Self.holdback)
        committed[source] = base + max(0, next)
        pendingCount = queue.count
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                do {
                    let text = try await self.transcribe(job.samples).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.entries.append(Entry(source: job.source, range: job.range, text: text))
                    }
                } catch {
                    logger.error("Segment transcription failed: \(error.localizedDescription)")
                    self.lastError = error
                }
                self.pendingCount = self.queue.count
                self.onChange?()
            }
            self?.worker = nil
        }
    }
}
