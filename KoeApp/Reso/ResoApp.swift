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

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup handled by AppState.shutdown() in MenuBarView quit action
    }
}
