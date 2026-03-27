import Carbon
import ApplicationServices

final class PasteManager: @unchecked Sendable {
    func simulatePaste(completion: @escaping @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            self.performPaste()
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
