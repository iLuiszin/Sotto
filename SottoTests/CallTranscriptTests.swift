import Foundation
import Testing
@testable import Sotto

struct SpeechSegmenterTests {
    private let rate = 16_000

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { sin(Float($0) * 0.1) * 0.3 }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    @Test func silenceHasNoSegments() {
        #expect(SpeechSegmenter.segments(in: silence(3)).isEmpty)
        #expect(SpeechSegmenter.isSilent(silence(3)))
    }

    @Test func splitsOnLongSilence() {
        let audio = silence(1) + tone(2) + silence(1.5) + tone(1)
        let segments = SpeechSegmenter.segments(in: audio)
        #expect(segments.count == 2)
        #expect(segments[0].lowerBound < rate)
        #expect(segments[1].lowerBound > Int(4.0 * Double(rate)))
    }

    @Test func shortPauseStaysInOneSegment() {
        let audio = tone(1) + silence(0.3) + tone(1)
        #expect(SpeechSegmenter.segments(in: audio).count == 1)
    }

    @Test func dropsBlipsShorterThanMinimum() {
        let audio = silence(1) + tone(0.1) + silence(1)
        #expect(SpeechSegmenter.segments(in: audio).isEmpty)
    }

    @Test func cutsSpeechLongerThanMaximum() {
        let segments = SpeechSegmenter.segments(in: tone(60))
        #expect(segments.count >= 3)
        #expect(segments.allSatisfy { Double($0.count) / Double(rate) <= 26 })
    }

    @Test func segmentsNeverOverlap() {
        let segments = SpeechSegmenter.segments(in: tone(60))
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(a.upperBound <= b.lowerBound)
        }
    }
}

struct SlackHuddleLabelsTests {
    @Test func parsesHuddleWindowTitle() {
        let place = SlackHuddleLabels.parseWindowTitle("meus-bots - IBRACEM - Slack")
        #expect(place?.channel == "meus-bots")
        #expect(place?.workspace == "IBRACEM")
    }

    @Test func rejectsMainWindowTitle() {
        #expect(SlackHuddleLabels.parseWindowTitle("meus-bots (Canal) - IBRACEM - 14 novos itens - Slack [Principal] 🏠") == nil)
        #expect(SlackHuddleLabels.parseWindowTitle("Preferências") == nil)
    }

    @Test func readsParticipantNameFromTileRow() {
        #expect(SlackHuddleLabels.participantName(fromRowTitle: "Ver perfil de Luís Felipe Matos Corrêa") == "Luís Felipe Matos Corrêa")
        #expect(SlackHuddleLabels.participantName(fromRowTitle: "View profile of Daniel Botelho") == "Daniel Botelho")
        #expect(SlackHuddleLabels.participantName(fromRowTitle: "Daniel Botelho: CMA@IBRA100.") == nil)
        #expect(SlackHuddleLabels.participantName(fromRowTitle: "Ver perfil de ") == nil)
    }

    @Test func readsMicStateFromTileLabel() {
        #expect(SlackHuddleLabels.isMicOn(fromTileLabel: "vídeo está desativado, áudio está ativado") == true)
        #expect(SlackHuddleLabels.isMicOn(fromTileLabel: "vídeo está desativado, áudio está desativado") == false)
        #expect(SlackHuddleLabels.isMicOn(fromTileLabel: "Mais ações") == nil)
    }
}

struct CallTranscriptTests {
    @Test func headerListsHuddlePlaceAndParticipants() {
        let huddle = HuddleContext(workspace: "IBRACEM", channel: "meus-bots", participants: [
            .init(name: "Luís Felipe", micOnAt: [0]),
            .init(name: "Daniel Botelho", micOnAt: []),
        ])
        #expect(CallTranscript.header(huddle: huddle, timeRange: "20/10/2026 14:02–14:31", participantsLabel: "Participantes")
            == "Slack · IBRACEM · meus-bots · 20/10/2026 14:02–14:31\nParticipantes: Luís Felipe, Daniel Botelho")
    }

    @Test func headerWithoutHuddleIsJustTheTime() {
        #expect(CallTranscript.header(huddle: nil, timeRange: "20/10/2026 14:02–14:31", participantsLabel: "Participantes")
            == "20/10/2026 14:02–14:31")
    }

    @Test func interleavesByStartTime() {
        let transcript = CallTranscript(lines: [
            .init(speaker: .others, start: 5, text: "Fine, thanks."),
            .init(speaker: .me, start: 1, text: "How are you?"),
        ])
        #expect(transcript.formatted(meLabel: "Me", othersLabel: "Others")
            == "[00:01] Me: How are you?\n\n[00:05] Others: Fine, thanks.")
    }

    @Test func joinsConsecutiveLinesFromSameSpeaker() {
        let transcript = CallTranscript(lines: [
            .init(speaker: .me, start: 0, text: "Hello."),
            .init(speaker: .me, start: 3, text: "Can you hear me?"),
            .init(speaker: .others, start: 6, text: "Yes."),
        ])
        #expect(transcript.formatted(meLabel: "Me", othersLabel: "Others")
            == "[00:00] Me: Hello. Can you hear me?\n\n[00:06] Others: Yes.")
    }

    @Test func dropsEmptyLinesAndFormatsHours() {
        let transcript = CallTranscript(lines: [
            .init(speaker: .others, start: 3725, text: "Bye."),
            .init(speaker: .me, start: 10, text: ""),
        ])
        #expect(transcript.formatted(meLabel: "Eu", othersLabel: "Outros") == "[1:02:05] Outros: Bye.")
    }
}
