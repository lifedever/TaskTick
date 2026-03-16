import SwiftUI
import SwiftData

struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    let task: ScheduledTask
    @State private var showingDeleteAlert = false
    @State private var showingClearLogsAlert = false
    @State private var isScriptExpanded = false
    @State private var showingTaskLogs = false
    @StateObject private var scheduler = TaskScheduler.shared

    var isRunning: Bool {
        scheduler.runningTaskIDs.contains(task.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                    .padding(.horizontal)

                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        scheduleCard
                        scriptCard
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 16) {
                        recentLogsCard
                    }
                    .frame(width: 300, alignment: .top)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .sheet(isPresented: $showingTaskLogs) {
            TaskLogsView(task: task)
        }
        .alert(L10n.tr("clear_logs.title"), isPresented: $showingClearLogsAlert) {
            Button(L10n.tr("clear_logs.cancel"), role: .cancel) {}
            Button(L10n.tr("clear_logs.confirm"), role: .destructive) {
                for log in task.executionLogs {
                    modelContext.delete(log)
                }
                task.executionCount = 0
                task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
                try? modelContext.save()
                TaskScheduler.shared.rebuildSchedule()
            }
        } message: {
            Text(L10n.tr("clear_logs.message", task.name))
        }
        .alert(L10n.tr("delete.title"), isPresented: $showingDeleteAlert) {
            Button(L10n.tr("delete.cancel"), role: .cancel) {}
            Button(L10n.tr("delete.confirm"), role: .destructive) {
                modelContext.delete(task)
                try? modelContext.save()
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

                        Text(task.repeatType.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        // Action buttons
                        HStack(spacing: 8) {
                            Button {
                                task.isEnabled.toggle()
                                task.updatedAt = Date()
                                if task.isEnabled {
                                    task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
                                } else {
                                    task.nextRunAt = nil
                                }
                                try? modelContext.save()
                                TaskScheduler.shared.rebuildSchedule()
                            } label: {
                                Label(
                                    task.isEnabled ? L10n.tr("task.detail.disable") : L10n.tr("task.detail.enable"),
                                    systemImage: task.isEnabled ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(task.isEnabled ? .orange : .green)
                            .pointerCursor()

                            Button {
                                Task {
                                    _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                                }
                            } label: {
                                Label(L10n.tr("task.detail.run"), systemImage: "play.fill")
                            }
                            .disabled(isRunning)
                            .pointerCursor()

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
                            .disabled(task.executionLogs.isEmpty)
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
                    // Show scheduled date if set
                    if let date = task.scheduledDate {
                        detailRow(L10n.tr("schedule.date"), value: date.formatted(date: .abbreviated, time: .omitted))
                        detailRow(L10n.tr("schedule.time"), value: date.formatted(date: .omitted, time: .shortened))
                    }

                    // Repeat type
                    detailRow(L10n.tr("schedule.repeat"), value: task.repeatType.displayName)

                    // End repeat
                    if task.repeatType != .never {
                        switch task.endRepeatType {
                        case .never:
                            detailRow(L10n.tr("schedule.end_repeat"), value: L10n.tr("end_repeat.never"))
                        case .onDate:
                            if let endDate = task.endRepeatDate {
                                detailRow(L10n.tr("schedule.end_repeat"), value: endDate.formatted(date: .abbreviated, time: .omitted))
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

                    if let lastRun = task.lastRunAt {
                        detailRow(L10n.tr("task.detail.last_run"), value: lastRun.formatted(date: .abbreviated, time: .standard))
                    }

                    detailRow(L10n.tr("task.detail.timeout"), value: L10n.tr("task.detail.timeout_value", task.timeoutSeconds))

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
                        return (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? "⚠️ Cannot read file"
                    }
                    return task.scriptBody
                }()

                VStack(alignment: .leading, spacing: 0) {
                    Text(displayScript)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: isScriptExpanded ? nil : 120, alignment: .top)
                        .clipped()

                    if displayScript.components(separatedBy: .newlines).count > 6 {
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

    // MARK: - Recent Logs Card

    private var recentLogsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L10n.tr("task.detail.recent_logs"), systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    Text("\(task.executionLogs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                    Spacer()
                    Button(L10n.tr("task.detail.view_logs")) {
                        showingTaskLogs = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .pointerCursor()
                }

                let logs = (task.executionLogs)
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
                            HStack(spacing: 8) {
                                StatusBadge(status: log.status, compact: true)

                                Text(Self.timeAgo(log.startedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer()

                                if let ms = log.durationMs {
                                    Text("\(ms)ms")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.primary.opacity(0.02))
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helper

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

    private static func timeAgo(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
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
