import AVFoundation
import AppKit
import UserNotifications

@MainActor
@Observable
final class PermissionManager {
    var microphoneGranted = false
    var accessibilityGranted = false
    var inputMonitoringGranted = false

    func checkAllPermissions() async {
        microphoneGranted = await requestMicrophonePermission()
        accessibilityGranted = checkAccessibility()
        inputMonitoringGranted = checkInputMonitoring()
    }

    // MARK: - Microphone

    private func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            print("[PermissionManager] microphone denied/restricted")
            return false
        }
    }

    func isMicrophoneGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Accessibility

    func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Input Monitoring

    func checkInputMonitoring() -> Bool {
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        if let tap {
            CFMachPortInvalidate(tap)
            return true
        }
        return false
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[PermissionManager] notification permission error: \(error)")
            }
        }
    }
}
