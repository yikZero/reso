import AppKit

final class CuePlayer {
    private let startSound = NSSound(named: "Tink")
    private let stopSound = NSSound(named: "Pop")
    private let errorSound = NSSound(named: "Basso")

    func playStart() {
        guard RustBridge.shared.getFeedbackConfig().start_sound else { return }
        startSound?.play()
    }

    func playStop() {
        guard RustBridge.shared.getFeedbackConfig().stop_sound else { return }
        stopSound?.play()
    }

    func playError() {
        guard RustBridge.shared.getFeedbackConfig().error_sound else { return }
        errorSound?.play()
    }
}
