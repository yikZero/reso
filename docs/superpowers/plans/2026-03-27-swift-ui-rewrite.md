# Swift/SwiftUI Full Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the entire Objective-C frontend of Reso to Swift 6 / SwiftUI, targeting macOS 15+, while preserving the Rust backend unchanged.

**Architecture:** SwiftUI `@main` App with `MenuBarExtra` scene for the menu bar, `Settings` scene for configuration, and an NSPanel hosting SwiftUI for the floating overlay. A single `@Observable` `AppState` class is the central source of truth. `RustBridge` wraps all `sp_core_*` FFI calls and dispatches C callbacks to `@MainActor`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, AppKit (NSPanel), AVFoundation, CoreAudio, Carbon (key codes), Rust FFI via C bridging header.

---

## File Structure

```
KoeApp/Reso/
├── ResoApp.swift                    # @main App with MenuBarExtra + Settings
├── State/
│   └── AppState.swift               # @Observable central state + orchestration
├── Bridge/
│   └── RustBridge.swift             # sp_core_* FFI wrapper + C callback registration
├── Managers/
│   ├── HotkeyMonitor.swift          # CGEventTap + NSEvent, 5-state machine
│   ├── AudioCaptureManager.swift    # AVAudioEngine → 16kHz PCM frames
│   ├── AudioDeviceManager.swift     # CoreAudio device enumeration + selection
│   ├── PermissionManager.swift      # Mic, accessibility, input monitoring checks
│   ├── ClipboardManager.swift       # Backup, write, restore clipboard
│   ├── PasteManager.swift           # CGEvent Cmd+V simulation
│   ├── CuePlayer.swift             # System sound feedback
│   └── UpdateManager.swift          # GitHub release update checking
├── Views/
│   ├── MenuBarView.swift            # MenuBarExtra popover content
│   ├── SetupFlowView.swift          # Inline first-launch API key + hotkey setup
│   ├── SettingsView.swift           # Full settings window (4 tabs)
│   ├── OverlayView.swift            # SwiftUI overlay content (waveform, dots, etc.)
│   └── OverlayPanel.swift           # NSPanel subclass + NSHostingView host
├── Models/
│   └── SessionHistory.swift         # SwiftData @Model
├── Reso-Bridging-Header.h          # #import "koe_core.h"
├── Resources/
│   ├── Assets.xcassets/
│   └── Info.plist
└── Reso.entitlements
```

---

### Task 1: Project Configuration & Bridging Header

**Files:**
- Modify: `KoeApp/project.yml`
- Create: `KoeApp/Reso/Reso-Bridging-Header.h`
- Modify: `KoeApp/Reso/Info.plist`

This task sets up the build system for Swift, removes ObjC references, and creates the bridging header for Rust FFI.

- [ ] **Step 1: Create the bridging header**

```c
// KoeApp/Reso/Reso-Bridging-Header.h
#ifndef Reso_Bridging_Header_h
#define Reso_Bridging_Header_h

#include "koe_core.h"

#endif
```

- [ ] **Step 2: Update project.yml for Swift**

Replace the entire `project.yml` with:

```yaml
name: Reso
options:
  deploymentTarget:
    macOS: "15.0"
  xcodeVersion: "16.0"
  defaultConfig: Release

settings:
  base:
    PRODUCT_BUNDLE_IDENTIFIER: com.yikzero.reso
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    ENABLE_HARDENED_RUNTIME: YES
    APP_UPDATE_FEED_URL: "https://raw.githubusercontent.com/yikZero/reso/main/docs/update-feed.json"

targets:
  Reso:
    type: application
    platform: macOS
    sources:
      - path: Reso
        excludes:
          - "*.entitlements"
    settings:
      base:
        INFOPLIST_FILE: Reso/Info.plist
        CODE_SIGN_ENTITLEMENTS: Reso/Reso.entitlements
        PRODUCT_NAME: Reso
        CODE_SIGN_IDENTITY: "Apple Development"
        DEVELOPMENT_TEAM: 648N996R87
        CODE_SIGN_STYLE: Automatic
        SWIFT_VERSION: "6.0"
        SWIFT_OBJC_BRIDGING_HEADER: "Reso/Reso-Bridging-Header.h"
        HEADER_SEARCH_PATHS:
          - "$(inherited)"
          - "$(SRCROOT)/../koe-core/target"
        LIBRARY_SEARCH_PATHS:
          - "$(inherited)"
          - "$(SRCROOT)/../target/aarch64-apple-darwin/release"
          - "$(SRCROOT)/../target/x86_64-apple-darwin/release"
          - "$(SRCROOT)/../target/release"
        OTHER_LDFLAGS:
          - "-lkoe_core"
          - "-lSystem"
          - "-lresolv"
          - "-framework Security"
          - "-framework CoreFoundation"
          - "-framework UserNotifications"
        ENABLE_APP_SANDBOX: NO
    dependencies: []
    preBuildScripts:
      - name: Build Rust Library
        script: |
          if [ "$SKIP_RUST_BUILD" = "1" ]; then
            echo "Skipping Rust build (pre-built in CI)"
            exit 0
          fi
          export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
          cd "${SRCROOT}/.."
          if [ "$ARCHS" = "x86_64" ]; then
            RUST_TARGET="x86_64-apple-darwin"
          else
            RUST_TARGET="aarch64-apple-darwin"
          fi
          cargo build --manifest-path koe-core/Cargo.toml --release --target "$RUST_TARGET"
        basedOnDependencyAnalysis: false
    frameworks:
      - AVFoundation
      - AppKit
      - ApplicationServices
      - Carbon
      - CoreAudio
      - AudioToolbox
      - ServiceManagement
      - UserNotifications
      - SwiftData
```

Key changes from the ObjC version:
- `MACOSX_DEPLOYMENT_TARGET: "15.0"` (was 13.0)
- Added `SWIFT_VERSION: "6.0"`
- Added `SWIFT_OBJC_BRIDGING_HEADER`
- Added `SwiftData` framework
- Removed `libsqlite3.tbd` (SwiftData replaces SQLite)
- Removed `CLANG_ENABLE_OBJC_ARC` (Swift-only)

- [ ] **Step 3: Update Info.plist for macOS 15**

Replace `Info.plist` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Reso</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleDisplayName</key>
	<string>Reso</string>
	<key>CFBundleShortVersionString</key>
	<string>0.3.0</string>
	<key>CFBundleVersion</key>
	<string>3</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Reso needs microphone access to capture your speech for voice input.</string>
	<key>SPUpdateFeedURL</key>
	<string>$(APP_UPDATE_FEED_URL)</string>
</dict>
</plist>
```

Changes: bumped version to 0.3.0/build 3, removed `NSPrincipalClass` (SwiftUI App lifecycle doesn't need it).

- [ ] **Step 4: Commit**

```bash
git add KoeApp/Reso/Reso-Bridging-Header.h KoeApp/project.yml KoeApp/Reso/Info.plist
git commit -m "chore: configure project for Swift 6 / SwiftUI / macOS 15"
```

---

### Task 2: Rust FFI Bridge

**Files:**
- Create: `KoeApp/Reso/Bridge/RustBridge.swift`

The bridge wraps all `sp_core_*` C functions and registers callbacks that dispatch to `AppState` on MainActor.

- [ ] **Step 1: Create RustBridge.swift**

```swift
// KoeApp/Reso/Bridge/RustBridge.swift

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

/// Protocol for receiving Rust core callbacks on MainActor.
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

/// Wraps all sp_core_* FFI calls. Singleton — one Rust core per app.
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

        var context = SPSessionContext(
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

// These are C-compatible callback functions registered with the Rust core.
// They dispatch to the MainActor-isolated delegate via Task.

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
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Bridge/RustBridge.swift
git commit -m "feat: add Swift RustBridge FFI wrapper"
```

---

### Task 3: Permission Manager

**Files:**
- Create: `KoeApp/Reso/Managers/PermissionManager.swift`

- [ ] **Step 1: Create PermissionManager.swift**

```swift
// KoeApp/Reso/Managers/PermissionManager.swift

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
        // Probe by attempting to create a listen-only CGEventTap
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
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Managers/PermissionManager.swift
git commit -m "feat: add PermissionManager for mic, accessibility, input monitoring"
```

---

### Task 4: Audio Device Manager

**Files:**
- Create: `KoeApp/Reso/Managers/AudioDeviceManager.swift`

- [ ] **Step 1: Create AudioDeviceManager.swift**

```swift
// KoeApp/Reso/Managers/AudioDeviceManager.swift

import CoreAudio
import AudioToolbox
import Foundation

// MARK: - Audio Input Device

struct AudioInputDevice: Identifiable, Hashable {
    let id: String          // UID
    let name: String
    let deviceID: AudioDeviceID
}

// MARK: - Audio Device Manager

@MainActor
@Observable
final class AudioDeviceManager {
    var availableDevices: [AudioInputDevice] = []

    private static let selectedUIDKey = "SPSelectedAudioDeviceUID"
    private static let selectedNameKey = "SPSelectedAudioDeviceName"
    private var listenerRegistered = false
    private var onDeviceListChanged: (() -> Void)?

    var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: Self.selectedUIDKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.selectedUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedUIDKey)
                UserDefaults.standard.removeObject(forKey: Self.selectedNameKey)
            }
        }
    }

    var selectedDeviceName: String? {
        UserDefaults.standard.string(forKey: Self.selectedNameKey)
    }

    func selectDevice(uid: String?, name: String?) {
        if let uid {
            UserDefaults.standard.set(uid, forKey: Self.selectedUIDKey)
            UserDefaults.standard.set(name, forKey: Self.selectedNameKey)
        } else {
            selectedDeviceUID = nil
        }
    }

    // MARK: - Enumerate

    func refreshDevices() {
        availableDevices = Self.enumerateInputDevices()
    }

    static func enumerateInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        var result: [AudioInputDevice] = []

        for deviceID in deviceIDs {
            // Skip aggregate devices
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transportType) == noErr {
                if transportType == kAudioDeviceTransportTypeAggregate { continue }
            }

            // Check input channels
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &inputSize) == noErr else { continue }
            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(inputSize))
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddr, 0, nil, &inputSize, bufferListPtr) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get UID
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid) == noErr else { continue }

            // Get name
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr else { continue }

            result.append(AudioInputDevice(
                id: uid as String,
                name: name as String,
                deviceID: deviceID
            ))
        }

        return result.sorted { $0.name < $1.name }
    }

    // MARK: - Resolve Device ID

    func resolvedDeviceID() -> AudioDeviceID {
        guard let uid = selectedDeviceUID else { return kAudioObjectUnknown }
        if let device = availableDevices.first(where: { $0.id == uid }) {
            return device.deviceID
        }
        print("[AudioDeviceManager] selected device \(uid) not found, using system default")
        return kAudioObjectUnknown
    }

    func isSelectedDeviceAvailable() -> Bool {
        guard let uid = selectedDeviceUID else { return true }
        return availableDevices.contains { $0.id == uid }
    }

    // MARK: - Device Change Listening

    func startListening(onChanged: @escaping () -> Void) {
        self.onDeviceListChanged = onChanged
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListCallback,
            selfPtr
        )
        listenerRegistered = true
        refreshDevices()
    }

    func stopListening() {
        guard listenerRegistered else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            deviceListCallback,
            selfPtr
        )
        listenerRegistered = false
    }
}

// C callback for CoreAudio device list changes
private func deviceListCallback(
    _: AudioObjectID,
    _: UInt32,
    _: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let manager = Unmanaged<AudioDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    Task { @MainActor in
        manager.refreshDevices()
        manager.onDeviceListChanged?()
    }
    return noErr
}
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Managers/AudioDeviceManager.swift
git commit -m "feat: add AudioDeviceManager for CoreAudio device enumeration"
```

---

### Task 5: Audio Capture Manager

**Files:**
- Create: `KoeApp/Reso/Managers/AudioCaptureManager.swift`

- [ ] **Step 1: Create AudioCaptureManager.swift**

```swift
// KoeApp/Reso/Managers/AudioCaptureManager.swift

import AVFoundation
import CoreAudio

/// Callback for each 200ms audio frame (6400 bytes, 16kHz mono Int16 LE).
typealias AudioFrameCallback = (_ buffer: UnsafePointer<UInt8>, _ length: UInt32, _ timestamp: UInt64) -> Void

final class AudioCaptureManager: @unchecked Sendable {
    private let targetSampleRate: Double = 16000
    private let frameSamples: Int = 3200  // 200ms at 16kHz
    private let frameBytes: Int = 6400    // 3200 samples × 2 bytes

    private var audioEngine: AVAudioEngine?
    private var audioCallback: AudioFrameCallback?
    private var accumBuffer = Data()
    private var pendingDeviceID: AudioDeviceID = kAudioObjectUnknown

    private(set) var isCapturing = false

    func setInputDeviceID(_ deviceID: AudioDeviceID) {
        pendingDeviceID = deviceID
    }

    func startCapture(callback: @escaping AudioFrameCallback) {
        audioCallback = callback
        accumBuffer.removeAll()

        // Create fresh engine each time to avoid stale device state
        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode

        // Set input device if specified
        if pendingDeviceID != kAudioObjectUnknown {
            let audioUnit = inputNode.audioUnit!
            var deviceID = pendingDeviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            print("[AudioCapture] invalid hardware format")
            return
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("[AudioCapture] failed to create target format")
            return
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            print("[AudioCapture] failed to create converter")
            return
        }

        let sampleRateRatio = targetSampleRate / hwFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let inputFrames = buffer.frameLength
            let outputFrameCount = AVAudioFrameCount(Double(inputFrames) * sampleRateRatio + 1)

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var gotInput = false
            let status = converter.convert(to: convertedBuffer, error: nil) { _, outStatus in
                if gotInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                gotInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, convertedBuffer.frameLength > 0 else { return }

            // Convert Float32 → Int16 LE
            let floatPtr = convertedBuffer.floatChannelData![0]
            let sampleCount = Int(convertedBuffer.frameLength)
            var int16Data = Data(count: sampleCount * 2)

            int16Data.withUnsafeMutableBytes { rawBuffer in
                let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    let sample = max(-1.0, min(1.0, floatPtr[i]))
                    int16Ptr[i] = Int16(sample * 32767.0)
                }
            }

            self.accumBuffer.append(int16Data)

            // Emit full frames
            while self.accumBuffer.count >= self.frameBytes {
                let frame = self.accumBuffer.prefix(self.frameBytes)
                frame.withUnsafeBytes { rawBuffer in
                    let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                    self.audioCallback?(ptr, UInt32(self.frameBytes), 0)
                }
                self.accumBuffer.removeFirst(self.frameBytes)
            }
        }

        do {
            try engine.start()
            isCapturing = true
        } catch {
            print("[AudioCapture] engine start failed: \(error)")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // Flush remaining buffer
        if !accumBuffer.isEmpty {
            accumBuffer.withUnsafeBytes { rawBuffer in
                let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                audioCallback?(ptr, UInt32(accumBuffer.count), 0)
            }
            accumBuffer.removeAll()
        }

        audioCallback = nil
        isCapturing = false
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Managers/AudioCaptureManager.swift
git commit -m "feat: add AudioCaptureManager for 16kHz PCM capture"
```

---

### Task 6: Clipboard & Paste Managers

**Files:**
- Create: `KoeApp/Reso/Managers/ClipboardManager.swift`
- Create: `KoeApp/Reso/Managers/PasteManager.swift`

- [ ] **Step 1: Create ClipboardManager.swift**

```swift
// KoeApp/Reso/Managers/ClipboardManager.swift

import AppKit

final class ClipboardManager: @unchecked Sendable {
    private var backedUpItems: [[NSPasteboard.PasteboardType: Data]] = []
    private var backedUpChangeCount: Int = 0
    private var writtenChangeCount: Int = 0

    func backup() {
        let pb = NSPasteboard.general
        backedUpChangeCount = pb.changeCount
        backedUpItems = []

        guard let items = pb.pasteboardItems else { return }
        for item in items {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            backedUpItems.append(dict)
        }
    }

    func writeText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        writtenChangeCount = pb.changeCount
    }

    func scheduleRestore(afterMs delay: UInt) {
        guard !backedUpItems.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delay))) { [weak self] in
            self?.restoreIfUnchanged()
        }
    }

    private func restoreIfUnchanged() {
        let pb = NSPasteboard.general
        guard pb.changeCount == writtenChangeCount else {
            print("[ClipboardManager] clipboard modified by user, skipping restore")
            return
        }

        pb.clearContents()
        for itemDict in backedUpItems {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
    }
}
```

- [ ] **Step 2: Create PasteManager.swift**

```swift
// KoeApp/Reso/Managers/PasteManager.swift

import Carbon
import ApplicationServices

final class PasteManager: @unchecked Sendable {
    func simulatePaste(completion: @escaping () -> Void) {
        // Wait 50ms for clipboard write to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            self.performPaste()
            // Wait 100ms for paste to take effect
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                completion()
            }
        }
    }

    private func performPaste() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("[PasteManager] failed to create event source")
            return
        }

        // Key code 9 = V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            print("[PasteManager] failed to create key events")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        print("[PasteManager] Cmd+V simulated")
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add KoeApp/Reso/Managers/ClipboardManager.swift KoeApp/Reso/Managers/PasteManager.swift
git commit -m "feat: add ClipboardManager and PasteManager"
```

---

### Task 7: Cue Player

**Files:**
- Create: `KoeApp/Reso/Managers/CuePlayer.swift`

- [ ] **Step 1: Create CuePlayer.swift**

```swift
// KoeApp/Reso/Managers/CuePlayer.swift

import AppKit

final class CuePlayer {
    private var startSoundEnabled = true
    private var stopSoundEnabled = true
    private var errorSoundEnabled = true

    func reloadFeedbackConfig() {
        let config = RustBridge.shared.getFeedbackConfig()
        startSoundEnabled = config.start_sound
        stopSoundEnabled = config.stop_sound
        errorSoundEnabled = config.error_sound
    }

    func playStart() {
        guard startSoundEnabled else { return }
        playSystemSound("Tink")
    }

    func playStop() {
        guard stopSoundEnabled else { return }
        playSystemSound("Pop")
    }

    func playError() {
        guard errorSoundEnabled else { return }
        playSystemSound("Basso")
    }

    private func playSystemSound(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            print("[CuePlayer] system sound '\(name)' not found")
            return
        }
        sound.play()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Managers/CuePlayer.swift
git commit -m "feat: add CuePlayer for audio feedback"
```

---

### Task 8: Hotkey Monitor

**Files:**
- Create: `KoeApp/Reso/Managers/HotkeyMonitor.swift`

- [ ] **Step 1: Create HotkeyMonitor.swift**

```swift
// KoeApp/Reso/Managers/HotkeyMonitor.swift

import AppKit
import Carbon

// MARK: - Hotkey State

private enum HotkeyState {
    case idle
    case pending           // Key pressed, determining tap vs hold
    case recordingHold     // Confirmed hold (long press)
    case recordingToggle   // Toggle mode (tap to start, tap to stop)
    case consumeKeyUp      // Waiting to consume keyUp after toggle-stop
}

// MARK: - Delegate

@MainActor
protocol HotkeyMonitorDelegate: AnyObject {
    func hotkeyMonitorDidDetectHoldStart()
    func hotkeyMonitorDidDetectHoldEnd()
    func hotkeyMonitorDidDetectTapStart()
    func hotkeyMonitorDidDetectTapEnd()
    func hotkeyMonitorDidDetectCancel()
}

// MARK: - HotkeyMonitor

final class HotkeyMonitor: @unchecked Sendable {
    @MainActor weak var delegate: HotkeyMonitorDelegate?

    // Key configuration
    var targetKeyCode: UInt16 = 63       // Fn
    var altKeyCode: UInt16 = 179         // Globe
    var targetModifierFlag: UInt64 = 0x00800000
    var cancelKeyCode: UInt16 = 58       // Left Option
    var cancelAltKeyCode: UInt16 = 0
    var cancelModifierFlag: UInt64 = 0x00000020

    var holdThresholdMs: Int = 180
    var suspended = false {
        didSet {
            if !suspended {
                // Sync state after suspension (may have missed events)
                holdTimer?.invalidate()
                holdTimer = nil
                triggerDown = false
                state = .idle
            }
        }
    }

    private var state: HotkeyState = .idle
    private var holdTimer: Timer?
    private var triggerDown = false
    private var lastSessionEndTime: Date?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let debounceThresholdMs: Int = 500

    // MARK: - Start / Stop

    func start() {
        // NSEvent monitors
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            self?.handleNSEvent(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }

        // CGEventTap as backup
        setupEventTap()

        print("[HotkeyMonitor] started: trigger=\(targetKeyCode)/\(altKeyCode) cancel=\(cancelKeyCode)/\(cancelAltKeyCode)")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        holdTimer?.invalidate()
        holdTimer = nil
        state = .idle
    }

    func resetToIdle() {
        holdTimer?.invalidate()
        holdTimer = nil
        triggerDown = false
        state = .idle
        lastSessionEndTime = Date()
    }

    // MARK: - Event Tap

    private func setupEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: selfPtr
        ) else {
            print("[HotkeyMonitor] CGEventTap creation failed (no input monitoring permission?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - NSEvent Handling

    private func handleNSEvent(_ event: NSEvent) {
        guard !suspended else { return }

        switch event.type {
        case .flagsChanged:
            let keyCode = event.keyCode
            let flags = event.modifierFlags.rawValue

            if isTargetKey(keyCode) {
                let isDown = (flags & UInt(targetModifierFlag)) != 0
                if isDown {
                    handleTriggerDown()
                } else {
                    handleTriggerUp()
                }
            } else if isCancelKey(keyCode) {
                let isDown = (flags & UInt(cancelModifierFlag)) != 0
                if isDown && isRecording {
                    handleCancel(source: "NSEvent")
                }
            }

        case .keyDown:
            let keyCode = event.keyCode
            if isCancelKey(keyCode) && isRecording {
                handleCancel(source: "NSEvent-keyDown")
            } else if isTargetKey(keyCode) {
                handleTriggerDown()
            }

        case .keyUp:
            let keyCode = event.keyCode
            if isTargetKey(keyCode) {
                handleTriggerUp()
            }

        default:
            break
        }
    }

    // MARK: - Key Matching

    private func isTargetKey(_ keyCode: UInt16) -> Bool {
        keyCode == targetKeyCode || (altKeyCode != 0 && keyCode == altKeyCode)
    }

    private func isCancelKey(_ keyCode: UInt16) -> Bool {
        keyCode == cancelKeyCode || (cancelAltKeyCode != 0 && keyCode == cancelAltKeyCode)
    }

    private var isRecording: Bool {
        state == .recordingHold || state == .recordingToggle
    }

    // MARK: - State Machine

    private func handleTriggerDown() {
        switch state {
        case .idle:
            // Debounce check
            if let lastEnd = lastSessionEndTime,
               Date().timeIntervalSince(lastEnd) * 1000 < Double(debounceThresholdMs) {
                return
            }
            state = .pending
            triggerDown = true
            startHoldTimer()

        case .recordingToggle:
            // Second tap ends toggle recording
            state = .consumeKeyUp
            Task { @MainActor [weak self] in
                self?.delegate?.hotkeyMonitorDidDetectTapEnd()
            }

        default:
            break
        }
    }

    private func handleTriggerUp() {
        switch state {
        case .pending:
            // Released before hold timer → tap
            cancelHoldTimer()
            state = .recordingToggle
            triggerDown = false
            Task { @MainActor [weak self] in
                self?.delegate?.hotkeyMonitorDidDetectTapStart()
            }

        case .recordingHold:
            // Hold ended
            state = .idle
            triggerDown = false
            lastSessionEndTime = Date()
            Task { @MainActor [weak self] in
                self?.delegate?.hotkeyMonitorDidDetectHoldEnd()
            }

        case .consumeKeyUp:
            // Final key-up after toggle-stop
            state = .idle
            triggerDown = false
            lastSessionEndTime = Date()

        default:
            break
        }
    }

    private func handleCancel(source: String) {
        guard isRecording else { return }
        print("[HotkeyMonitor] cancel from \(source)")
        resetToIdle()
        Task { @MainActor [weak self] in
            self?.delegate?.hotkeyMonitorDidDetectCancel()
        }
    }

    // MARK: - Hold Timer

    private func startHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Double(holdThresholdMs) / 1000.0, repeats: false) { [weak self] _ in
            self?.holdTimerFired()
        }
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func holdTimerFired() {
        guard state == .pending else { return }
        state = .recordingHold
        Task { @MainActor [weak self] in
            self?.delegate?.hotkeyMonitorDidDetectHoldStart()
        }
    }
}

// MARK: - CGEventTap C Callback

private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable if tap got disabled
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard !monitor.suspended else { return Unmanaged.passUnretained(event) }

    if type == .flagsChanged {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue

        DispatchQueue.main.async {
            if monitor.isTargetKey(keyCode) {
                let isDown = (flags & monitor.targetModifierFlag) != 0
                if isDown {
                    monitor.handleTriggerDown()
                } else {
                    monitor.handleTriggerUp()
                }
            } else if monitor.isCancelKey(keyCode) {
                let isDown = (flags & monitor.cancelModifierFlag) != 0
                if isDown && monitor.isRecording {
                    monitor.handleCancel(source: "CGEventTap")
                }
            }
        }
    }

    return Unmanaged.passUnretained(event)
}

// Make private methods accessible from C callback
extension HotkeyMonitor {
    fileprivate var eventTap: CFMachPort? { self.eventTap }

    fileprivate func isTargetKey(_ keyCode: UInt16) -> Bool {
        keyCode == targetKeyCode || (altKeyCode != 0 && keyCode == altKeyCode)
    }

    fileprivate func isCancelKey(_ keyCode: UInt16) -> Bool {
        keyCode == cancelKeyCode || (cancelAltKeyCode != 0 && keyCode == cancelAltKeyCode)
    }

    fileprivate func handleTriggerDown() { handleTriggerDown() }
    fileprivate func handleTriggerUp() { handleTriggerUp() }
    fileprivate func handleCancel(source: String) { handleCancel(source: source) }
}
```

Wait — the extension at the bottom will cause infinite recursion since the private methods and fileprivate methods have the same name. Let me fix this approach.

Actually the issue is that the C callback needs to access private members. The cleaner approach is to make the methods and properties that the C callback needs `fileprivate` from the start. Let me revise.

- [ ] **Step 1: Create HotkeyMonitor.swift**

The file above should be written with these corrections:
- `isTargetKey`, `isCancelKey`, `isRecording`, `handleTriggerDown`, `handleTriggerUp`, `handleCancel` should all be `fileprivate` instead of `private`
- The `eventTap` stored property should be `fileprivate`
- Remove the extension at the bottom entirely

Replace the access levels in the class body:

```swift
    fileprivate var eventTap: CFMachPort?
    // ... (other properties stay private)

    fileprivate func isTargetKey(_ keyCode: UInt16) -> Bool { ... }
    fileprivate func isCancelKey(_ keyCode: UInt16) -> Bool { ... }
    fileprivate var isRecording: Bool { ... }
    fileprivate func handleTriggerDown() { ... }
    fileprivate func handleTriggerUp() { ... }
    fileprivate func handleCancel(source: String) { ... }
```

And the C callback accesses them directly without the extension wrapper.

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Managers/HotkeyMonitor.swift
git commit -m "feat: add HotkeyMonitor with tap/hold state machine"
```

---

### Task 9: Update Manager

**Files:**
- Create: `KoeApp/Reso/Managers/UpdateManager.swift`

- [ ] **Step 1: Create UpdateManager.swift**

```swift
// KoeApp/Reso/Managers/UpdateManager.swift

import AppKit

@MainActor
final class UpdateManager {
    private let feedURL: URL?
    private let bundle: Bundle
    private var periodicTimer: Timer?
    private var isChecking = false

    private static let lastCheckDateKey = "SPUpdateLastCheckDate"
    private static let skippedVersionKey = "SPUpdateSkippedVersion"
    private static let checkInterval: TimeInterval = 6 * 3600   // 6 hours
    private static let initialDelay: TimeInterval = 8           // 8 seconds

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        if let urlString = bundle.infoDictionary?["SPUpdateFeedURL"] as? String {
            feedURL = URL(string: urlString)
        } else {
            feedURL = nil
        }
    }

    func start() {
        guard feedURL != nil else {
            print("[UpdateManager] no feed URL, auto-update disabled")
            return
        }

        // Initial check after delay
        Timer.scheduledTimer(withTimeInterval: Self.initialDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutomaticCheckIfNeeded()
            }
        }

        // Periodic check
        periodicTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutomaticCheckIfNeeded()
            }
        }
    }

    func checkForUpdatesFromUserAction() {
        checkForUpdates(userInitiated: true)
    }

    // MARK: - Private

    private func performAutomaticCheckIfNeeded() {
        if let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckDateKey) as? Date,
           Date().timeIntervalSince(lastCheck) < Self.checkInterval {
            return
        }
        checkForUpdates(userInitiated: false)
    }

    private func checkForUpdates(userInitiated: Bool) {
        guard let feedURL else {
            if userInitiated { showAlert(title: "Update Check", message: "Update feed URL not configured.") }
            return
        }
        guard !isChecking else {
            if userInitiated { showAlert(title: "Update Check", message: "Already checking for updates.") }
            return
        }

        isChecking = true
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckDateKey)

        Task {
            defer { isChecking = false }
            do {
                let (data, response) = try await URLSession.shared.data(from: feedURL)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    if userInitiated { showAlert(title: "Update Check Failed", message: "Server returned an error.") }
                    return
                }
                handleFeed(data: data, userInitiated: userInitiated)
            } catch {
                print("[UpdateManager] fetch error: \(error)")
                if userInitiated { showAlert(title: "Update Check Failed", message: error.localizedDescription) }
            }
        }
    }

    private func handleFeed(data: Data, userInitiated: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feedVersion = json["version"] as? String,
              let downloadURL = json["download_url"] as? String else {
            if userInitiated { showAlert(title: "Update Check Failed", message: "Invalid feed format.") }
            return
        }

        let feedBuild = (json["build"] as? Int) ?? 0
        let notes = json["notes"] as? String

        // Check minimum system version
        if let minVersion = json["minimum_system_version"] as? String {
            let currentSystem = ProcessInfo.processInfo.operatingSystemVersionString
            if compareVersions(minVersion, currentSystem) == .orderedDescending {
                if userInitiated { showAlert(title: "Update Available", message: "Version \(feedVersion) requires macOS \(minVersion).") }
                return
            }
        }

        let currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let currentBuild = Int(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0

        guard isNewer(feedVersion: feedVersion, feedBuild: feedBuild, currentVersion: currentVersion, currentBuild: currentBuild) else {
            if userInitiated { showAlert(title: "Up to Date", message: "You're running the latest version (\(currentVersion)).") }
            return
        }

        // Check if user skipped this version
        let skipToken = "\(feedVersion):\(feedBuild)"
        if !userInitiated,
           UserDefaults.standard.string(forKey: Self.skippedVersionKey) == skipToken {
            return
        }

        presentUpdateAlert(version: feedVersion, notes: notes, downloadURL: downloadURL, skipToken: skipToken, userInitiated: userInitiated)
    }

    private func presentUpdateAlert(version: String, notes: String?, downloadURL: String, skipToken: String, userInitiated: Bool) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Version \(version) is available." + (notes.map { "\n\n\($0)" } ?? "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if !userInitiated {
            alert.addButton(withTitle: "Skip This Version")
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            if let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(skipToken, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    private func isNewer(feedVersion: String, feedBuild: Int, currentVersion: String, currentBuild: Int) -> Bool {
        let cmp = compareVersions(feedVersion, currentVersion)
        if cmp == .orderedDescending { return true }
        if cmp == .orderedSame && feedBuild > currentBuild { return true }
        return false
    }

    private func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Managers/UpdateManager.swift
git commit -m "feat: add UpdateManager for GitHub release checking"
```

---

### Task 10: SwiftData Session History Model

**Files:**
- Create: `KoeApp/Reso/Models/SessionHistory.swift`

- [ ] **Step 1: Create SessionHistory.swift**

```swift
// KoeApp/Reso/Models/SessionHistory.swift

import Foundation
import SwiftData

@Model
final class SessionHistory {
    var startedAt: Date
    var durationMs: Int
    var text: String
    var characterCount: Int
    var wordCount: Int

    init(durationMs: Int, text: String) {
        self.startedAt = Date()
        self.durationMs = durationMs
        self.text = text
        (self.characterCount, self.wordCount) = Self.countText(text)
    }

    /// Count characters and words, handling CJK and Latin text.
    /// CJK characters each count as 1 char; Latin words are space-separated.
    static func countText(_ text: String) -> (chars: Int, words: Int) {
        var charCount = 0
        var wordCount = 0
        var inWord = false

        for scalar in text.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs + Extension A + Compatibility
            let isCJK = (v >= 0x4E00 && v <= 0x9FFF)
                || (v >= 0x3400 && v <= 0x4DBF)
                || (v >= 0xF900 && v <= 0xFAFF)

            if isCJK {
                charCount += 1
                if inWord { wordCount += 1; inWord = false }
            } else if scalar.properties.isAlphabetic || scalar == "'" || scalar.properties.numericType != nil {
                if !inWord { inWord = true }
                charCount += 1
            } else {
                if inWord { wordCount += 1; inWord = false }
            }
        }
        if inWord { wordCount += 1 }

        return (charCount, wordCount)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Models/SessionHistory.swift
git commit -m "feat: add SwiftData SessionHistory model"
```

---

### Task 11: Overlay Panel (NSPanel + SwiftUI)

**Files:**
- Create: `KoeApp/Reso/Views/OverlayPanel.swift`
- Create: `KoeApp/Reso/Views/OverlayView.swift`

- [ ] **Step 1: Create OverlayView.swift**

```swift
// KoeApp/Reso/Views/OverlayView.swift

import SwiftUI

// MARK: - Overlay Mode

enum OverlayMode {
    case none
    case waveform      // Animated bars (recording)
    case processing    // Bouncing dots
    case success       // Animated checkmark
    case error         // Red X
}

// MARK: - Overlay View

struct OverlayView: View {
    let statusText: String
    let accentColor: Color
    let mode: OverlayMode

    @State private var tick: Int = 0
    @State private var animationTimer: Timer?

    private let pillHeight: CGFloat = 36
    private let pillRadius: CGFloat = 18
    private let iconAreaWidth: CGFloat = 28
    private let iconTextGap: CGFloat = 6
    private let horizontalPad: CGFloat = 14

    var body: some View {
        HStack(spacing: iconTextGap) {
            iconView
                .frame(width: iconAreaWidth, height: pillHeight - 8)

            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, horizontalPad)
        .frame(height: pillHeight)
        .background(
            Capsule()
                .fill(.black.opacity(0.70))
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .onAppear { startAnimation() }
        .onDisappear { stopAnimation() }
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        switch mode {
        case .waveform:
            WaveformIcon(tick: tick, color: accentColor)
        case .processing:
            ProcessingDotsIcon(tick: tick, color: accentColor)
        case .success:
            CheckmarkIcon(tick: tick, color: accentColor)
        case .error:
            CrossIcon(color: accentColor)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Animation

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            tick += 1
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

// MARK: - Waveform

private struct WaveformIcon: View {
    let tick: Int
    let color: Color

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let barMinH: CGFloat = 3
    private let barMaxH: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
            let startX = (size.width - totalWidth) / 2

            for i in 0..<barCount {
                let phase = Double(tick) * 0.06 + Double(i) * 1.1
                let t = (sin(phase) + 1) / 2  // 0...1
                let height = barMinH + (barMaxH - barMinH) * t
                let alpha = 0.55 + 0.45 * t
                let x = startX + CGFloat(i) * (barWidth + barSpacing)
                let y = (size.height - height) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(color.opacity(alpha)))
            }
        }
    }
}

// MARK: - Processing Dots

private struct ProcessingDotsIcon: View {
    let tick: Int
    let color: Color

    private let dotCount = 3
    private let dotBaseRadius: CGFloat = 2.5
    private let dotSpacing: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let totalWidth = CGFloat(dotCount - 1) * dotSpacing
            let startX = (size.width - totalWidth) / 2

            for i in 0..<dotCount {
                let phase = Double(tick) * 0.075 - Double(i) * 1.2
                let t = (sin(phase) + 1) / 2
                let radius = dotBaseRadius + 1.5 * t
                let alpha = 0.4 + 0.6 * t
                let offsetY = -3.0 * t
                let x = startX + CGFloat(i) * dotSpacing
                let y = size.height / 2 + offsetY

                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                let path = Path(ellipseIn: rect)
                context.fill(path, with: .color(color.opacity(alpha)))
            }
        }
    }
}

// MARK: - Checkmark

private struct CheckmarkIcon: View {
    let tick: Int
    let color: Color

    var body: some View {
        Canvas { context, size in
            let progress = min(1.0, Double(tick) / 24.0)  // ~400ms at 60fps
            guard progress > 0 else { return }

            let cx = size.width / 2
            let cy = size.height / 2

            // Checkmark points (relative to center)
            let p1 = CGPoint(x: cx - 6, y: cy)
            let p2 = CGPoint(x: cx - 2, y: cy + 5)
            let p3 = CGPoint(x: cx + 7, y: cy - 5)

            var path = Path()
            path.move(to: p1)

            if progress < 0.4 {
                let t = progress / 0.4
                let x = p1.x + (p2.x - p1.x) * t
                let y = p1.y + (p2.y - p1.y) * t
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: p2)
                let t = (progress - 0.4) / 0.6
                let x = p2.x + (p3.x - p2.x) * t
                let y = p2.y + (p3.y - p2.y) * t
                path.addLine(to: CGPoint(x: x, y: y))
            }

            context.stroke(path, with: .color(color), lineWidth: 2.5)
        }
    }
}

// MARK: - Cross

private struct CrossIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let r: CGFloat = 5

            var path = Path()
            path.move(to: CGPoint(x: cx - r, y: cy - r))
            path.addLine(to: CGPoint(x: cx + r, y: cy + r))
            path.move(to: CGPoint(x: cx + r, y: cy - r))
            path.addLine(to: CGPoint(x: cx - r, y: cy + r))

            context.stroke(path, with: .color(color), lineWidth: 2.5)
        }
    }
}
```

- [ ] **Step 2: Create OverlayPanel.swift**

```swift
// KoeApp/Reso/Views/OverlayPanel.swift

import AppKit
import SwiftUI

@MainActor
final class OverlayPanel {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayView>?
    private(set) var currentState: SessionState = .idle

    private let pillHeight: CGFloat = 36
    private let bottomMargin: CGFloat = 50
    private let maxWidth: CGFloat = 600

    private let fadeInDuration: TimeInterval = 0.2
    private let fadeOutDuration: TimeInterval = 0.5

    init() {
        setupPanel()
    }

    private func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        let overlayView = OverlayView(statusText: "", accentColor: .white, mode: .none)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        self.panel = panel
        self.hostingView = hosting
    }

    func updateState(_ state: SessionState) {
        currentState = state

        let (text, color, mode) = stateConfig(for: state)

        guard mode != .none else {
            hide()
            return
        }

        let overlayView = OverlayView(statusText: text, accentColor: color, mode: mode)
        hostingView?.rootView = overlayView

        resizeAndCenter()
        show()
    }

    // MARK: - State → Display Config

    private func stateConfig(for state: SessionState) -> (String, Color, OverlayMode) {
        switch state {
        case .recordingHold, .recordingToggle:
            return ("Listening…", Color(red: 1, green: 0.32, blue: 0.32), .waveform)
        case .connectingAsr, .finalizingAsr:
            return ("Processing…", Color(red: 0.35, green: 0.78, blue: 1.0), .processing)
        case .preparingPaste, .pasting:
            return ("Copied to clipboard", Color(red: 0.3, green: 0.85, blue: 0.45), .success)
        case .failed:
            return ("Something went wrong", Color(red: 1, green: 0.6, blue: 0.28), .error)
        case .idle, .completed, .cancelled:
            return ("", .clear, .none)
        }
    }

    // MARK: - Layout

    private func resizeAndCenter() {
        guard let panel, let screen = NSScreen.main else { return }

        // Measure text width
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let text = (hostingView?.rootView.statusText) ?? ""
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let desiredWidth = min(maxWidth, 14 + 28 + 6 + textSize.width + 14 + 10)

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - desiredWidth / 2
        let y = screenFrame.minY + bottomMargin

        panel.setFrame(NSRect(x: x, y: y, width: desiredWidth, height: pillHeight), display: true)
    }

    // MARK: - Show / Hide

    private func show() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeInDuration
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeOutDuration
            panel.animator().alphaValue = 0
        }) { [weak self] in
            guard let self, let state = self.currentState as SessionState?,
                  state == .idle || state == .completed || state == .cancelled else { return }
            panel.orderOut(nil)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add KoeApp/Reso/Views/OverlayView.swift KoeApp/Reso/Views/OverlayPanel.swift
git commit -m "feat: add OverlayPanel (NSPanel) + SwiftUI OverlayView"
```

---

### Task 12: AppState (Central Observable State)

**Files:**
- Create: `KoeApp/Reso/State/AppState.swift`

This is the central orchestrator — equivalent to SPAppDelegate's delegate callback implementations.

- [ ] **Step 1: Create AppState.swift**

```swift
// KoeApp/Reso/State/AppState.swift

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
        // Check if API key exists in config
        let configPath = NSHomeDirectory() + "/.koe/config.yaml"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        // Simple check: api_key field has a non-empty value
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api_key:") {
                let value = trimmed.dropFirst("api_key:".count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
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
        // Set up SwiftData
        do {
            modelContainer = try ModelContainer(for: SessionHistory.self)
        } catch {
            print("[AppState] SwiftData init failed: \(error)")
        }

        // Initialize Rust core
        let bridge = RustBridge.shared
        bridge.delegate = self
        bridge.initialize()

        // Audio device listening
        audioDeviceManager.startListening { [weak self] in
            self?.handleDeviceListChanged()
        }

        // Create overlay
        overlayPanel = OverlayPanel()

        // Start update checker
        updateManager.start()

        // Request notification permission
        permissionManager.requestNotificationPermission()

        // Check permissions
        await permissionManager.checkAllPermissions()

        guard permissionManager.microphoneGranted else {
            cuePlayer.playError()
            return
        }

        if !permissionManager.inputMonitoringGranted {
            print("[AppState] input monitoring not granted")
        }

        // Configure and start hotkey monitor
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

        // Get frontmost app info
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleId = frontApp?.bundleIdentifier
        let pid = Int32(frontApp?.processIdentifier ?? 0)

        RustBridge.shared.beginSession(mode: mode, bundleId: bundleId, pid: pid)

        // Start audio capture
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
        // Record history
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
        // Skip terminal states handled by other callbacks
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
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/State/AppState.swift
git commit -m "feat: add AppState as central Observable orchestrator"
```

---

### Task 13: Menu Bar View

**Files:**
- Create: `KoeApp/Reso/Views/MenuBarView.swift`

- [ ] **Step 1: Create MenuBarView.swift**

```swift
// KoeApp/Reso/Views/MenuBarView.swift

import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

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
            // Status header
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            Divider()

            // Mic device picker
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

            // Settings
            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            // Check for updates
            Button("Check for Updates…") {
                appState.updateManager.checkForUpdatesFromUserAction()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            Divider()

            // Launch at login
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }
            ))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            Divider()

            // Quit
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

    private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.activate()
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    // MARK: - Launch at Login

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
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Views/MenuBarView.swift
git commit -m "feat: add MenuBarView for MenuBarExtra content"
```

---

### Task 14: Setup Flow View

**Files:**
- Create: `KoeApp/Reso/Views/SetupFlowView.swift`

- [ ] **Step 1: Create SetupFlowView.swift**

```swift
// KoeApp/Reso/Views/SetupFlowView.swift

import SwiftUI

struct SetupFlowView: View {
    @Environment(AppState.self) private var appState

    @State private var apiKey: String = ""
    @State private var triggerKey: String = "fn"
    @State private var cancelKey: String = "left_option"
    @State private var errorMessage: String?

    private let keyOptions = [
        ("fn", "Fn"),
        ("left_option", "Left Option"),
        ("right_option", "Right Option"),
        ("left_command", "Left Command"),
        ("right_command", "Right Command"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup Required")
                .font(.headline)

            Text("Enter your Gemini API key to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Trigger Key:")
                    .font(.caption)
                Picker("", selection: $triggerKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            HStack {
                Text("Cancel Key:")
                    .font(.caption)
                Picker("", selection: $cancelKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Button("Save & Start") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.isEmpty)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func save() {
        guard triggerKey != cancelKey else {
            errorMessage = "Trigger and cancel keys must be different."
            return
        }

        // Write config.yaml
        let configDir = NSHomeDirectory() + "/.koe"
        let configPath = configDir + "/config.yaml"

        // Read existing or start fresh
        var yaml = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if yaml.isEmpty {
            yaml = """
            asr:
              api_key: ""
              model: "gemini-3.1-flash-live-preview"
              connect_timeout_ms: 5000
              final_wait_timeout_ms: 10000
              system_prompt_path: "system_prompt.txt"

            feedback:
              start_sound: false
              stop_sound: false
              error_sound: false

            appearance:
              hide_menu_icon: false

            hotkey:
              trigger_key: "fn"
              cancel_key: "left_option"

            dictionary:
              path: "dictionary.txt"
            """
        }

        yaml = yamlSet(yaml, key: "api_key", value: apiKey)
        yaml = yamlSet(yaml, key: "trigger_key", value: triggerKey)
        yaml = yamlSet(yaml, key: "cancel_key", value: cancelKey)

        do {
            try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
            appState.reloadConfig()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    /// Simple YAML value replacement for a flat key.
    private func yamlSet(_ yaml: String, key: String, value: String) -> String {
        let pattern = "(\(key):\\s*).*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return yaml }
        let range = NSRange(yaml.startIndex..., in: yaml)
        let quoted = value.contains(" ") || value.contains("#") ? "\"\(value)\"" : "\"\(value)\""
        return regex.stringByReplacingMatches(in: yaml, range: range, withTemplate: "$1\(quoted)")
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Views/SetupFlowView.swift
git commit -m "feat: add SetupFlowView for first-launch inline setup"
```

---

### Task 15: Settings View

**Files:**
- Create: `KoeApp/Reso/Views/SettingsView.swift`

- [ ] **Step 1: Create SettingsView.swift**

```swift
// KoeApp/Reso/Views/SettingsView.swift

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Gemini", systemImage: "sparkle") {
                AsrSettingsTab()
            }
            Tab("Controls", systemImage: "keyboard") {
                HotkeySettingsTab()
            }
            Tab("Dictionary", systemImage: "text.book.closed") {
                DictionarySettingsTab()
            }
            Tab("Prompt", systemImage: "text.bubble") {
                PromptSettingsTab()
            }
        }
        .frame(width: 500, height: 380)
    }
}

// MARK: - ASR Settings

private struct AsrSettingsTab: View {
    @State private var apiKey = ""
    @State private var model = ""
    @State private var showKey = false

    var body: some View {
        Form {
            Section {
                Text("Configure Gemini Live API for speech recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API Key") {
                HStack {
                    if showKey {
                        TextField("API Key", text: $apiKey)
                    } else {
                        SecureField("API Key", text: $apiKey)
                    }
                    Button(showKey ? "Hide" : "Show") {
                        showKey.toggle()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Model") {
                TextField("Model", text: $model)
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { load() }
    }

    private func load() {
        let yaml = readConfig()
        apiKey = yamlRead(yaml, key: "api_key")
        model = yamlRead(yaml, key: "model").isEmpty ? "gemini-3.1-flash-live-preview" : yamlRead(yaml, key: "model")
    }

    private func save() {
        var yaml = readConfig()
        yaml = yamlWrite(yaml, key: "api_key", value: apiKey)
        yaml = yamlWrite(yaml, key: "model", value: model)
        writeConfig(yaml)
        RustBridge.shared.reloadConfig()
    }
}

// MARK: - Hotkey Settings

private struct HotkeySettingsTab: View {
    @State private var triggerKey = "fn"
    @State private var cancelKey = "left_option"
    @State private var hideMenuIcon = false
    @State private var errorMessage: String?

    private let keyOptions = [
        ("fn", "Fn"),
        ("left_option", "Left Option"),
        ("right_option", "Right Option"),
        ("left_command", "Left Command"),
        ("right_command", "Right Command"),
    ]

    var body: some View {
        Form {
            Section {
                Text("Choose trigger and cancel keys for voice input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keys") {
                Picker("Trigger Key", selection: $triggerKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
                Picker("Cancel Key", selection: $cancelKey) {
                    ForEach(keyOptions, id: \.0) { key, label in
                        Text(label).tag(key)
                    }
                }
            }

            Section("Appearance") {
                Toggle("Hide menu bar icon (show Dock icon instead)", isOn: $hideMenuIcon)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { load() }
    }

    private func load() {
        let yaml = readConfig()
        triggerKey = yamlRead(yaml, key: "trigger_key").isEmpty ? "fn" : yamlRead(yaml, key: "trigger_key")
        cancelKey = yamlRead(yaml, key: "cancel_key").isEmpty ? "left_option" : yamlRead(yaml, key: "cancel_key")
        hideMenuIcon = yamlRead(yaml, key: "hide_menu_icon") == "true"
    }

    private func save() {
        guard triggerKey != cancelKey else {
            errorMessage = "Trigger and cancel keys must be different."
            return
        }
        errorMessage = nil

        var yaml = readConfig()
        yaml = yamlWrite(yaml, key: "trigger_key", value: triggerKey)
        yaml = yamlWrite(yaml, key: "cancel_key", value: cancelKey)
        yaml = yamlWrite(yaml, key: "hide_menu_icon", value: hideMenuIcon ? "true" : "false")
        writeConfig(yaml)
        RustBridge.shared.reloadConfig()
    }
}

// MARK: - Dictionary Settings

private struct DictionarySettingsTab: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("User dictionary — one term per line. These terms help improve recognition accuracy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .onAppear { load() }
    }

    private func load() {
        let path = NSHomeDirectory() + "/.koe/dictionary.txt"
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func save() {
        let path = NSHomeDirectory() + "/.koe/dictionary.txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - System Prompt Settings

private struct PromptSettingsTab: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System prompt sent to Gemini for speech recognition and correction.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
        .onAppear { load() }
    }

    private func load() {
        let path = NSHomeDirectory() + "/.koe/system_prompt.txt"
        text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    private func save() {
        let path = NSHomeDirectory() + "/.koe/system_prompt.txt"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        RustBridge.shared.reloadConfig()
    }
}

// MARK: - YAML Helpers

private func configPath() -> String {
    NSHomeDirectory() + "/.koe/config.yaml"
}

private func readConfig() -> String {
    (try? String(contentsOfFile: configPath(), encoding: .utf8)) ?? ""
}

private func writeConfig(_ yaml: String) {
    try? yaml.write(toFile: configPath(), atomically: true, encoding: .utf8)
}

/// Simple YAML key-value reader (flat, finds first match).
private func yamlRead(_ yaml: String, key: String) -> String {
    for line in yaml.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\(key):") {
            let value = trimmed.dropFirst("\(key):".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value
        }
    }
    return ""
}

/// Simple YAML key-value writer (replaces first match in-place).
private func yamlWrite(_ yaml: String, key: String, value: String) -> String {
    let lines = yaml.components(separatedBy: "\n")
    var result: [String] = []
    var replaced = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !replaced && trimmed.hasPrefix("\(key):") {
            // Preserve indentation
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            let needsQuotes = value.contains(" ") || value.contains("#") || value.contains("$")
            let formatted = needsQuotes ? "\"\(value)\"" : value
            result.append("\(indent)\(key): \(formatted)")
            replaced = true
        } else {
            result.append(line)
        }
    }
    return result.joined(separator: "\n")
}
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/Views/SettingsView.swift
git commit -m "feat: add SettingsView with 4 tabs (Gemini, Controls, Dictionary, Prompt)"
```

---

### Task 16: App Entry Point (ResoApp.swift)

**Files:**
- Create: `KoeApp/Reso/ResoApp.swift`

- [ ] **Step 1: Create ResoApp.swift**

```swift
// KoeApp/Reso/ResoApp.swift

import SwiftUI
import SwiftData

@main
struct ResoApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Reso", systemImage: "waveform") {
            MenuBarView()
                .environment(appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }

    init() {
        // Install Edit menu for text fields (Cmd+C/V/X/A)
        installEditMenu()
    }

    private func installEditMenu() {
        DispatchQueue.main.async {
            guard let mainMenu = NSApp.mainMenu else {
                NSApp.mainMenu = NSMenu()
                return
            }

            // Only add if not already present
            if mainMenu.item(withTitle: "Edit") != nil { return }

            let editMenu = NSMenu(title: "Edit")
            editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            editMenu.addItem(.separator())
            editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

            let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            editMenuItem.submenu = editMenu
            mainMenu.addItem(editMenuItem)
        }
    }
}

// MARK: - App Lifecycle via NSApplicationDelegate

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState else { return }
        Task { @MainActor in
            await appState.initialize()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            appState?.shutdown()
        }
    }
}
```

Wait — in SwiftUI's App lifecycle, there's no direct `applicationDidFinishLaunching`. We need to trigger initialization differently. The cleanest approach is to use `.task` on the menu bar content view, or use `@NSApplicationDelegateAdaptor`.

Let me revise:

```swift
// KoeApp/Reso/ResoApp.swift

import SwiftUI
import SwiftData

@main
struct ResoApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Reso", systemImage: "waveform") {
            MenuBarView()
                .environment(appState)
                .task {
                    guard !appState.initialized else { return }
                    appState.initialized = true
                    installEditMenu()
                    await appState.initialize()
                }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }

    private func installEditMenu() {
        guard let mainMenu = NSApp.mainMenu else {
            NSApp.mainMenu = NSMenu()
            return
        }
        if mainMenu.item(withTitle: "Edit") != nil { return }

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
    }
}

// MARK: - Lifecycle

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup handled by AppState.shutdown() in MenuBarView quit action
    }
}
```

This also requires adding an `initialized` property to `AppState`. Add to `AppState.swift`:

```swift
var initialized = false
```

- [ ] **Step 2: Commit**

```bash
git add KoeApp/Reso/ResoApp.swift
git commit -m "feat: add ResoApp @main entry point with MenuBarExtra + Settings"
```

---

### Task 17: Delete ObjC Files & Clean Up

**Files:**
- Delete: All `KoeApp/Reso/SP*.h`, `KoeApp/Reso/SP*.m`, `KoeApp/Reso/Bridge/SP*.h`, `KoeApp/Reso/Bridge/SP*.m`, `KoeApp/Reso/main.m`
- Delete: Old directory structure files

- [ ] **Step 1: Delete all Objective-C source files**

```bash
cd /Users/yikzero/conductor/workspaces/koe/tirana
# Delete all ObjC implementation and header files
find KoeApp/Reso -name "SP*.h" -o -name "SP*.m" | xargs rm -f
rm -f KoeApp/Reso/main.m
```

- [ ] **Step 2: Verify no ObjC files remain**

```bash
find KoeApp/Reso -name "*.m" -o -name "*.h" | grep -v Bridging-Header
```

Expected: no output (only Reso-Bridging-Header.h should remain, which is filtered out).

- [ ] **Step 3: Commit**

```bash
git add -A KoeApp/Reso/
git commit -m "chore: remove all Objective-C source files"
```

---

### Task 18: Build & Fix Compilation Errors

This task handles building the project and fixing any Swift 6 compilation issues.

- [ ] **Step 1: Generate Xcode project and build Rust**

```bash
cd /Users/yikzero/conductor/workspaces/koe/tirana
make generate && make build-rust
```

Expected: XcodeGen generates project successfully, Rust compiles.

- [ ] **Step 2: Build Xcode project**

```bash
cd /Users/yikzero/conductor/workspaces/koe/tirana
make build-xcode 2>&1 | tail -50
```

Expected: compilation errors may occur — fix them iteratively.

- [ ] **Step 3: Fix any Swift 6 strict concurrency issues**

Common fixes needed:
- Add `@Sendable` to closures passed across actor boundaries
- Add `nonisolated` to properties/methods that don't need MainActor
- Use `sending` parameter annotations where needed
- Mark C interop types with `@unchecked Sendable` if needed

Fix each error, rebuild, repeat until clean.

- [ ] **Step 4: Fix any FFI type mismatches**

The bridging header imports `koe_core.h`. If Swift sees different types than expected (e.g., `SPSessionMode` as a struct vs enum), adjust `RustBridge.swift` to match the actual generated C types.

Check: `cat koe-core/target/koe_core.h` to see exact generated types after building Rust.

- [ ] **Step 5: Verify successful build**

```bash
make build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit fixes**

```bash
git add -A KoeApp/Reso/
git commit -m "fix: resolve Swift 6 compilation and FFI type issues"
```

---

### Task 19: Integration Test — Install & Run

- [ ] **Step 1: Install and launch**

```bash
make install
```

Expected: app builds, installs to /Applications, launches. Menu bar icon appears.

- [ ] **Step 2: Verify core functionality**

Manual verification checklist:
- Menu bar icon (waveform) appears
- Clicking icon shows menu/setup flow
- Settings window opens via menu
- Hotkey detection works (Fn press/release)
- Recording starts (overlay appears with waveform animation)
- Audio is captured and sent to Gemini
- Final text is pasted
- Overlay shows correct state transitions

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat: complete Swift/SwiftUI rewrite of Reso frontend"
```
