import AppKit
import SwiftData

@MainActor
@Observable
final class AppState {
    // MARK: - State

    var sessionState: SessionState = .idle
    var interimText: String = ""
    var initialized = false

    var isSetupComplete: Bool {
        let configPath = NSHomeDirectory() + "/.koe/config.yaml"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api_key:") {
                let value = trimmed.dropFirst("api_key:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return !value.isEmpty && value != "${GEMINI_API_KEY}"
            }
        }
        return false
    }

    // MARK: - Managers

    let permissionManager = PermissionManager()
    let audioDeviceManager = AudioDeviceManager()
    let audioCaptureManager = AudioCaptureManager()
    let clipboardManager = ClipboardManager()
    let pasteManager = PasteManager()
    let cuePlayer = CuePlayer()
    let hotkeyMonitor = HotkeyMonitor()
    let updateManager = UpdateManager()
    var overlayPanel: OverlayPanel?

    private var recordingStartTime: Date?
    private var modelContainer: ModelContainer?

    // MARK: - Initialization

    func initialize() async {
        do {
            modelContainer = try ModelContainer(for: SessionHistory.self)
        } catch {
            print("[AppState] SwiftData init failed: \(error)")
        }

        let bridge = RustBridge.shared
        bridge.delegate = self
        bridge.initialize()

        audioDeviceManager.startListening { [weak self] in
            self?.handleDeviceListChanged()
        }

        overlayPanel = OverlayPanel()

        updateManager.start()

        permissionManager.requestNotificationPermission()

        await permissionManager.checkAllPermissions()

        guard permissionManager.microphoneGranted else {
            cuePlayer.playError()
            return
        }

        if !permissionManager.inputMonitoringGranted {
            print("[AppState] input monitoring not granted")
        }

        hotkeyMonitor.delegate = self
        applyHotkeyConfig()
        hotkeyMonitor.start()
    }

    func shutdown() {
        audioDeviceManager.stopListening()
        hotkeyMonitor.stop()
        RustBridge.shared.destroy()
    }

    // MARK: - Config

    func applyHotkeyConfig() {
        let config = RustBridge.shared.getHotkeyConfig()
        hotkeyMonitor.targetKeyCode = config.trigger_key_code
        hotkeyMonitor.altKeyCode = config.trigger_alt_key_code
        hotkeyMonitor.targetModifierFlag = UInt64(config.trigger_modifier_flag)
        hotkeyMonitor.cancelKeyCode = config.cancel_key_code
        hotkeyMonitor.cancelAltKeyCode = config.cancel_alt_key_code
        hotkeyMonitor.cancelModifierFlag = UInt64(config.cancel_modifier_flag)
    }

    func reloadConfig() {
        RustBridge.shared.reloadConfig()
        let oldConfig = (
            hotkeyMonitor.targetKeyCode,
            hotkeyMonitor.altKeyCode,
            hotkeyMonitor.targetModifierFlag,
            hotkeyMonitor.cancelKeyCode,
            hotkeyMonitor.cancelAltKeyCode,
            hotkeyMonitor.cancelModifierFlag
        )

        let newHK = RustBridge.shared.getHotkeyConfig()
        let newConfig = (
            newHK.trigger_key_code,
            newHK.trigger_alt_key_code,
            UInt64(newHK.trigger_modifier_flag),
            newHK.cancel_key_code,
            newHK.cancel_alt_key_code,
            UInt64(newHK.cancel_modifier_flag)
        )

        let changed = oldConfig != newConfig
        applyHotkeyConfig()
        if changed {
            hotkeyMonitor.stop()
            hotkeyMonitor.start()
        }

        applyMenuIconVisibility()
    }

    func applyMenuIconVisibility() {
        let hide = RustBridge.shared.getHideMenuIcon()
        if hide {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Session Control

    private func startSession(mode: SessionMode) {
        recordingStartTime = Date()
        cuePlayer.reloadFeedbackConfig()
        cuePlayer.playStart()

        sessionState = mode == .hold ? .recordingHold : .recordingToggle
        overlayPanel?.updateState(sessionState)

        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontApp?.bundleIdentifier
        let pid = Int32(frontApp?.processIdentifier ?? 0)

        RustBridge.shared.beginSession(mode: mode, bundleId: bundleId, pid: pid)

        let deviceID = audioDeviceManager.resolvedDeviceID()
        audioCaptureManager.setInputDeviceID(deviceID)
        audioCaptureManager.startCapture { frame, length, timestamp in
            RustBridge.shared.pushAudio(frame: frame, length: length, timestamp: timestamp)
        }
    }

    private func endSession() {
        cuePlayer.playStop()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            self?.audioCaptureManager.stopCapture()
            RustBridge.shared.endSession()
        }
    }

    private func cancelSession() {
        audioCaptureManager.stopCapture()
        RustBridge.shared.cancelSession()
        recordingStartTime = nil
        sessionState = .idle
        overlayPanel?.updateState(.idle)
    }

    // MARK: - Audio Device Changes

    private func handleDeviceListChanged() {
        guard audioCaptureManager.isCapturing else { return }
        if !audioDeviceManager.isSelectedDeviceAvailable() {
            audioCaptureManager.stopCapture()
            handleAudioCaptureError("Selected audio device disconnected")
        }
    }

    private func handleAudioCaptureError(_ message: String) {
        print("[AppState] audio error: \(message)")
        cuePlayer.playError()
        RustBridge.shared.endSession()
        hotkeyMonitor.resetToIdle()
        sessionState = .failed
        overlayPanel?.updateState(.failed)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.sessionState == .failed {
                self?.sessionState = .idle
                self?.overlayPanel?.updateState(.idle)
            }
        }
    }

    // MARK: - History

    private func recordSession(durationMs: Int, text: String) {
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        let entry = SessionHistory(durationMs: durationMs, text: text)
        context.insert(entry)
        try? context.save()
    }

    // MARK: - Copyable Alert (no accessibility fallback)

    private func showCopyableTextAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Voice Input Result"
        alert.informativeText = "Accessibility permission not granted. Text copied to clipboard — paste manually with Cmd+V."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

// MARK: - RustBridgeDelegate

extension AppState: RustBridgeDelegate {
    func rustBridgeDidBecomeReady() {
        print("[AppState] session ready (ASR connected)")
    }

    func rustBridgeDidReceiveFinalText(_ text: String) {
        if let start = recordingStartTime {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            recordSession(durationMs: durationMs, text: text)
        }

        if permissionManager.checkAccessibility() {
            clipboardManager.backup()
            clipboardManager.writeText(text)
            sessionState = .idle
            overlayPanel?.updateState(.idle)

            pasteManager.simulatePaste { [weak self] in
                self?.clipboardManager.scheduleRestore(afterMs: 1500)
            }
        } else {
            sessionState = .idle
            overlayPanel?.updateState(.idle)
            showCopyableTextAlert(text)
        }
    }

    func rustBridgeDidEncounterError(_ message: String) {
        let isAuthError = message.contains("401")
        let isNoSpeech = message.contains("no speech recognized")

        if !isAuthError && !isNoSpeech {
            cuePlayer.playError()
        }

        audioCaptureManager.stopCapture()
        hotkeyMonitor.resetToIdle()

        sessionState = .failed
        overlayPanel?.updateState(.failed)

        let dismissDelay: TimeInterval = isNoSpeech ? 1 : 2
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
            if self?.sessionState == .failed {
                self?.sessionState = .idle
                self?.overlayPanel?.updateState(.idle)
            }
        }
    }

    func rustBridgeDidReceiveWarning(_ message: String) {
        print("[AppState] warning: \(message)")
    }

    func rustBridgeDidChangeState(_ state: SessionState) {
        switch state {
        case .preparingPaste, .pasting, .completed, .failed:
            return
        default:
            sessionState = state
            overlayPanel?.updateState(state)
        }
    }

    func rustBridgeDidReceiveInterimText(_ text: String) {
        interimText = text
    }
}

// MARK: - HotkeyMonitorDelegate

extension AppState: HotkeyMonitorDelegate {
    func hotkeyMonitorDidDetectHoldStart() {
        startSession(mode: .hold)
    }

    func hotkeyMonitorDidDetectHoldEnd() {
        endSession()
    }

    func hotkeyMonitorDidDetectTapStart() {
        startSession(mode: .toggle)
    }

    func hotkeyMonitorDidDetectTapEnd() {
        endSession()
    }

    func hotkeyMonitorDidDetectCancel() {
        cancelSession()
    }
}
