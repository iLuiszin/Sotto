import SwiftUI
import AVFoundation
@preconcurrency import Sparkle

@main
struct SottoApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var coordinator = DictationCoordinator()
    @State private var didLaunch = false
    // Personal fork: upstream's appcast would replace this build with the original app.
    private let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    private var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: "onboardingCompleted")
    }

    var body: some Scene {
        MenuBarExtra("Sotto", systemImage: "waveform") {
            MenuBarContentView(openWindow: openWindow, coordinator: coordinator, updater: updaterController.updater)
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(coordinator)
                .frame(minWidth: 500, minHeight: 400)
                .task {
                    guard !didLaunch else { return }
                    didLaunch = true
                    if needsOnboarding {
                        openWindow(id: "onboarding")
                        NSApp.setActivationPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                    guard let window = notification.object as? NSWindow,
                          window.identifier?.rawValue.contains("settings") == true else { return }
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 500)

        Window("Welcome", id: "onboarding") {
            OnboardingView(coordinator: coordinator) {
                NSApp.setActivationPolicy(.accessory)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier?.rawValue.contains("onboarding") == true else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }

    init() {
        let coord = DictationCoordinator()
        _coordinator = State(initialValue: coord)

        Task { @MainActor in
            coord.start()
        }
    }
}

private struct MenuBarContentView: View {
    let openWindow: OpenWindowAction
    let coordinator: DictationCoordinator
    let updater: SPUUpdater

    @AppStorage(UserDefaultsKeys.selectedSettingsTab) private var selectedSettingsTab: SettingsTab = .general

    var body: some View {
        if coordinator.translateEnabled {
            Menu("Translate: \(AILanguage.shortCode(for: coordinator.translateTargetLanguage))") {
                ForEach(AILanguage.supported, id: \.code) { lang in
                    Button {
                        coordinator.translateTargetLanguage = lang.code
                    } label: {
                        HStack {
                            Text(lang.name)
                            if coordinator.translateTargetLanguage == lang.code {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()
        }

        Button("Transcribe Audio...") {
            selectedSettingsTab = .transcribe
            openSettings()
        }

        if coordinator.recorder.isRecording {
            Button("Stop Recording") {
                coordinator.toggleRecorder()
            }
        }

        Divider()

        Button("Settings...") {
            openSettings()
        }

        Divider()

        Button("Quit Sotto") {
            NSApp.terminate(nil)
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
