import AppKit
import Foundation

/// Checks GitHub Releases API for app updates, downloads and installs.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isChecking = false

    // Download state
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var downloadComplete = false
    @Published var downloadedFileURL: URL?

    // UI state
    @Published var showUpdateDialog = false

    static let shared = UpdateChecker()

    let repoOwner = "lifedever"
    let repoName = "TaskTick"

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private init() {}

    struct GitHubRelease: Codable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let assets: [Asset]?

        struct Asset: Codable {
            let name: String
            let browser_download_url: String
            let size: Int?
        }
    }

    func checkForUpdates(userInitiated: Bool = false) async {
        isChecking = true

        do {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                isChecking = false
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remoteVersion = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

            latestVersion = remoteVersion
            releaseNotes = release.body

            // Find the correct DMG for current architecture
            let arch = currentArch()
            if let dmgAsset = release.assets?.first(where: { $0.name.contains(arch) && $0.name.hasSuffix(".dmg") }) {
                downloadURL = URL(string: dmgAsset.browser_download_url)
                totalBytes = Int64(dmgAsset.size ?? 0)
            } else if let dmgAsset = release.assets?.first(where: { $0.name.hasSuffix(".dmg") }) {
                downloadURL = URL(string: dmgAsset.browser_download_url)
                totalBytes = Int64(dmgAsset.size ?? 0)
            } else {
                downloadURL = URL(string: release.html_url)
            }

            // Skip if user has skipped this version
            let skippedVersion = UserDefaults.standard.string(forKey: "skippedVersion")
            if !userInitiated && remoteVersion == skippedVersion {
                updateAvailable = false
            } else {
                updateAvailable = isNewer(remote: remoteVersion, current: currentVersion)
            }

            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")

            if updateAvailable {
                showUpdateDialog = true
            } else if userInitiated {
                // Show "up to date" alert
                showUpToDateAlert()
            }
        } catch {
            // Silently fail
        }

        isChecking = false
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        updateAvailable = false
        showUpdateDialog = false
    }

    func downloadUpdate() {
        guard let url = downloadURL else { return }

        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        downloadComplete = false

        let delegate = DownloadDelegate { [weak self] progress, received, total in
            Task { @MainActor in
                self?.downloadProgress = progress
                self?.downloadedBytes = received
                self?.totalBytes = total
            }
        } onComplete: { [weak self] fileURL in
            Task { @MainActor in
                self?.downloadComplete = true
                self?.downloadedFileURL = fileURL
                self?.isDownloading = false
            }
        }
        self.downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadComplete = false
    }

    func installAndRestart() {
        guard let fileURL = downloadedFileURL else { return }

        let destApp = Bundle.main.bundlePath
        let dmgPath = fileURL.path

        // Use a single shell script to handle the entire update process
        // This avoids Swift-side hdiutil output parsing issues
        let script = """
        #!/bin/bash
        DMG_PATH="\(dmgPath)"
        DEST_APP="\(destApp)"
        APP_NAME="TaskTick"

        # Mount DMG and capture mount point
        MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse -noverify 2>/dev/null | grep -o '/Volumes/[^\t]*' | head -1)

        if [ -z "$MOUNT_POINT" ]; then
            open "$DMG_PATH"
            exit 1
        fi

        SOURCE_APP="$MOUNT_POINT/$APP_NAME.app"

        if [ ! -d "$SOURCE_APP" ]; then
            hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
            open "$DMG_PATH"
            exit 1
        fi

        # Wait for the app to quit
        sleep 2

        # Replace and relaunch
        rm -rf "$DEST_APP"
        cp -R "$SOURCE_APP" "$DEST_APP"
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
        open "$DEST_APP"
        rm -f "$0"
        """

        do {
            let scriptPath = NSTemporaryDirectory() + "tasktick_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()

            // Quit immediately so the script can replace the app
            NSApp.terminate(nil)
        } catch {
            NSWorkspace.shared.open(fileURL)
        }
    }

    // MARK: - Private

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func isNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.no_updates")
        alert.informativeText = L10n.tr("update.no_updates.message", currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func startPeriodicChecks() {
        let interval = UserDefaults.standard.integer(forKey: "updateCheckInterval")
        let hours = interval > 0 ? interval : 24

        Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { _ in
            Task { @MainActor in
                guard UserDefaults.standard.bool(forKey: "autoCheckUpdates") else { return }
                await UpdateChecker.shared.checkForUpdates()
            }
        }
    }
}

// MARK: - Download Delegate

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double, Int64, Int64) -> Void
    let onComplete: @Sendable (URL) -> Void

    init(
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (URL) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move to a persistent temp location
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("TaskTick-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
        onComplete(dest)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 1
        let progress = Double(totalBytesWritten) / Double(total)
        onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }
}
