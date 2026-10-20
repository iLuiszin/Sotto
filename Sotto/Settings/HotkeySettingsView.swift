import SwiftUI

struct HotkeySettingsView: View {
    @Environment(DictationCoordinator.self) private var coordinator
    @State private var hybridLabel = ""
    @State private var recorderLabel = ""

    var body: some View {
        Form {
            Section("Dictation") {
                HotkeyRecorderView(
                    label: hybridLabel,
                    title: "Dictation shortcut",
                    subtitle: "Hold to talk, tap to toggle",
                    onRecord: { hotkey in
                        coordinator.hotkeyService.updateHotkey(hotkey, for: .hybrid)
                        hybridLabel = HotkeyService.displayName(for: hotkey)
                    },
                    onClear: {
                        coordinator.hotkeyService.clearHotkey(for: .hybrid)
                        hybridLabel = ""
                    }
                )
            }

            Section("Recording") {
                HotkeyRecorderView(
                    label: recorderLabel,
                    title: String(localized: "Start or stop recording"),
                    subtitle: String(localized: "Records in the Transcribe tab, even with the window closed"),
                    onRecord: { hotkey in
                        coordinator.hotkeyService.updateHotkey(hotkey, for: .recorderToggle)
                        recorderLabel = HotkeyService.displayName(for: hotkey)
                    },
                    onClear: {
                        coordinator.hotkeyService.clearHotkey(for: .recorderToggle)
                        recorderLabel = ""
                    }
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            HotkeyRecorderView.hotkeyService = coordinator.hotkeyService
            hybridLabel = loadLabel(for: .hybrid)
            recorderLabel = loadLabel(for: .recorderToggle)
        }
    }

    private func loadLabel(for slot: HotkeySlotType) -> String {
        guard let data = UserDefaults.standard.data(forKey: slot.defaultsKey),
              let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: data) else {
            return ""
        }
        return HotkeyService.displayName(for: hotkey)
    }
}
