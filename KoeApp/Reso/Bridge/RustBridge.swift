import Foundation

// MARK: - Session Mode

enum SessionMode: Int32 {
    case hold = 0
    case toggle = 1
}

// MARK: - Session State

enum SessionState: String {
    case idle
    case connectingAsr = "connecting_asr"
    case recordingHold = "recording_hold"
    case recordingToggle = "recording_toggle"
    case finalizingAsr = "finalizing_asr"
    case preparingPaste = "preparing_paste"
    case pasting
    case completed
    case failed
    case cancelled
}

// MARK: - Bridge Callback Target

@MainActor
protocol RustBridgeDelegate: AnyObject {
    func rustBridgeDidBecomeReady()
    func rustBridgeDidReceiveFinalText(_ text: String)
    func rustBridgeDidEncounterError(_ message: String)
    func rustBridgeDidReceiveWarning(_ message: String)
    func rustBridgeDidChangeState(_ state: SessionState)
    func rustBridgeDidReceiveInterimText(_ text: String)
}

// MARK: - RustBridge

final class RustBridge: @unchecked Sendable {
    static let shared = RustBridge()

    @MainActor weak var delegate: RustBridgeDelegate?

    private init() {}

    // MARK: - Lifecycle

    func initialize() {
        let callbacks = SPCallbacks(
            on_session_ready: bridgeOnSessionReady,
            on_session_error: bridgeOnSessionError,
            on_session_warning: bridgeOnSessionWarning,
            on_final_text_ready: bridgeOnFinalTextReady,
            on_log_event: bridgeOnLogEvent,
            on_state_changed: bridgeOnStateChanged,
            on_interim_text: bridgeOnInterimText
        )
        sp_core_register_callbacks(callbacks)

        let result = sp_core_create(nil)
        if result != 0 {
            print("[RustBridge] sp_core_create failed: \(result)")
        }
    }

    func destroy() {
        sp_core_destroy()
    }

    // MARK: - Session

    func beginSession(mode: SessionMode, bundleId: String?, pid: Int32) {
        let cBundleId = bundleId.flatMap { $0.withCString { strdup($0) } }
        defer { cBundleId.map { free($0) } }

        let context = SPSessionContext(
            mode: SPSessionMode(rawValue: UInt32(mode.rawValue)),
            frontmost_bundle_id: cBundleId,
            frontmost_pid: pid
        )
        let result = sp_core_session_begin(context)
        if result != 0 {
            print("[RustBridge] sp_core_session_begin failed: \(result)")
        }
    }

    func pushAudio(frame: UnsafePointer<UInt8>, length: UInt32, timestamp: UInt64) {
        sp_core_push_audio(frame, length, timestamp)
    }

    func endSession() {
        sp_core_session_end()
    }

    func cancelSession() {
        sp_core_session_cancel()
    }

    // MARK: - Config

    func reloadConfig() {
        sp_core_reload_config()
    }

    func getHotkeyConfig() -> SPHotkeyConfig {
        sp_core_get_hotkey_config()
    }

    func getFeedbackConfig() -> SPFeedbackConfig {
        sp_core_get_feedback_config()
    }

    func getHideMenuIcon() -> Bool {
        sp_core_get_hide_menu_icon()
    }
}

// MARK: - C Callbacks (free functions)

private func bridgeOnSessionReady() {
    Task { @MainActor in
        RustBridge.shared.delegate?.rustBridgeDidBecomeReady()
    }
}

private func bridgeOnSessionError(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let str = String(cString: message)
    Task { @MainActor in
        RustBridge.shared.delegate?.rustBridgeDidEncounterError(str)
    }
}

private func bridgeOnSessionWarning(_ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let str = String(cString: message)
    Task { @MainActor in
        RustBridge.shared.delegate?.rustBridgeDidReceiveWarning(str)
    }
}

private func bridgeOnFinalTextReady(_ text: UnsafePointer<CChar>?) {
    guard let text else { return }
    let str = String(cString: text)
    Task { @MainActor in
        RustBridge.shared.delegate?.rustBridgeDidReceiveFinalText(str)
    }
}

private func bridgeOnLogEvent(_ level: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let str = String(cString: message)
    let levelName: String
    switch level {
    case 0: levelName = "ERROR"
    case 1: levelName = "WARN"
    case 2: levelName = "INFO"
    default: levelName = "DEBUG"
    }
    print("[Koe/Rust][\(levelName)] \(str)")
}

private func bridgeOnStateChanged(_ state: UnsafePointer<CChar>?) {
    guard let state else { return }
    let str = String(cString: state)
    guard let sessionState = SessionState(rawValue: str) else {
        print("[RustBridge] unknown state: \(str)")
        return
    }
    Task { @MainActor in
        RustBridge.shared.delegate?.rustBridgeDidChangeState(sessionState)
    }
}

private func bridgeOnInterimText(_ text: UnsafePointer<CChar>?) {
    guard let text else { return }
    let str = String(cString: text)
    Task { @MainActor in
        RustBridge.shared.delegate?.rustBridgeDidReceiveInterimText(str)
    }
}
