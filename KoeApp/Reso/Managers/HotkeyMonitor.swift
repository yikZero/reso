import AppKit
import Carbon

// MARK: - Hotkey State

private enum HotkeyState {
    case idle
    case pending
    case recordingHold
    case recordingToggle
    case consumeKeyUp
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
    var targetKeyCode: UInt16 = 63
    var altKeyCode: UInt16 = 179
    var targetModifierFlag: UInt64 = 0x00800000
    var cancelKeyCode: UInt16 = 58
    var cancelAltKeyCode: UInt16 = 0
    var cancelModifierFlag: UInt64 = 0x00000020

    var holdThresholdMs: Int = 180
    var suspended = false {
        didSet {
            if !suspended {
                holdTimer?.invalidate()
                holdTimer = nil
                triggerDown = false
                state = .idle
            }
        }
    }

    fileprivate var state: HotkeyState = .idle
    fileprivate var holdTimer: Timer?
    fileprivate var triggerDown = false
    fileprivate var lastSessionEndTime: Date?
    fileprivate var eventTap: CFMachPort?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var runLoopSource: CFRunLoopSource?

    fileprivate let debounceThresholdMs: Int = 500

    // MARK: - Start / Stop

    func start() {
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

    fileprivate func isTargetKey(_ keyCode: UInt16) -> Bool {
        keyCode == targetKeyCode || (altKeyCode != 0 && keyCode == altKeyCode)
    }

    fileprivate func isCancelKey(_ keyCode: UInt16) -> Bool {
        keyCode == cancelKeyCode || (cancelAltKeyCode != 0 && keyCode == cancelAltKeyCode)
    }

    fileprivate var isRecording: Bool {
        state == .recordingHold || state == .recordingToggle
    }

    // MARK: - State Machine

    fileprivate func handleTriggerDown() {
        switch state {
        case .idle:
            if let lastEnd = lastSessionEndTime,
               Date().timeIntervalSince(lastEnd) * 1000 < Double(debounceThresholdMs) {
                return
            }
            state = .pending
            triggerDown = true
            startHoldTimer()

        case .recordingToggle:
            state = .consumeKeyUp
            Task { @MainActor [weak self] in
                self?.delegate?.hotkeyMonitorDidDetectTapEnd()
            }

        default:
            break
        }
    }

    fileprivate func handleTriggerUp() {
        switch state {
        case .pending:
            cancelHoldTimer()
            state = .recordingToggle
            triggerDown = false
            Task { @MainActor [weak self] in
                self?.delegate?.hotkeyMonitorDidDetectTapStart()
            }

        case .recordingHold:
            state = .idle
            triggerDown = false
            lastSessionEndTime = Date()
            Task { @MainActor [weak self] in
                self?.delegate?.hotkeyMonitorDidDetectHoldEnd()
            }

        case .consumeKeyUp:
            state = .idle
            triggerDown = false
            lastSessionEndTime = Date()

        default:
            break
        }
    }

    fileprivate func handleCancel(source: String) {
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
    } else if type == .keyDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        DispatchQueue.main.async {
            if monitor.isCancelKey(keyCode) && monitor.isRecording {
                monitor.handleCancel(source: "CGEventTap-keyDown")
            } else if monitor.isTargetKey(keyCode) {
                monitor.handleTriggerDown()
            }
        }
    } else if type == .keyUp {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        DispatchQueue.main.async {
            if monitor.isTargetKey(keyCode) {
                monitor.handleTriggerUp()
            }
        }
    }

    return Unmanaged.passUnretained(event)
}
