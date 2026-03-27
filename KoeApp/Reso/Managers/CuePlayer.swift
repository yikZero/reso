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
