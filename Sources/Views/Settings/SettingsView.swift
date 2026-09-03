import SwiftUI
import SwiftData
import ServiceManagement
import TaskTickCore

struct SettingsView: View {
    // General
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @ObservedObject private var quickLauncherSettings = QuickLauncherSettings.shared
    @AppStorage("defaultShell") private var defaultShell = "/bin/zsh"
    @AppStorage("defaultTimeout") private var defaultTimeout = 300
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    // Notifications
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true

    // Logs
    @AppStorage(ExecutionLogRetentionPolicy.automaticCleanupKey)
    private var automaticLogCleanup = ExecutionLogRetentionPolicy.defaultAutomaticCleanup
    @AppStorage(ExecutionLogRetentionPolicy.retentionDaysKey)
    private var logRetentionDays = ExecutionLogRetentionPolicy.defaultRetentionDays
    @AppStorage(ExecutionLogRetentionPolicy.maximumLogsPerTaskKey)
    private var maximumLogsPerTask = ExecutionLogRetentionPolicy.defaultMaximumLogsPerTask
    @AppStorage("logs.streamManualToFile") private var streamManualToFile = true

    // Updates
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("updateCheckInterval") private var updateCheckInterval = 24

    @StateObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var languageManager = LanguageManager.shared

    @StateObject private var backupManager = DatabaseBackup.shared
    @State private var backupToRestore: DatabaseBackup.BackupEntry?
    @State private var showRestoreConfirm = false
    @State private var showRestoreResult = false
    @State private var restoreSuccess = false
    @State private var restoreErrorMessage: String?
    @State private var isRestoring = false
    @State private var showBackupList = false
    @State private var backupToDelete: DatabaseBackup.BackupEntry?
    @State private var showDeleteConfirm = false
    @State private var showBackupSuccess = false

    // Log cleanup
    @State private var showCleanupConfirm = false
    @State private var showCleanupResult = false
    @State private var cleanupDeletedCount = 0
    @State private var isCleaningLogs = false

    /// The tab bar, as data. Both the `tabItem` labels and the window width
    /// below read from here — a width computed from a second, hand-copied list
    /// of titles would drift the first time a tab is added or renamed.
    enum Tab: String, CaseIterable {
        case general = "settings.general"
        case quickLauncher = "quick_launcher.settings.section"
        case cli = "settings.cli.section.title"
        case notifications = "settings.notifications"
        case backup = "settings.backup"
        case logs = "settings.logs"
        case updates = "settings.updates"
        case about = "settings.about"

        var title: String { L10n.tr(rawValue) }

        var symbol: String {
            switch self {
            case .general: return "gear"
            case .quickLauncher: return "command"
            case .cli: return "terminal"
            case .notifications: return "bell"
            case .backup: return "externaldrive.badge.timemachine"
            case .logs: return "doc.text"
            case .updates: return "arrow.triangle.2.circlepath"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(Tab.general.title, systemImage: Tab.general.symbol) }

            quickLauncherTab
                .tabItem { Label(Tab.quickLauncher.title, systemImage: Tab.quickLauncher.symbol) }

            cliTab
                .tabItem { Label(Tab.cli.title, systemImage: Tab.cli.symbol) }

            notificationsTab
                .tabItem { Label(Tab.notifications.title, systemImage: Tab.notifications.symbol) }

            backupTab
                .tabItem { Label(Tab.backup.title, systemImage: Tab.backup.symbol) }

            logsTab
                .tabItem { Label(Tab.logs.title, systemImage: Tab.logs.symbol) }

            updatesTab
                .tabItem { Label(Tab.updates.title, systemImage: Tab.updates.symbol) }

            aboutTab
                .tabItem { Label(Tab.about.title, systemImage: Tab.about.symbol) }
        }
        .frame(width: Self.windowWidth())
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand {
            NSApp.keyWindow?.close()
        }
    }

    /// How wide the window has to be for the whole tab bar to stay visible.
    ///
    /// This used to be a hardcoded 680, measured in English (issue #39 item 1).
    /// But the requirement is a pure function of the current language: Chinese
    /// fits all eight tabs in 680pt with room to spare, while Russian's
    /// "Резервное копирование" alone is nearly three times the width of
    /// "Backup" and silently pushes two tabs into the macOS "»" overflow menu.
    /// Any fixed number is only ever right for the language it was measured in,
    /// so measure the strings actually about to be drawn.
    ///
    /// Calibrated against the live tab bar via the accessibility API: items are
    /// laid out flush against each other at the 11pt small system font plus a
    /// constant ~12pt of horizontal padding, and macOS collapses the bar once
    /// they need more than the window minus ~8pt at each end. The 16pt used
    /// here is that measured inset with margin to spare.
    static func windowWidth(screenWidth: CGFloat? = nil) -> CGFloat {
        windowWidth(titles: Tab.allCases.map(\.title), screenWidth: screenWidth)
    }

    /// Split out so tests can feed it every language's titles straight from the
    /// `.strings` files instead of re-deriving the formula.
    static func windowWidth(titles: [String], screenWidth: CGFloat? = nil) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bar = titles.reduce(CGFloat.zero) { total, title in
            total + ceil((title as NSString).size(withAttributes: [.font: font]).width) + itemPadding
        }
        // Never shrink below the familiar 680 — languages that fit should keep
        // the proportions users already know. Never exceed the display either:
        // a pathological translation must not open a window wider than the
        // screen, "»" is the lesser evil at that point.
        let available = (screenWidth ?? NSScreen.main?.visibleFrame.width ?? 1440) - 80
        return min(max(680, ceil(bar) + 2 * barInset), max(680, available))
    }

    /// Measured against the live tab bar (see `windowWidth`), not guessed.
    static let itemPadding: CGFloat = 12
    static let barInset: CGFloat = 16

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section(L10n.tr("settings.general")) {
                Picker(L10n.tr("settings.appearance"), selection: $appearanceMode) {
                    Text(L10n.tr("settings.appearance.system")).tag("system")
                    Text(L10n.tr("settings.appearance.light")).tag("light")
                    Text(L10n.tr("settings.appearance.dark")).tag("dark")
                }
                .onChange(of: appearanceMode) { _, newValue in
                    applyAppearance(newValue)
                }

                Picker(L10n.tr("settings.general.language"), selection: $languageManager.current) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Toggle(L10n.tr("settings.general.launch_at_login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                Toggle(L10n.tr("settings.general.show_menubar_icon"), isOn: $showMenuBarIcon)
            }

            Section(L10n.tr("settings.general.defaults")) {
                Picker(L10n.tr("settings.general.default_shell"), selection: $defaultShell) {
                    ForEach(AvailableShells.load(including: defaultShell), id: \.self) { shell in
                        Text(shell).tag(shell)
                    }
                }

                LabeledContent(L10n.tr("settings.general.default_timeout")) {
                    HStack(spacing: 6) {
                        TextField("", value: $defaultTimeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text(L10n.tr("settings.general.seconds"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notifications

    /// System notifications and remote push channels are the two halves of one
    /// question — "how does a finished task reach me?" — so they share a tab.
    /// They used to sit in General, which had accumulated everything from
    /// appearance to default shell; the channel list (issue #51) is the first
    /// item here that manages a collection rather than flipping a switch, and
    /// it needs the room.
    private var notificationsTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("settings.notifications.enable"), isOn: $notificationsEnabled)
            } header: {
                Text(L10n.tr("settings.notifications"))
            } footer: {
                Text(L10n.tr("settings.notifications.hint"))
            }

            PushChannelsSection()
        }
        .formStyle(.grouped)
        // The launch-time Bark→channel migration writes straight to
        // UserDefaults, possibly before PushChannelSettings was ever created.
        .onAppear { PushChannelSettings.shared.reload() }
    }

    // MARK: - Quick Launcher

    private var quickLauncherTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("quick_launcher.settings.enable"), isOn: $quickLauncherSettings.isEnabled)

                if quickLauncherSettings.isEnabled {
                    LabeledContent(L10n.tr("quick_launcher.settings.shortcut")) {
                        HotkeyRecorderView(settings: quickLauncherSettings)
                    }
                }
            } footer: {
                Text(L10n.tr("quick_launcher.settings.hint"))
            }

            Section {
                Picker(
                    L10n.tr("quick_launcher.settings.show_tasks"),
                    selection: $quickLauncherSettings.taskFilter
                ) {
                    ForEach(QuickLauncherTaskFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .disabled(!quickLauncherSettings.isEnabled)
            } header: {
                Text(L10n.tr("quick_launcher.settings.results"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Command Line

    private var cliTab: some View {
        Form {
            CLIInstallSection()
            RaycastExtensionSection()
        }
        .formStyle(.grouped)
    }

    // MARK: - Backup

    private var backupTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("settings.backup.enable"), isOn: $backupManager.isEnabled)
                    .onChange(of: backupManager.isEnabled) { _, _ in
                        backupManager.startScheduledBackups()
                    }

                if let lastDate = backupManager.lastBackupDate {
                    LabeledContent(L10n.tr("settings.backup.last_backup"), value: formatBackupDate(lastDate))
                }

                if backupManager.isEnabled, let nextDate = backupManager.nextBackupDate {
                    LabeledContent(L10n.tr("settings.backup.next_backup"), value: formatBackupDate(nextDate))
                }

                Picker(L10n.tr("settings.backup.frequency"), selection: $backupManager.intervalHours) {
                    Text(L10n.tr("settings.backup.frequency.1h")).tag(1)
                    Text(L10n.tr("settings.backup.frequency.6h")).tag(6)
                    Text(L10n.tr("settings.backup.frequency.12h")).tag(12)
                    Text(L10n.tr("settings.backup.frequency.24h")).tag(24)
                }
                .disabled(!backupManager.isEnabled)
                .onChange(of: backupManager.intervalHours) { _, _ in
                    backupManager.startScheduledBackups()
                }

                Picker(L10n.tr("settings.backup.max_count"), selection: $backupManager.maxBackups) {
                    ForEach(1...10, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .disabled(!backupManager.isEnabled)

                LabeledContent(L10n.tr("settings.backup.directory")) {
                    HStack(spacing: 6) {
                        Text(backupManager.customDirectory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Button(L10n.tr("settings.backup.choose_directory")) {
                            chooseBackupDirectory()
                        }
                        .pointerCursor()
                    }
                }
                .disabled(!backupManager.isEnabled)

                HStack(spacing: 12) {
                    Button(L10n.tr("settings.backup.backup_now")) {
                        if backupManager.performBackup() {
                            showBackupSuccess = true
                        }
                    }
                    .disabled(!backupManager.isEnabled)
                    .pointerCursor()

                    Button(L10n.tr("settings.backup.open_directory")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: backupManager.customDirectory))
                    }
                    .pointerCursor()

                    Button(L10n.tr("settings.backup.list")) {
                        showBackupList = true
                    }
                    .pointerCursor()
                }
            } header: {
                Text(L10n.tr("settings.backup.section"))
            }
        }
        .formStyle(.grouped)
        .alert(L10n.tr("settings.backup.success"), isPresented: $showBackupSuccess) {
            Button("OK") {}
        } message: {
            Text(L10n.tr(backupManager.lastBackupWasDedup
                         ? "settings.backup.success.no_change.message"
                         : "settings.backup.success.message"))
        }
        .sheet(isPresented: $showBackupList) {
            backupListSheet
        }
        .alert(L10n.tr("settings.backup.restore_confirm.title"), isPresented: $showRestoreConfirm) {
            Button(L10n.tr("settings.backup.restore_confirm.cancel"), role: .cancel) {}
            Button(L10n.tr("settings.backup.restore_confirm.confirm"), role: .destructive) {
                if let backup = backupToRestore {
                    runRestore(backup)
                }
            }
        } message: {
            Text(L10n.tr("settings.backup.restore_confirm.message"))
        }
        .alert(restoreSuccess ? L10n.tr("settings.backup.restore_success")
                              : L10n.tr("settings.backup.restore_failed"),
               isPresented: $showRestoreResult) {
            Button("OK") {}
        } message: {
            Text(restoreSuccess
                 ? L10n.tr("settings.backup.restore_success.message")
                 : (restoreErrorMessage ?? L10n.tr("settings.backup.restore_failed.message")))
        }
        .alert(L10n.tr("settings.backup.skipped.title"), isPresented: skipReasonPresented) {
            Button("OK") { backupManager.lastSkipReason = nil }
        } message: {
            Text(backupManager.lastSkipReason ?? "")
        }
        .overlay {
            if isRestoring {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(L10n.tr("settings.backup.restoring"))
                            .font(.callout)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
                .allowsHitTesting(true)
            }
        }
    }

    /// Backing for the skip-reason alert. Shows whenever `lastSkipReason` is non-nil.
    private var skipReasonPresented: Binding<Bool> {
        Binding(
            get: { backupManager.lastSkipReason != nil },
            set: { if !$0 { backupManager.lastSkipReason = nil } }
        )
    }

    private func runRestore(_ backup: DatabaseBackup.BackupEntry) {
        // Legacy restore swaps SQLite files and must restart the app. If
        // scripts are running, confirm BEFORE touching any files or spawning
        // the relaunch watcher — cancelling later would leave the store
        // already swapped under a live app plus a watcher waiting to
        // resurrect it.
        if backup.format == .legacy, !AppDelegate.confirmTerminationOfRunningScripts() {
            return
        }
        // Flush in-flight edits before swapping data so the user's last save isn't
        // silently dropped. Non-fatal — restore proceeds either way.
        do {
            try TaskTickApp._sharedModelContainer.mainContext.save()
        } catch {
            NSLog("⚠️ Pre-restore save failed (unsaved edits will be lost): \(error.localizedDescription)")
        }

        isRestoring = true
        Task {
            // restore(from:) does the heavy SwiftData work on a background context,
            // so awaiting it here keeps the main thread free to render the spinner.
            let result = await backupManager.restore(from: backup)
            isRestoring = false
            switch result {
            case .success:
                switch backup.format {
                case .legacy:
                    // Legacy restore swaps the SQLite files under SwiftData — must
                    // restart for the new file to be read.
                    let appPath = Bundle.main.bundlePath
                    let pid = ProcessInfo.processInfo.processIdentifier
                    let script = """
                    while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
                    open "\(appPath)"
                    """
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", script]
                    try? process.run()
                    AppDelegate.shouldReallyQuit = true
                    NSApp.terminate(nil)
                case .json:
                    // JSON restore went through ModelContext — no restart needed,
                    // SwiftUI views will refresh from the @Query subscription.
                    restoreSuccess = true
                    restoreErrorMessage = nil
                    showRestoreResult = true
                }
            case .failed(let message):
                restoreErrorMessage = message
                restoreSuccess = false
                showRestoreResult = true
            }
        }
    }

    private var backupListSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("settings.backup.list"))
                    .font(.headline)
                Spacer()
                Button(L10n.tr("editor.cancel")) {
                    showBackupList = false
                }
                .pointerCursor()
            }
            .padding()

            Divider()

            let backups = backupManager.listBackups()
            if backups.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(L10n.tr("settings.backup.no_backups"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(backups) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(formatBackupDate(entry.date))
                                    .font(.body)
                                if entry.format == .legacy {
                                    Text(L10n.tr("settings.backup.format.legacy"))
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(.orange.opacity(0.2)))
                                        .foregroundStyle(.orange)
                                }
                            }
                            HStack(spacing: 8) {
                                if let count = entry.taskCount {
                                    Text(L10n.tr("settings.backup.tasks_count", count))
                                }
                                Text(formatFileSize(entry.sizeBytes))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.tr("settings.backup.restore")) {
                            backupToRestore = entry
                            showBackupList = false
                            showRestoreConfirm = true
                        }
                        .controlSize(.small)
                        .pointerCursor()
                        Button(role: .destructive) {
                            backupToDelete = entry
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .pointerCursor()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(width: 400, height: 320)
        .alert(L10n.tr("settings.backup.delete_confirm.title"), isPresented: $showDeleteConfirm) {
            Button(L10n.tr("settings.backup.restore_confirm.cancel"), role: .cancel) {}
            Button(L10n.tr("delete.confirm"), role: .destructive) {
                if let backup = backupToDelete {
                    backupManager.deleteBackup(backup)
                }
            }
        } message: {
            Text(L10n.tr("settings.backup.delete_confirm.message"))
        }
    }

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backupManager.customDirectory = url.path
        }
    }

    private func formatBackupDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Logs

    private var logsTab: some View {
        Form {
            Section(L10n.tr("settings.logs.section")) {
                Toggle(
                    L10n.tr("settings.logs.automatic_cleanup"),
                    isOn: $automaticLogCleanup
                )

                LabeledContent(L10n.tr("settings.logs.retention")) {
                    HStack(spacing: 6) {
                        TextField("", value: $logRetentionDays, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text(L10n.tr("settings.logs.retention.days"))
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent(L10n.tr("settings.logs.maximum_per_task")) {
                    TextField("", value: $maximumLogsPerTask, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }

                HStack(spacing: 8) {
                    Button(L10n.tr("settings.logs.cleanup"), role: .destructive) {
                        showCleanupConfirm = true
                    }
                    .pointerCursor()
                    .disabled(isCleaningLogs)

                    if isCleaningLogs {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Section {
                Toggle(L10n.tr("settings.logs.stream_to_file"), isOn: $streamManualToFile)

                if streamManualToFile, let dir = LogFileWriter.logsDirectory() {
                    HStack(spacing: 8) {
                        Text(dir.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.tr("settings.logs.reveal_directory")) {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                        .pointerCursor()
                    }
                }
            } header: {
                Text(L10n.tr("settings.logs.streaming"))
            } footer: {
                Text(L10n.tr("settings.logs.stream_to_file.hint"))
            }
        }
        .formStyle(.grouped)
        .alert(L10n.tr("settings.logs.cleanup.confirm.title"), isPresented: $showCleanupConfirm) {
            Button(L10n.tr("settings.logs.cleanup.cancel"), role: .cancel) {}
            Button(L10n.tr("settings.logs.cleanup.confirm"), role: .destructive) {
                runLogCleanup()
            }
        } message: {
            Text(L10n.tr(
                "settings.logs.cleanup.confirm.message",
                max(logRetentionDays, 0),
                max(maximumLogsPerTask, 1)
            ))
        }
        .alert(L10n.tr("settings.logs.cleanup.result.title"), isPresented: $showCleanupResult) {
            Button("OK") {}
        } message: {
            Text(L10n.tr("settings.logs.cleanup.result.message", cleanupDeletedCount))
        }
    }

    private func runLogCleanup() {
        isCleaningLogs = true
        Task {
            let result = await ExecutionLogRetentionManager.shared.runManualCleanup()

            isCleaningLogs = false
            cleanupDeletedCount = result.deletedCount
            showCleanupResult = true
            if result.deletedCount > 0 {
                TaskScheduler.shared.rebuildSchedule()
            }
        }
    }

    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section(L10n.tr("settings.updates.section")) {
                Toggle(L10n.tr("settings.updates.auto_check"), isOn: $autoCheckUpdates)

                Picker(L10n.tr("settings.updates.frequency"), selection: $updateCheckInterval) {
                    Text(L10n.tr("settings.updates.frequency.12h")).tag(12)
                    Text(L10n.tr("settings.updates.frequency.24h")).tag(24)
                    Text(L10n.tr("settings.updates.frequency.3d")).tag(72)
                    Text(L10n.tr("settings.updates.frequency.1w")).tag(168)
                }
                .disabled(!autoCheckUpdates)

                HStack(spacing: 12) {
                    Button(L10n.tr("settings.updates.check_now")) {
                        Task { await updateChecker.checkForUpdates(userInitiated: true) }
                    }
                    .disabled(updateChecker.isChecking)
                    .pointerCursor()

                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                        Text(L10n.tr("settings.updates.new_version", version))
                            .font(.caption)
                            .foregroundStyle(.green)
                            .fontWeight(.medium)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        Form {
            Section(L10n.tr("settings.about.section")) {
                LabeledContent(L10n.tr("settings.about.version"), value: updateChecker.currentVersion)
                LabeledContent(L10n.tr("settings.about.build"), value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

                Text("A native macOS app for managing scheduled tasks.\nNo crontab, no launchd — just TaskTick.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

                Text("一款原生 macOS 定时任务管理应用。\n无需 crontab，无需 launchd，交给 TaskTick。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)

                Link(L10n.tr("settings.about.github"), destination: URL(string: "https://github.com/lifedever/TaskTick")!)
                    .pointerCursor()
                Link(L10n.tr("settings.about.issues"), destination: URL(string: "https://github.com/lifedever/TaskTick/issues")!)
                    .pointerCursor()
                Link(L10n.tr("settings.about.sponsor"), destination: URL(string: "https://www.lifedever.com/sponsor/")!)
                    .pointerCursor()

                Text(L10n.tr("settings.about.copyright"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    private func applyAppearance(_ mode: String) {
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil // follow system
        }
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }
}
