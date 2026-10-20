import Foundation
import Testing
@testable import Sotto

struct GoogleMeetLabelsTests {
    @Test func readsMeetingTitleAndCode() {
        #expect(GoogleMeetLabels.meetingTitle(fromPageTitle: "Meet - Daily - Time AGI") == "Daily - Time AGI")
        #expect(GoogleMeetLabels.meetingTitle(fromPageTitle: "Google Agenda") == nil)
        #expect(GoogleMeetLabels.meetingCode(fromAddress: "https://meet.google.com/jkv-pzvy-gjr?authuser=0") == "jkv-pzvy-gjr")
        #expect(GoogleMeetLabels.meetingCode(fromAddress: "https://calendar.google.com/abc-defg-hij") == nil)
    }

    @Test func readsMicStateFromPeoplePanelControls() {
        #expect(GoogleMeetLabels.isMicOn(fromParticipantControl: "Desativar o som do microfone de Sarah Bezerra") == true)
        #expect(GoogleMeetLabels.isMicOn(fromParticipantControl: "Não pode reativar o som de outra pessoa") == false)
        #expect(GoogleMeetLabels.isMicOn(fromParticipantControl: "O microfone está desativado.") == false)
        #expect(GoogleMeetLabels.isMicOn(fromParticipantControl: "Mais ações") == nil)
    }

    /// Shape seen in a real call: the name sits one level deeper than its caption text.
    @Test func pairsCaptionSpeakersWithText() {
        let captions = GoogleMeetLabels.captions(from: [
            (24, "Sarah Bezerra"), (23, "Bom dia, pessoal."),
            (24, "Lucas Biscalquini"), (23, "Bom dia."), (23, "Vamos começar?"),
        ])
        #expect(captions.count == 2)
        #expect(captions[0].speaker == "Sarah Bezerra")
        #expect(captions[1].speaker == "Lucas Biscalquini")
        #expect(captions[1].text == "Bom dia. Vamos começar?")
    }
}

struct SpeakerAttributionTests {
    private func meet(sightings: [(String, TimeInterval)], participants: [String] = [], selfName: String? = nil) -> CallContext {
        var context = CallContext(app: "Google Meet", title: "Daily", selfName: selfName)
        context.observe(participants: participants.map { ($0, nil) }, at: 0)
        for (name, time) in sightings { context.observe(speaker: name, at: time) }
        return context
    }

    @Test func namesTheSpeakerSeenInCaptionsDuringTheSegment() {
        let context = meet(sightings: [("Sarah", 10), ("Sarah", 12), ("Lucas", 30)])
        #expect(SpeakerAttribution.speaker(from: 9, to: 14, context: context, microphoneSpeech: []) == "Sarah")
        #expect(SpeakerAttribution.speaker(from: 29, to: 33, context: context, microphoneSpeech: []) == "Lucas")
    }

    @Test func neverNamesTheUserForSystemAudio() {
        let context = meet(sightings: [("Luis", 10), ("Luis", 11), ("Sarah", 12)], selfName: "Luis")
        #expect(SpeakerAttribution.speaker(from: 9, to: 13, context: context, microphoneSpeech: []) == "Sarah")
    }

    @Test func recognizesTheUserFromMicrophoneSpeechWhenUnmarked() {
        let context = meet(sightings: [("Luis", 5), ("Luis", 6), ("Luis", 7), ("Sarah", 20), ("Sarah", 21), ("Sarah", 22)])
        #expect(SpeakerAttribution.inferredSelf(context: context, microphoneSpeech: [4...8]) == "Luis")
        // Only Sarah is left, so system audio is hers even where captions only showed the user.
        #expect(SpeakerAttribution.speaker(from: 4, to: 8, context: context, microphoneSpeech: [4...8]) == "Sarah")
    }

    @Test func singleOtherParticipantNamesEverySegment() {
        let context = meet(sightings: [], participants: ["Luis", "Daniel"], selfName: "Luis")
        #expect(SpeakerAttribution.speaker(from: 0, to: 5, context: context, microphoneSpeech: []) == "Daniel")
    }

    @Test func staysGenericWhenUnknown() {
        let context = meet(sightings: [], participants: ["Luis", "Daniel", "Julio"], selfName: "Luis")
        #expect(SpeakerAttribution.speaker(from: 0, to: 5, context: context, microphoneSpeech: []) == nil)
    }
}
