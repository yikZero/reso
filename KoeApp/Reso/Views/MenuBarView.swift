import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !appState.isSetupComplete {
            SetupFlowView()
        } else {
            mainMenu
        }
    }

    @ViewBuilder
    private var mainMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            todayStatsSection

            Divider()

            if !appState.audioDeviceManager.availableDevices.isEmpty {
                Menu("Microphone") {
                    ForEach(appState.audioDeviceManager.availableDevices) { device in
                        Button {
                            appState.audioDeviceManager.selectDevice(uid: device.id, name: device.name)
                        } label: {
                            HStack {
                                Text(device.name)
                                if device.id == appState.audioDeviceManager.selectedDeviceUID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Button("System Default") {
                        appState.audioDeviceManager.selectDevice(uid: nil, name: nil)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }

            Divider()

            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            Button("Check for Updates…") {
                appState.updateManager.checkForUpdatesFromUserAction()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }
            ))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            Divider()

            Button("Quit Reso") {
                appState.shutdown()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .frame(width: 240)
    }

    @ViewBuilder
    private var todayStatsSection: some View {
        let cost = appState.todayStats.estimatedCost
        Text("Today: \(cost < 0.01 ? "< $0.01" : String(format: "$%.2f", cost))")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .onAppear { appState.refreshTodayStats() }
    }

    private var statusText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        switch appState.sessionState {
        case .idle, .completed, .cancelled:
            return "Ready — v\(version)"
        case .recordingHold, .recordingToggle:
            return "Listening..."
        case .connectingAsr, .finalizingAsr:
            return "Processing..."
        case .preparingPaste, .pasting:
            return "Copied to clipboard"
        case .failed:
            return "Something went wrong"
        }
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[MenuBarView] launch at login error: \(error)")
        }
    }
}
