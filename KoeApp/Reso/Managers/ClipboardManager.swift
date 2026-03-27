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
