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

    private func resizeAndCenter() {
        guard let panel, let screen = NSScreen.main else { return }

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let text = (hostingView?.rootView.statusText) ?? ""
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let desiredWidth = min(maxWidth, 14 + 28 + 6 + textSize.width + 14 + 10)

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - desiredWidth / 2
        let y = screenFrame.minY + bottomMargin

        panel.setFrame(NSRect(x: x, y: y, width: desiredWidth, height: pillHeight), display: true)
    }

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
            guard let self, self.currentState == .idle || self.currentState == .completed || self.currentState == .cancelled else { return }
            panel.orderOut(nil)
        }
    }
}
