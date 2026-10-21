import AppKit
import SwiftUI

/// A floating panel on the right edge of the screen that follows a call recording:
/// the call Sotto detected, who is in it, and the transcript as it is written.
/// It does not take focus, so it can stay open over the call.
@MainActor
final class LiveCallPanelController {
    private var panel: NSPanel?

    private static let size = NSSize(width: 360, height: 460)
    private static let margin: CGFloat = 12

    func show(_ viewModel: RecorderTranscriberViewModel) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let view = LiveCallPanelView(viewModel: viewModel) { [weak self] in self?.close() }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 280, height: 220)
        let hostingView = NSHostingView(rootView: view)
        // The panel sets the size; without this the view widens to fit unwrapped text.
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - Self.size.width - Self.margin,
                y: frame.maxY - Self.size.height - Self.margin
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct LiveCallPanelView: View {
    let viewModel: RecorderTranscriberViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            summary
            LiveCallView(viewModel: viewModel, transcriptHeight: nil)
            if let file = viewModel.savedFile {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The saved summary is Markdown; shows its "### " headings in bold instead of raw.
    private static func styledSummary(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            if line.hasPrefix("#") {
                var heading = AttributedString(line.drop { $0 == "#" || $0 == " " })
                heading.font = .callout.weight(.semibold)
                result += heading
            } else {
                result += AttributedString(line)
            }
        }
        return result
    }

    @ViewBuilder
    private var summary: some View {
        switch viewModel.summaryState {
        case .none:
            EmptyView()
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing...").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(Self.styledSummary(text))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            Divider()
        case .failed(let message):
            Text("Could not summarize: \(message)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            switch viewModel.phase {
            case .recording:
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(Duration.seconds(viewModel.recordingDuration).formatted(.time(pattern: .minuteSecond)))
                    .font(.headline.monospacedDigit())
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing...").font(.headline)
            case .done(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Done").font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            default:
                EmptyView()
            }
            Spacer()
            if case .recording = viewModel.phase {
                Button(role: .destructive) {
                    viewModel.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close")
        }
    }
}

/// The call Sotto detected and the transcript so far. Shown in the Transcribe tab and
/// in the floating panel.
struct LiveCallView: View {
    let viewModel: RecorderTranscriberViewModel
    /// A fixed height for the transcript, or `nil` to fill the space available.
    let transcriptHeight: CGFloat?

    var body: some View {
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
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .frame(height: transcriptHeight)
                .frame(maxHeight: transcriptHeight == nil ? .infinity : nil)
                .onChange(of: viewModel.liveTranscript) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
        }
    }
}
