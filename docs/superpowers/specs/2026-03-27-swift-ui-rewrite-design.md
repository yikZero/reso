# Swift/SwiftUI Full Rewrite Design

## Overview

Rewrite the entire Objective-C UI layer of Reso (macOS voice input tool) to Swift 6 / SwiftUI, targeting macOS 15+. The Rust backend (`koe-core`, `koe-asr`) remains unchanged. No backward compatibility required — clean slate.

## Target

- macOS 15+ (Sequoia)
- Swift 6
- SwiftUI App lifecycle
- SwiftData for persistence

## App Structure

```
ResoApp (@main)
├── MenuBarExtra (menu bar icon + popover)
│   ├── Inline setup flow (first launch)
│   ├── Status display
│   ├── Mic device selector
│   └── Quit / Settings links
├── Settings (SwiftUI Settings scene)
│   ├── API key config
│   ├── Hotkey config
│   └── Feedback sounds config
└── OverlayPanel (NSPanel + NSHostingView)
    └── OverlayView (SwiftUI: interim text, state indicators)
```

Central state: one `@Observable` class `AppState` holds session state, interim text, permission statuses, and current config. All views bind to this single source of truth.

## File Structure

```
KoeApp/Reso/
├── ResoApp.swift              # @main, MenuBarExtra + Settings scenes
├── State/
│   └── AppState.swift         # @Observable central state
├── Bridge/
│   └── RustBridge.swift       # sp_core_* FFI wrapper + C callbacks
├── Managers/
│   ├── HotkeyMonitor.swift    # CGEventTap + NSEvent global monitor
│   ├── AudioCaptureManager.swift
│   ├── AudioDeviceManager.swift
│   ├── PermissionManager.swift
│   ├── ClipboardManager.swift
│   ├── PasteManager.swift
│   ├── CuePlayer.swift
│   └── UpdateManager.swift
├── Views/
│   ├── MenuBarView.swift      # MenuBarExtra content
│   ├── SetupFlowView.swift    # Inline first-launch setup
│   ├── SettingsView.swift     # Settings window content
│   ├── OverlayView.swift      # Floating overlay SwiftUI content
│   └── OverlayPanel.swift     # NSPanel subclass + NSHostingView host
├── Models/
│   └── SessionHistory.swift   # SwiftData @Model for history stats
├── Resources/
│   ├── Assets.xcassets
│   ├── start.caf / stop.caf / error.caf
│   └── Info.plist
└── Reso-Bridging-Header.h     # #import "koe_core.h"
```

All existing `SP*.h`, `SP*.m`, and `main.m` files are deleted.

## Rust FFI Bridge

`RustBridge.swift` is the single point of contact with the Rust core.

### Wrapped functions

- `create(configPath:)`, `destroy()`
- `registerCallbacks()`, `reloadConfig()`
- `sessionBegin(mode:)`, `pushAudio(frame:length:timestamp:)`, `sessionEnd()`, `sessionCancel()`
- `getHotkeyConfig()`, `getFeedbackConfig()`

### Callback pattern

C function pointers receive an opaque context pointer (`UnsafeMutableRawPointer`) pointing to `AppState`. Each callback converts the pointer via `Unmanaged<AppState>.fromOpaque()` and dispatches UI updates on `@MainActor` via `Task { @MainActor in ... }`.

Callbacks: `on_session_ready`, `on_interim_text`, `on_final_text_ready`, `on_state_changed`, `on_session_error`, `on_session_warning`, `on_log_event`.

Views never call `sp_core_*` directly — all interaction goes through `AppState` methods that delegate to `RustBridge`.

## Component Details

### HotkeyMonitor

5-state machine: Idle → Pending → RecordingHold / RecordingToggle → ConsumeKeyUp.

- `CGEvent.tapCreate()` for flagsChanged events
- `NSEvent.addGlobalMonitorForEvents()` as fallback
- 180ms `DispatchSourceTimer` to distinguish tap from hold
- Reports events via closure callbacks to `AppState`

### AudioCaptureManager

- `AVAudioEngine` with input node tap at hardware sample rate
- `AVAudioConverter` resamples to 16kHz mono PCM Int16 LE
- Accumulates into 200ms frames (3200 samples = 6400 bytes)
- Calls `RustBridge.pushAudio()` per frame

### AudioDeviceManager

- Core Audio `AudioObjectGetPropertyData` to enumerate input devices
- Exposes device list for mic selector in MenuBarView
- Sets selected device on `AVAudioEngine`

### OverlayPanel

`NSPanel` subclass:
- `styleMask: [.borderless, .nonactivatingPanel]`
- `level: .floating`
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`
- `ignoresMouseEvents: true`
- Hosts `OverlayView` via `NSHostingView`
- Positioned bottom-center of main screen
- Show/hide driven by `AppState.sessionState`

### PermissionManager

Checks three permissions, exposes `@Observable` states:
- Microphone: `AVCaptureDevice.authorizationStatus(for: .audio)`
- Accessibility: `AXIsProcessTrusted()`
- Input Monitoring: trial `CGEvent.tapCreate()` creation

### ClipboardManager / PasteManager

- `ClipboardManager`: backs up `NSPasteboard.general`, writes text, schedules restore
- `PasteManager`: simulates Cmd+V via `CGEvent` injection

### CuePlayer

- `AVAudioPlayer` for start/stop/error sound cues
- Reads feedback config from Rust core via `RustBridge.getFeedbackConfig()`

### UpdateManager

- Fetches latest release from GitHub API
- Compares with current bundle version
- Shows update prompt in menu bar

### SwiftData History

```swift
@Model
class SessionHistory {
    var startedAt: Date
    var duration: TimeInterval
    var characterCount: Int
    var wordCount: Int
}
```

Inserted at session completion. Old SQLite `history.db` is abandoned (no migration needed).

## UI Flows

### First Launch

1. App launches → `MenuBarExtra` appears in menu bar
2. No API key detected → `MenuBarView` shows inline `SetupFlowView`
3. User enters API key, selects hotkey, configures sounds
4. Config saved via `RustBridge.reloadConfig()`
5. Normal operation begins

### Recording Session

1. User presses hotkey → `HotkeyMonitor` detects → `AppState.startSession()`
2. `RustBridge.sessionBegin()` called → Rust connects to Gemini
3. `AudioCaptureManager.start()` → audio frames pushed via `RustBridge.pushAudio()`
4. Interim text callbacks update `AppState.interimText` → `OverlayView` shows live text
5. User releases hotkey → `AppState.endSession()` → `RustBridge.sessionEnd()`
6. Final text callback → `ClipboardManager` writes text → `PasteManager` simulates Cmd+V
7. Overlay shows completion briefly, then hides

## Build System

`project.yml` changes:
- Source glob: `Reso/**/*.swift` (replace `Reso/**/*.m`)
- Add `Reso/Reso-Bridging-Header.h` as `SWIFT_OBJC_BRIDGING_HEADER`
- Set `SWIFT_VERSION: "6"`
- Set `MACOSX_DEPLOYMENT_TARGET: "15.0"`
- Keep Rust library linking, header search paths, frameworks unchanged
- Add SwiftData framework to linked frameworks

`Makefile` unchanged — `xcodegen` + `cargo build` + `xcodebuild` pipeline stays the same.
