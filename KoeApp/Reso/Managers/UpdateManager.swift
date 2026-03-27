import AppKit

@MainActor
final class UpdateManager {
    private let feedURL: URL?
    private let bundle: Bundle
    private var periodicTimer: Timer?
    private var isChecking = false

    private static let lastCheckDateKey = "SPUpdateLastCheckDate"
    private static let skippedVersionKey = "SPUpdateSkippedVersion"
    private static let checkInterval: TimeInterval = 6 * 3600
    private static let initialDelay: TimeInterval = 8

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

        Timer.scheduledTimer(withTimeInterval: Self.initialDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutomaticCheckIfNeeded()
            }
        }

        periodicTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutomaticCheckIfNeeded()
            }
        }
    }

    func checkForUpdatesFromUserAction() {
        checkForUpdates(userInitiated: true)
    }

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

        let skipToken = "\(feedVersion):\(feedBuild)"
        if !userInitiated,
           UserDefaults.standard.string(forKey: Self.skippedVersionKey) == skipToken {
            return
        }

        presentUpdateAlert(version: feedVersion, notes: notes, downloadURL: downloadURL, skipToken: skipToken, userInitiated: userInitiated)
    }

    // MARK: - Presentation

    private func presentUpdateAlert(version: String, notes: String?, downloadURL: String, skipToken: String, userInitiated: Bool) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Version \(version) is available." + (notes.map { "\n\n\($0)" } ?? "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        if !userInitiated {
            alert.addButton(withTitle: "Skip This Version")
        }

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            downloadAndInstall(from: downloadURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(skipToken, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    // MARK: - Download & Install

    private func downloadAndInstall(from urlString: String) {
        guard let url = URL(string: urlString) else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Updating Reso"
        panel.center()
        panel.level = .floating

        let label = NSTextField(labelWithString: "Downloading update…")
        label.frame = NSRect(x: 20, y: 48, width: 260, height: 17)
        label.font = .systemFont(ofSize: 13)

        let progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 20, width: 260, height: 20))
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)

        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(progressBar)
        panel.makeKeyAndOrderFront(nil)

        let appBundleURL = bundle.bundleURL

        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let dmgURL = FileManager.default.temporaryDirectory.appendingPathComponent("Reso-update.dmg")
                let fm = FileManager.default
                try? fm.removeItem(at: dmgURL)
                try fm.moveItem(at: tempURL, to: dmgURL)

                label.stringValue = "Installing update…"

                try await Task.detached {
                    try Self.installFromDMG(at: dmgURL, replacingAppAt: appBundleURL)
                }.value

                panel.close()
                relaunchApp()
            } catch {
                panel.close()
                let alert = NSAlert()
                alert.messageText = "Update Failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Download in Browser")
                if alert.runModal() == .alertSecondButtonReturn,
                   let fallbackURL = URL(string: urlString) {
                    NSWorkspace.shared.open(fallbackURL)
                }
            }
        }
    }

    nonisolated private static func installFromDMG(at dmgPath: URL, replacingAppAt appURL: URL) throws {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("reso-update-mount").path
        let fm = FileManager.default

        // Clean up any leftover mount from a previous attempt
        try? runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet", "-force"])
        try? fm.removeItem(atPath: mountPoint)

        // Mount DMG
        try runProcess("/usr/bin/hdiutil", ["attach", dmgPath.path, "-nobrowse", "-quiet", "-mountpoint", mountPoint])

        defer {
            try? runProcess("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
            try? fm.removeItem(at: dmgPath)
        }

        // Find .app in mounted volume
        let items = try fm.contentsOfDirectory(atPath: mountPoint)
        guard let appName = items.first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(domain: "UpdateManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No application found in the disk image."])
        }

        let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

        // Safe replace: backup old app, copy new, restore on failure
        let backupURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(".\(appURL.lastPathComponent).update-backup")
        try? fm.removeItem(at: backupURL)
        try fm.moveItem(at: appURL, to: backupURL)
        do {
            try fm.copyItem(at: sourceApp, to: appURL)
            // Remove quarantine so Gatekeeper doesn't block the replaced app
            try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
            try? fm.removeItem(at: backupURL)
        } catch {
            // Restore from backup
            try? fm.moveItem(at: backupURL, to: appURL)
            throw error
        }
    }

    private func relaunchApp() {
        let appPath = bundle.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1 && open \"\(appPath)\""]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    nonisolated private static func runProcess(_ executablePath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UpdateManager", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executablePath) exited with status \(process.terminationStatus)"])
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
