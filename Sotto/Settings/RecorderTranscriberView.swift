import SwiftUI
import UniformTypeIdentifiers

struct RecorderTranscriberView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @State private var showFilePicker = false

    /// Owned by the coordinator, so a recording started with the shortcut keeps running
    /// while this window is closed and its result is here when the window opens.
    private var viewModel: RecorderTranscriberViewModel { coordinator.recorder }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                modelStatusSection
                recordingSection
                fileImportSection
                resultSection
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 400)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio, .aiff, .audiovisualContent],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.transcribeFile(at: url)
            }
        }
        .onChange(of: viewModel.phase) { _, phase in
            announce(phase)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.badge.mic")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Transcribe Audio")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Record yourself or import an audio file, then copy the full transcription.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Model Status

    @ViewBuilder
    private var modelStatusSection: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.canTranscribe ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.canTranscribe ? .green : .orange)
                .accessibilityHidden(true)
            if let name = viewModel.activeModelName {
                Text("Active model: \(name)")
                    .font(.callout)
            } else {
                Text("No model loaded. Download one in the Model tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingSection: some View {
        VStack(spacing: 12) {
            Text("Record")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                if case .recording = viewModel.phase {
                    Button(role: .destructive) {
                        viewModel.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    VStack(alignment: .leading) {
                        Text(formatDuration(viewModel.recordingDuration))
                            .font(.title3.monospacedDigit())
                        ProgressView()
                            .controlSize(.small)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Recording")
                    .accessibilityValue(spokenDuration(viewModel.recordingDuration))
                } else {
                    Button {
                        viewModel.startRecording()
                    } label: {
                        Label("Record", systemImage: "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                @Bindable var viewModel = viewModel
                Toggle("Include system audio", isOn: $viewModel.includeSystemAudio)
                    .disabled(viewModel.isBusy)
                Text("Also records what other apps play, like the other side of a call. Use headphones so your microphone doesn't pick it up twice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .recording = viewModel.phase, viewModel.includeSystemAudio {
                liveCallPanel
            }
        }
    }

    /// What Sotto sees of the call and the transcript so far, while it records.
    private var liveCallPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = viewModel.liveContext {
                Text("\(context.app) · \(context.title)")
                    .font(.subheadline.weight(.semibold))
                if !context.participants.isEmpty {
                    Text("Participants (\(context.participants.count)): \(context.participants.map(\.name).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No call detected yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.liveTranscript.isEmpty
                         ? String(localized: "Listening…")
                         : viewModel.liveTranscript)
                        .font(.callout)
                        .foregroundStyle(viewModel.liveTranscript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .frame(height: 180)
                .onChange(of: viewModel.liveTranscript) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - File Import

    @ViewBuilder
    private var fileImportSection: some View {
        VStack(spacing: 12) {
            Text("Import File")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showFilePicker = true
            } label: {
                Label("Choose Audio File...", systemImage: "doc")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Supports WAV, MP3, M4A, AIFF, CAF")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        switch viewModel.phase {
        case .idle, .recording:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading audio file...")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let progress = viewModel.segmentProgress {
                    Text("Transcribing \(progress.done) of \(progress.total)...")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Transcribing...")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .done(let text):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Transcription")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button {
                        viewModel.copyText()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))

                if viewModel.recordingDuration > 0 {
                    Text("Duration: \(formatDuration(viewModel.recordingDuration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Duration: \(spokenDuration(viewModel.recordingDuration))")
                }

                Button {
                    viewModel.reset()
                } label: {
                    Label("New Transcription", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        case .error(let message):
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.callout)
                }
                Button {
                    viewModel.reset()
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    /// "1 minute, 5 seconds" instead of "1:05", which VoiceOver reads as a ratio.
    private func spokenDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

    /// Results appear without focus moving, so VoiceOver users need to hear the outcome.
    private func announce(_ phase: RecorderTranscriberViewModel.Phase) {
        switch phase {
        case .done:
            AccessibilityNotification.Announcement(String(localized: "Transcription complete")).post()
        case .error(let message):
            AccessibilityNotification.Announcement(message).post()
        case .idle, .recording, .loading, .transcribing:
            break
        }
    }
}
