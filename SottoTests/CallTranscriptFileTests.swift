import Foundation
import Testing
@testable import Sotto

struct CallTranscriptFileTests {
    private let labels = CallTranscriptFile.Labels(
        summary: "Resumo", keyPoints: "Pontos principais", decisions: "Decisões",
        nextSteps: "Próximos passos", transcript: "Transcrição"
    )

    @Test func namesTheFileAfterTheCallWithoutPathCharacters() throws {
        let start = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 11, minute: 2)))
        let context = CallContext(app: "Slack", title: "IBRACEM · dev/backend: daily")
        let url = CallTranscriptFile.url(startedAt: start, context: context)
        #expect(url.lastPathComponent == "2026-10-20 11-02 Slack - IBRACEM · dev-backend- daily.md")
        #expect(url.deletingLastPathComponent() == CallTranscriptFile.folder)
    }

    @Test func putsTheSummaryAboveTheTranscript() {
        let markdown = CallTranscriptFile.markdown(
            header: "Google Meet · Daily · 20/10/2026 11:02–11:20\nParticipantes (2): Allan, Leo",
            summary: "Falaram do roteamento.",
            transcript: "[00:02] Allan: Bom dia.",
            labels: labels
        )
        #expect(markdown == """
            # Google Meet · Daily · 20/10/2026 11:02–11:20

            Participantes (2): Allan, Leo

            ## Resumo

            Falaram do roteamento.

            ## Transcrição

            [00:02] Allan: Bom dia.

            """)
    }

    @Test func savesTheTranscriptAloneUntilTheSummaryIsReady() {
        let markdown = CallTranscriptFile.markdown(header: "Slack · daily", summary: nil, transcript: "[00:01] Eu: Oi.", labels: labels)
        #expect(!markdown.contains("## Resumo"))
        #expect(markdown.hasPrefix("# Slack · daily\n\n## Transcrição"))
    }
}
