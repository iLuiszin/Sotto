import Foundation
import os

nonisolated private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "CallTranscriptFile")

/// Saves each call recording as a Markdown file in `~/Documents/Sotto`, so a transcript
/// survives quitting Sotto or starting the next recording, and other tools can read it.
nonisolated enum CallTranscriptFile {
    struct Labels {
        let summary: String
        let keyPoints: String
        let decisions: String
        let nextSteps: String
        let transcript: String
    }

    static var folder: URL {
        URL.documentsDirectory.appending(path: "Sotto", directoryHint: .isDirectory)
    }

    /// "2026-10-20 11-02 Google Meet - Caliber & HarmoniaPay - Daily.md". Characters that
    /// are not allowed in file names are replaced.
    static func url(startedAt start: Date, context: CallContext?) -> URL {
        let stamp = start.formatted(.verbatim(
            "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)",
            timeZone: .current,
            calendar: .current
        ))
        var name = stamp
        if let context { name += " \(context.app) - \(context.title)" }
        let notAllowed = CharacterSet(charactersIn: "/:\\").union(.newlines)
        let safe = String(name.unicodeScalars.map { notAllowed.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        return folder.appending(path: String(safe.prefix(150)) + ".md", directoryHint: .notDirectory)
    }

    /// The call header's first line becomes the title; the rest stays under it.
    static func markdown(header: String, summary: String?, transcript: String, labels: Labels) -> String {
        let headerLines = header.split(separator: "\n", omittingEmptySubsequences: false)
        var parts = ["# \(headerLines.first ?? "")"]
        if headerLines.count > 1 { parts.append(headerLines.dropFirst().joined(separator: "\n")) }
        if let summary { parts.append("## \(labels.summary)\n\n\(summary)") }
        parts.append("## \(labels.transcript)\n\n\(transcript)")
        return parts.joined(separator: "\n\n") + "\n"
    }

    @available(macOS 26.0, *)
    static func formatted(_ summary: CallSummary, labels: Labels) -> String {
        var sections = [summary.overview]
        func list(_ title: String, _ items: [String]) {
            let items = items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { return }
            sections.append("### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        list(labels.keyPoints, summary.keyPoints)
        list(labels.decisions, summary.decisions)
        list(labels.nextSteps, summary.nextSteps)
        return sections.joined(separator: "\n\n")
    }

    static func write(_ markdown: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Saved call transcript to \(url.path, privacy: .private)")
    }
}
