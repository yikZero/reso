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
