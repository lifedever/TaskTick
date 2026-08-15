import SwiftUI
import SwiftData
import TaskTickCore

struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    let task: ScheduledTask
    @State private var showingDeleteAlert = false
    @State private var showingClearLogsAlert = false
    @State private var isScriptExpanded = false
    @State private var showingTaskLogs = false
    @State private var selectedLogIdForSheet: UUID?
    @State private var cachedFileContent: String?
    @State private var fileWatcher: FileWatcher?
    @State private var hoveredLogID: UUID?
    @StateObject private var scheduler = TaskScheduler.shared
    @AppStorage("logs.streamManualToFile") private var streamManualToFile = true

    var isRunning: Bool {
        scheduler.runningTaskIDs.contains(task.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.vertical)
            Divider()
                .padding(.horizontal)

            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        scheduleCard
                        if let name = task.shortcutName, !name.isEmpty {
                            shortcutCard
                        } else {
                            scriptCard
                        }
                        if task.isManualOnly && streamManualToFile {
                            liveLogFileCard
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        recentLogsCard
                    }
                    .frame(width: 300, alignment: .top)
                }
                .padding(.horizontal)
                .padding(.vertical)
            }
        }
        .onAppear {
            loadFileContent()
            startFileWatcher()
        }
        .onDisappear {
            fileWatcher?.cancel()
            fileWatcher = nil
        }
        .onChange(of: task.scriptFilePath) {
            loadFileContent()
            startFileWatcher()
        }
        .sheet(isPresented: $showingTaskLogs) {
            TaskLogsView(task: task, initialSelectedLogId: selectedLogIdForSheet)
        }
        .alert(L10n.tr("clear_logs.title"), isPresented: $showingClearLogsAlert) {
            Button(L10n.tr("clear_logs.cancel"), role: .cancel) {}
            Button(L10n.tr("clear_logs.confirm"), role: .destructive) {
                for log in Array(task.executionLogs) {
                    modelContext.delete(log)
                }
                // Save deletions first so the to-many relationship reflects the empty state
                // before computeNextRunDate reads executionLogs.count.
                do { try modelContext.save() } catch { NSLog("⚠️ clear logs save failed: \(error)") }
                task.executionCount = 0
                task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
                do { try modelContext.save() } catch { NSLog("⚠️ clear logs post-save failed: \(error)") }
                TaskScheduler.shared.rebuildSchedule()
            }
        } message: {
            Text(L10n.tr("clear_logs.message", task.name))
        }
        .alert(L10n.tr("delete.title"), isPresented: $showingDeleteAlert) {
            Button(L10n.tr("delete.cancel"), role: .cancel) {}
            Button(L10n.tr("delete.confirm"), role: .destructive) {
                let deletedName = task.name
                modelContext.delete(task)
                do {
                    try modelContext.save()
                    LogFileWriter.deleteFile(for: deletedName)
                } catch {
                    presentErrorAlert(titleKey: "error.delete_failed.title",
                                      messageKey: "error.delete_failed.message",
                                      error: error)
                }
            }
        } message: {
            Text(L10n.tr("delete.message", task.name))
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                // Task icon
                RoundedRectangle(cornerRadius: 12)
                    .fill(task.isEnabled ? Color.accentColor.gradient : Color.gray.opacity(0.2).gradient)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "terminal")
                            .font(.title3)
                            .foregroundStyle(task.isEnabled ? .white : .secondary)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    HStack(spacing: 12) {
                        if task.serialNumber > 0 {
                            Text("#\(task.serialNumber)")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }

                        HStack(spacing: 4) {
                            Circle()
                                .fill(task.isEnabled ? .green : .gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text(task.isEnabled ? L10n.tr("task.status.enabled") : L10n.tr("task.status.disabled"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Text("·")
                            .foregroundStyle(.quaternary)

                        Text(task.isManualOnly ? L10n.tr("schedule.manual_only") : task.repeatDisplayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        // Action buttons
                        HStack(spacing: 8) {
                            Button {
                                toggleTaskEnabled(task, context: modelContext)
                            } label: {
                                Label(
                                    task.isEnabled ? L10n.tr("task.detail.disable") : L10n.tr("task.detail.enable"),
                                    systemImage: task.isEnabled ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(task.isEnabled ? .orange : .green)
                            .pointerCursor()

                            if isRunning {
                                Button {
                                    ScriptExecutor.shared.cancel(taskId: task.id)
                                    ActionToast.notify(.stopped(taskName: task.name), wantsBanner: task.notifyOnAction)
                                } label: {
                                    Label(L10n.tr("task.detail.stop"), systemImage: "stop.fill")
                                }
                                .tint(.red)
                                .pointerCursor()
                            } else {
                                Button {
                                    Task {
                                        _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                                    }
                                    ActionToast.notify(.started(taskName: task.name), wantsBanner: task.notifyOnAction)
                                } label: {
                                    Label(L10n.tr("task.detail.run"), systemImage: "play.fill")
                                }
                                .pointerCursor()
                            }

                            Button {
                                EditorState.shared.openEdit(task)
                                openWindow(id: "editor")
                            } label: {
                                Label(L10n.tr("task.detail.edit"), systemImage: "pencil")
                            }
                            .pointerCursor()

                            Button {
                                showingClearLogsAlert = true
                            } label: {
                                Label(L10n.tr("clear_logs.title"), systemImage: "trash.circle")
                            }
                            .disabled(task.executionLogs.filter { $0.modelContext != nil }.isEmpty)
                            .pointerCursor()

                            Button(role: .destructive) {
                                showingDeleteAlert = true
                            } label: {
                                Label(L10n.tr("task.detail.delete"), systemImage: "trash")
                            }
                            .pointerCursor()
                        }
                        .controlSize(.regular)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Schedule Card

    private var scheduleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("task.detail.schedule"), systemImage: "calendar.badge.clock")
                    .font(.headline)

                VStack(spacing: 8) {
                    // Live elapsed-time row — only when a run is in flight.
                    // Shares its data source (running ExecutionLog's startedAt)
                    // with the Quick Launcher row so the two surfaces always
                    // agree to the second.
                    if isRunning, let startedAt = RunningDuration.startedAt(for: task) {
                        HStack {
                            Text(L10n.tr("task.detail.elapsed"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                                Text(RunningDuration.format(since: startedAt, now: context.date))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.green)
                                    .monospacedDigit()
                            }
                        }
                    }

                    if task.isManualOnly {
                        detailRow(L10n.tr("schedule.trigger_section"), value: L10n.tr("schedule.manual_only"))
                    } else {
                    // Show scheduled date if set; time row collapses any extra
                    // fire points (issue #34) into the same value — no separate
                    // "Extra times" row.
                    if let date = task.scheduledDate {
                        detailRow(L10n.tr("schedule.date"), value: formatInTaskZone(date, task: task, date: .abbreviated, time: .omitted))
                        detailRow(L10n.tr("schedule.time"), value: formattedTimesValue(task: task, mainDate: date))
                    }

                    // Schedule interpreted in a non-system zone (issue #41) —
                    // surface it so the wall-clock rows above aren't misread.
                    if task.scheduleTimeZone != nil {
                        detailRow(L10n.tr("schedule.timezone"), value: TimeZoneDisplay.label(for: task.timeZoneIdentifier))
                    }

                    // Repeat type
                    detailRow(L10n.tr("schedule.repeat"), value: task.repeatDisplayName)

                    if task.jitterSeconds > 0 {
                        detailRow(L10n.tr("schedule.jitter"), value: L10n.tr("task.interval.seconds", task.jitterSeconds))
                    }

                    // End repeat
                    if task.schedule == .cron || task.repeatType != .never {
                        switch task.endRepeatType {
                        case .never:
                            detailRow(L10n.tr("schedule.end_repeat"), value: L10n.tr("end_repeat.never"))
                        case .onDate:
                            if let endDate = task.endRepeatDate {
                                detailRow(L10n.tr("schedule.end_repeat"), value: formatInTaskZone(endDate, task: task, date: .abbreviated, time: .omitted))
                            }
                        case .afterCount:
                            if let count = task.endRepeatCount {
                                detailRow(L10n.tr("schedule.end_repeat"), value: L10n.tr("schedule.after_n_times", count))
                            }
                        }
                    }

                    // Legacy cron/interval display
                    if task.scheduledDate == nil {
                        if task.schedule == .cron {
                            detailRow(L10n.tr("task.detail.cron_expression"), value: task.cronExpression ?? "-")
                        } else if let interval = task.intervalSeconds, interval > 0 {
                            detailRow(L10n.tr("task.detail.interval"), value: L10n.tr("task.detail.interval_value", interval))
                        }
                    }

                    detailRow(L10n.tr("task.detail.next_run"), value: task.nextRunAt?.formatted(date: .abbreviated, time: .standard) ?? "-")
                    } // end !isManualOnly

                    if let lastRun = task.lastRunAt {
                        detailRow(L10n.tr("task.detail.last_run"), value: lastRun.formatted(date: .abbreviated, time: .standard))
                    }

                    let timeoutLabel = task.timeoutSeconds <= 0
                        ? L10n.tr("editor.timeout.unlimited")
                        : L10n.tr("task.detail.timeout_value", task.timeoutSeconds)
                    detailRow(L10n.tr("task.detail.timeout"), value: timeoutLabel)

                    // Notification status
                    let notifyLabel: String = {
                        if task.notifyOnSuccess && task.notifyOnFailure {
                            return L10n.tr("notify.both_short")
                        } else if task.notifyOnSuccess {
                            return L10n.tr("notify.success_short")
                        } else if task.notifyOnFailure {
                            return L10n.tr("notify.failure_short")
                        } else {
                            return L10n.tr("notify.off")
                        }
                    }()
                    detailRow(L10n.tr("editor.section.notification"), value: notifyLabel)
                    if task.barkPushEnabled {
                        detailRow(
                            L10n.tr("settings.bark"),
                            value: task.barkNotifyOnOutputChange
                                ? L10n.tr("editor.notify_bark.on_output_change")
                                : L10n.tr("editor.notify_bark.on")
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Script Card

    private var scriptCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("task.detail.script"), systemImage: "terminal")
                    .font(.headline)

                VStack(spacing: 8) {
                    detailRow(L10n.tr("task.detail.shell"), value: task.shell)

                    if let dir = task.workingDirectory, !dir.isEmpty {
                        detailRow(L10n.tr("task.detail.working_dir"), value: dir)
                    }

                    if let filePath = task.scriptFilePath, !filePath.isEmpty {
                        detailRow(L10n.tr("editor.script.source"), value: L10n.tr("editor.script.source.file"))
                        detailRow(L10n.tr("editor.script.file_path"), value: filePath)
                    } else {
                        detailRow(L10n.tr("editor.script.source"), value: L10n.tr("editor.script.source.inline"))
                    }
                }

                // Show script content (inline or file preview)
                let displayScript: String = {
                    if let filePath = task.scriptFilePath, !filePath.isEmpty {
                        return cachedFileContent ?? ""
                    }
                    return task.scriptBody
                }()

                VStack(alignment: .leading, spacing: 0) {
                    let previewText = isScriptExpanded ? displayScript : String(displayScript.prefix(500))

                    ScrollView {
                        Text(previewText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: isScriptExpanded ? 400 : 120)

                    if displayScript.count > 500 || displayScript.components(separatedBy: .newlines).count > 6 {
                        Divider()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isScriptExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isScriptExpanded ? L10n.tr("task.detail.collapse_script") : L10n.tr("task.detail.show_full_script"))
                                Image(systemName: isScriptExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .pointerCursor()
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 0.5)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shortcut Card

    private var shortcutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("task.detail.shortcut"), systemImage: "wand.and.stars")
                    .font(.headline)

                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    Text(task.shortcutName ?? "")
                        .font(.system(.body, design: .rounded))
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 0.5)
                )

                Text(L10n.tr("task.detail.shortcut.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Live Log File Card

    private var liveLogFileCard: some View {
        let fileURL = LogFileWriter.fileURL(for: task.name)
        let fileExists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let fileSize: String = {
            guard let url = fileURL,
                  fileExists,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let bytes = attrs[.size] as? Int else { return "" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }()

        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.tr("task.detail.live_log_file"), systemImage: "doc.text.below.ecg")
                    .font(.headline)

                if let fileURL {
                    HStack(spacing: 8) {
                        Image(systemName: fileExists ? "doc.fill" : "doc")
                            .foregroundStyle(fileExists ? .secondary : .tertiary)
                        Text(fileURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(fileExists ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !fileSize.isEmpty {
                            Text(fileSize)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.black.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 0.5)
                    )

                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        } label: {
                            Label(L10n.tr("task.detail.live_log.reveal"), systemImage: "folder")
                        }
                        .pointerCursor()
                        .disabled(!fileExists)

                        Button {
                            openInConsole(fileURL)
                        } label: {
                            Label(L10n.tr("task.detail.live_log.console"), systemImage: "terminal")
                        }
                        .pointerCursor()
                        .disabled(!fileExists)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fileURL.path, forType: .string)
                            ToastCenter.shared.success(L10n.tr("task.detail.live_log.copied"))
                        } label: {
                            Label(L10n.tr("task.detail.live_log.copy_path"), systemImage: "doc.on.doc")
                        }
                        .pointerCursor()
                    }
                    .controlSize(.small)

                    if !fileExists {
                        Text(L10n.tr("task.detail.live_log.empty_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Hand the log file off to Console.app. Falls back to the default URL
    /// opener if Console isn't available (rare — it ships with macOS).
    private func openInConsole(_ url: URL) {
        let consoleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console")
        if let consoleURL {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: consoleURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Recent Logs Card

    private var recentLogsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.tr("task.detail.recent_logs"), systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Text("\(task.executionCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                    Spacer()
                    Button(L10n.tr("task.detail.view_logs")) {
                        selectedLogIdForSheet = nil
                        showingTaskLogs = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .pointerCursor()
                }

                let allLogs = task.executionLogs.filter { $0.modelContext != nil }
                let logs = allLogs
                    .sorted { $0.startedAt > $1.startedAt }
                    .prefix(10)

                if logs.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.title3)
                                .foregroundStyle(.quaternary)
                            Text(L10n.tr("task.detail.no_logs"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(logs)) { log in
                            recentLogRow(log)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func recentLogRow(_ log: ExecutionLog) -> some View {
        // Outer button opens the detail sheet; the trailing area conditionally
        // exposes a stop button on hover for `.running` logs (covers both live
        // tasks and stale phantoms left over from an earlier session).
        HStack(spacing: 8) {
            Button {
                selectedLogIdForSheet = log.id
                showingTaskLogs = true
            } label: {
                HStack(spacing: 8) {
                    StatusBadge(status: log.status, compact: true)
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        Text(Self.timeAgo(log.startedAt, now: ctx.date))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if log.status != .running, let ms = log.durationMs {
                        Text(ExecutionLog.formatDuration(ms))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                // Plain buttons only hit-test opaque pixels; without this the
                // Spacer gap (most of the row) silently ignores clicks.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            // Trailing slot while running — spinner, or stop button on hover
            if log.status == .running {
                if hoveredLogID == log.id {
                    Button {
                        stopOrFinalize(log)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(L10n.tr("task.detail.stop"))
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(.primary.opacity(hoveredLogID == log.id ? 0.05 : 0.02))
        )
        .onHover { hovering in
            if hovering { hoveredLogID = log.id }
            else if hoveredLogID == log.id { hoveredLogID = nil }
        }
    }

    /// Stop the run if it's actually live; otherwise just finalize the log so
    /// the UI stops claiming it's running. Same button covers both cases —
    /// most users won't know the difference between "live" and "phantom" so
    /// we shouldn't make them.
    private func stopOrFinalize(_ log: ExecutionLog) {
        guard let taskId = log.task?.id else { return }
        if scheduler.runningTaskIDs.contains(taskId) {
            ScriptExecutor.shared.cancel(taskId: taskId)
            ActionToast.notify(.stopped(taskName: task.name), wantsBanner: task.notifyOnAction)
            ToastCenter.shared.stopped(L10n.tr("toast.task.stopped", task.name))
        } else {
            log.status = .cancelled
            log.finishedAt = Date()
            if log.durationMs == nil {
                log.durationMs = Int(Date().timeIntervalSince(log.startedAt) * 1000)
            }
            try? modelContext.save()
            ToastCenter.shared.info(L10n.tr("toast.log.cleared"))
        }
    }

    // MARK: - Helper

    /// Format an instant using the task's schedule time zone (system when the
    /// task has none), so schedule rows show the wall-clock the user configured.
    private func formatInTaskZone(
        _ instant: Date,
        task: ScheduledTask,
        date dateStyle: Date.FormatStyle.DateStyle,
        time timeStyle: Date.FormatStyle.TimeStyle
    ) -> String {
        var style = Date.FormatStyle(date: dateStyle, time: timeStyle)
        if let tz = task.scheduleTimeZone {
            style.timeZone = tz
        }
        return instant.formatted(style)
    }

    /// Build the comma-separated time string shown on the time row — main
    /// time first, followed by any additional times (only when the repeat
    /// type supports them).
    private func formattedTimesValue(task: ScheduledTask, mainDate: Date) -> String {
        var times: [String] = [formatInTaskZone(mainDate, task: task, date: .omitted, time: .shortened)]
        if task.repeatType.supportsAdditionalTimes {
            for comps in task.additionalTimes {
                guard let h = comps.hour, let m = comps.minute else { continue }
                times.append(String(format: "%02d:%02d", h, m))
            }
        }
        return times.joined(separator: ", ")
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func loadFileContent() {
        if let filePath = task.scriptFilePath, !filePath.isEmpty,
           let result = PreviewFileReader.read(path: filePath) {
            cachedFileContent = result.truncated
                ? result.content + "\n" + L10n.tr("task.detail.preview_truncated")
                : result.content
        } else {
            cachedFileContent = nil
        }
    }

    /// Live-reloads the file-script preview when the file changes on disk
    /// (issue #39 item 5). Inline scripts don't need this — they're read
    /// straight from the SwiftData model, which SwiftUI already observes.
    private func startFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
        if let filePath = task.scriptFilePath, !filePath.isEmpty {
            fileWatcher = FileWatcher(path: filePath) { loadFileContent() }
        }
    }

    private static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let diff = now.timeIntervalSince(date)
        if diff >= 0 && diff < 60 {
            return L10n.tr("time.just_now")
        }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}

struct StatusIndicator: View {
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isEnabled ? .green : .gray.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(isEnabled ? L10n.tr("task.status.enabled") : L10n.tr("task.status.disabled"))
                .font(.caption)
                .foregroundStyle(isEnabled ? .green : .secondary)
        }
    }
}
