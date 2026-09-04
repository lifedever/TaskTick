import SwiftUI
import SwiftData
import KeyboardShortcuts
import TaskTickCore

enum TaskFilter: String, CaseIterable {
    case all
    case enabled
    case disabled

    var label: String {
        switch self {
        case .all: L10n.tr("task.filter.all")
        case .enabled: L10n.tr("task.filter.enabled")
        case .disabled: L10n.tr("task.filter.disabled")
        }
    }
}

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ScheduledTask.createdAt, order: .reverse) private var tasks: [ScheduledTask]
    @Binding var selectedTask: ScheduledTask?
    @Binding var sortOptionRaw: String
    @State private var filter: TaskFilter = .all
    @State private var searchText = ""
    @State private var taskToDelete: ScheduledTask?
    @State private var showingDeleteAlert = false
    @State private var taskToClearLogs: ScheduledTask?
    @State private var showingClearLogsAlert = false
    @StateObject private var scheduler = TaskScheduler.shared

    var filteredTasks: [ScheduledTask] {
        let filtered = tasks.filter { task in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .enabled: task.isEnabled
            case .disabled: !task.isEnabled
            }
            let matchesSearch = searchText.isEmpty || task.name.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
        let option = TaskSortOption(rawValue: sortOptionRaw) ?? .lastRunDesc
        return option.sort(filtered)
    }

    var scheduledTasks: [ScheduledTask] { filteredTasks.filter { !$0.isManualOnly } }
    var manualTasks: [ScheduledTask] { filteredTasks.filter { $0.isManualOnly } }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                Picker("", selection: $filter) {
                    ForEach(TaskFilter.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                sortMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if filteredTasks.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text(L10n.tr("task.empty.title"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("task.empty.description"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                List(selection: $selectedTask) {
                    if !scheduledTasks.isEmpty {
                        Section(L10n.tr("tasklist.section.scheduled")) {
                            ForEach(scheduledTasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                    if !manualTasks.isEmpty {
                        Section(L10n.tr("tasklist.section.manual")) {
                            ForEach(manualTasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .id(filter)
                .alert(L10n.tr("clear_logs.title"), isPresented: $showingClearLogsAlert) {
                    Button(L10n.tr("clear_logs.cancel"), role: .cancel) {}
                    Button(L10n.tr("clear_logs.confirm"), role: .destructive) {
                        if let task = taskToClearLogs {
                            LogDeletion.clearAll(for: task, in: modelContext)
                        }
                    }
                } message: {
                    Text(L10n.tr("clear_logs.message", taskToClearLogs?.name ?? ""))
                }
                .alert(L10n.tr("delete.title"), isPresented: $showingDeleteAlert) {
                    Button(L10n.tr("delete.cancel"), role: .cancel) {}
                    Button(L10n.tr("delete.confirm"), role: .destructive) {
                        if let task = taskToDelete {
                            let deletedName = task.name
                            if selectedTask == task { selectedTask = nil }
                            TaskHotkeyManager.shared.discardShortcut(for: task.id)
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
                    }
                } message: {
                    Text(L10n.tr("delete.message", taskToDelete?.name ?? ""))
                }
                .onChange(of: selectedTask) { _, newTask in
                    if let task = newTask {
                        withAnimation {
                            proxy.scrollTo(task.id, anchor: .center)
                        }
                    }
                }
                } // ScrollViewReader
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.tr("task.search.prompt")))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Link(destination: URL(string: "https://www.lifedever.com/sponsor/")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Text(L10n.tr("command.sponsor"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .background(.bar)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(L10n.tr("task.sort.created"), selection: $sortOptionRaw) {
                Text(L10n.tr("task.sort.descending")).tag(TaskSortOption.createdDesc.rawValue)
                Text(L10n.tr("task.sort.ascending")).tag(TaskSortOption.createdAsc.rawValue)
            }
            .pickerStyle(.inline)
            Picker(L10n.tr("task.sort.last_run"), selection: $sortOptionRaw) {
                Text(L10n.tr("task.sort.descending")).tag(TaskSortOption.lastRunDesc.rawValue)
                Text(L10n.tr("task.sort.ascending")).tag(TaskSortOption.lastRunAsc.rawValue)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }

    @ViewBuilder
    private func taskRow(_ task: ScheduledTask) -> some View {
        TaskListRow(
            task: task,
            isRunning: scheduler.runningTaskIDs.contains(task.id),
            isSelected: selectedTask == task
        )
        .tag(task)
        .id(task.id)
        .pointerCursor()
        .contextMenu {
            Button(L10n.tr("task.detail.edit"), systemImage: "pencil") {
                EditorState.shared.openEdit(task)
                openWindow(id: "editor")
            }
            if scheduler.runningTaskIDs.contains(task.id) {
                Button(L10n.tr("task.detail.stop"), systemImage: "stop.fill") {
                    ScriptExecutor.shared.cancel(taskId: task.id)
                    ActionToast.notify(.stopped(taskName: task.name), wantsBanner: task.notifyOnAction)
                }
            } else {
                Button(L10n.tr("task.detail.run"), systemImage: "play.fill") {
                    Task {
                        _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                    }
                    ActionToast.notify(.started(taskName: task.name), wantsBanner: task.notifyOnAction)
                }
            }
            Button(task.isEnabled ? L10n.tr("task.detail.disable") : L10n.tr("task.detail.enable"),
                   systemImage: task.isEnabled ? "pause.circle" : "play.circle") {
                toggleTaskEnabled(task, context: modelContext)
            }
            Divider()
            Button(L10n.tr("task.duplicate"), systemImage: "doc.on.doc") {
                duplicateTask(task)
            }
            if let filePath = task.scriptFilePath, !filePath.isEmpty {
                Button(L10n.tr("task.reveal_script"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                }
                .disabled(!FileManager.default.fileExists(atPath: filePath))
            }
            Divider()
            Button(L10n.tr("clear_logs.title"), systemImage: "trash.circle") {
                taskToClearLogs = task
                showingClearLogsAlert = true
            }
            // The denormalised counter is resynced by every delete path, so
            // the menu doesn't need to fault the relationship to know.
            .disabled(task.executionCount == 0)
            Button(L10n.tr("task.detail.delete"), systemImage: "trash", role: .destructive) {
                taskToDelete = task
                showingDeleteAlert = true
            }
        }
    }

    private func duplicateTask(_ task: ScheduledTask) {
        let copy = ScheduledTask(
            name: L10n.tr("task.duplicate.name", task.name),
            scriptBody: task.scriptBody,
            shell: task.shell,
            scheduledDate: task.scheduledDate,
            repeatType: task.repeatType,
            endRepeatType: task.endRepeatType,
            endRepeatDate: task.endRepeatDate,
            endRepeatCount: task.endRepeatCount,
            isEnabled: false,
            workingDirectory: task.workingDirectory,
            timeoutSeconds: task.timeoutSeconds,
            notifyOnSuccess: task.notifyOnSuccess,
            notifyOnFailure: task.notifyOnFailure
        )
        copy.scriptFilePath = task.scriptFilePath
        copy.shortcutName = task.shortcutName
        copy.scheduleType = task.scheduleType
        copy.cronExpression = task.cronExpression
        copy.intervalSeconds = task.intervalSeconds
        copy.jitterSeconds = task.jitterSeconds
        copy.preRunCommand = task.preRunCommand
        copy.customIntervalValue = task.customIntervalValue
        copy.customIntervalUnit = task.customIntervalUnit
        copy.additionalTimesJSON = task.additionalTimesJSON
        copy.timeZoneIdentifier = task.timeZoneIdentifier
        copy.hasDate = task.hasDate
        copy.hasTime = task.hasTime
        copy.environmentVariablesJSON = task.environmentVariablesJSON
        copy.runMissedExecution = task.runMissedExecution
        copy.runOnLaunch = task.runOnLaunch
        copy.notifyOnAction = task.notifyOnAction
        copy.notifyOnlyWhenOutput = task.notifyOnlyWhenOutput
        copy.notificationTemplateEnabled = task.notificationTemplateEnabled
        copy.notificationTemplate = task.notificationTemplate
        copy.pushEnabled = task.pushEnabled
        copy.pushOnlyWhenOutputChanged = task.pushOnlyWhenOutputChanged
        copy.pushChannelIDsJSON = task.pushChannelIDsJSON
        copy.strongReminder = task.strongReminder
        copy.ignoreExitCode = task.ignoreExitCode
        copy.isManualOnly = task.isManualOnly
        modelContext.insert(copy)
        do {
            try modelContext.save()
            selectedTask = copy
        } catch {
            modelContext.delete(copy)
            presentErrorAlert(titleKey: "error.save_failed.title",
                              messageKey: "error.save_failed.message",
                              error: error)
        }
    }
}

struct TaskListRow: View {
    let task: ScheduledTask
    let isRunning: Bool
    /// `List(selection:)` paints the selected row in the system accent
    /// colour. We deliberately do NOT flip the status dot to white when
    /// selected — keeping the semantic colour (green=enabled, blue=running)
    /// preserves the at-a-glance meaning that the inverse-colour variant
    /// destroyed. The dot reads fine against the accent background.
    let isSelected: Bool

    /// The newest log only, via a `fetchLimit = 1` store query. Rows redraw
    /// constantly and a busy task can hold a thousand logs, each with up to
    /// 512 KB of output — walking `executionLogs` here faulted all of it.
    @Query private var latestLogs: [ExecutionLog]

    init(task: ScheduledTask, isRunning: Bool, isSelected: Bool) {
        self.task = task
        self.isRunning = isRunning
        self.isSelected = isSelected
        _latestLogs = Query(ExecutionLogQuery.recent(taskID: task.id, limit: 1))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// Only reachable for enabled tasks that have never run — disabled tasks
    /// short-circuit to the pause icon before the dot branch.
    private var statusDotFill: Color { .green }

    /// Tooltip for the status indicator. The icons carry a lot of meaning for
    /// something this small, so spell it out on hover: running / disabled /
    /// last execution's outcome / enabled-but-never-run.
    private var statusHelpText: String {
        if isRunning { return ExecutionStatus.running.displayName }
        if !task.isEnabled { return L10n.tr("task.status.disabled") }
        if let status = latestExecutionStatus {
            return L10n.tr("task.status.last_run", status.displayName)
        }
        return L10n.tr("task.status.enabled")
    }

    /// The most recent completed or in-progress execution's status, derived
    /// from the task's execution logs. `nil` when the task has never run.
    private var latestExecutionStatus: ExecutionStatus? {
        latestLogs.first { $0.modelContext != nil }?.status
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Status indicator: the latest execution's icon, same family and
            // colours as the "最近执行" list (issue #44). Disabled tasks show
            // a uniform grey pause icon instead — "this won't fire on its own"
            // is the more useful signal there, and identical icons let the
            // disabled rows be picked out at a glance. A disabled task can
            // still be run manually, so `isRunning` wins over both.
            ZStack {
                if let status = isRunning ? .running : (task.isEnabled ? latestExecutionStatus : nil) {
                    Image(systemName: status.iconName)
                        .font(.system(size: 13))
                        .scaleEffect(status.iconScale)
                        .foregroundStyle(status.color)
                } else if !task.isEnabled {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.gray)
                } else {
                    Circle()
                        .fill(statusDotFill)
                        .frame(width: 10, height: 10)
                }
            }
            // Height is the measured line height of `.body` (16pt) so the icon
            // centres on the title rather than on the whole two-line block.
            // The extra 2pt is optical compensation: geometric centring reads
            // as "too high" against all-lowercase Latin names, whose x-height
            // sits lower than CJK glyphs of the same line height.
            .frame(width: 18, height: 16)
            .padding(.top, 2)
            // `contentShape` so the tooltip covers the whole 18pt slot, not
            // just the glyph's own pixels — a 15pt icon is a small target.
            .contentShape(Rectangle())
            .help(statusHelpText)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.name)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(task.isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if task.serialNumber > 0 {
                        Text("#\(task.serialNumber)")
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    if task.isManualOnly {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 9))
                        Text(L10n.tr("schedule.manual_only"))
                            .font(.caption2)
                    } else {
                        Image(systemName: "repeat")
                            .font(.system(size: 9))
                        Text(task.repeatDisplayName)
                            .font(.caption2)
                    }

                    Text("·")
                        .font(.caption2)
                    // Prefer "last run" since that's the dynamic signal users
                    // care about (when did this thing last fire?). Fall back
                    // to createdAt only for tasks that have never run yet.
                    // TimelineView ticks every 60s so the relative label
                    // doesn't freeze at "just-fired" forever. Short-circuit
                    // diffs under 60s to "just now" because zh-Hans .short
                    // formatter quantizes |diff|<1s to "0秒后" (a future-tense
                    // string for a past event), which reads as a bug.
                    TimelineView(.periodic(from: .now, by: 60)) { ctx in
                        let d = task.lastRunAt ?? task.createdAt
                        let diff = ctx.date.timeIntervalSince(d)
                        if diff >= 0 && diff < 60 {
                            Text(L10n.tr("time.just_now"))
                        } else {
                            Text(Self.relativeFormatter.localizedString(for: d, relativeTo: ctx.date))
                        }
                    }
                    .font(.caption2)

                    if let shortcut = TaskHotkeys.name(for: task.id).shortcut {
                        Text("·")
                            .font(.caption2)
                        Text(shortcut.description)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    // Same first-line alignment as the status icon, now that
                    // the row stack is top-aligned.
                    .frame(height: 16)
                    .padding(.top, 2)
                    // Force white on the selected row — without an explicit
                    // tint the spinner stays accent-coloured and disappears
                    // into the selection background.
                    .tint(isSelected ? Color.white : Color.accentColor)
            }
        }
        .padding(.vertical, 3)
        // List paints its selection highlight without a SwiftUI animation
        // transaction, but `Circle().fill(Color)` will use SwiftUI's default
        // colour-interpolation animation when the colour binding changes.
        // Result: the row background flashes blue instantly while the dot
        // slowly fades green→white. Disabling animation specifically for
        // `isSelected` changes brings them back into the same frame.
        .animation(nil, value: isSelected)
    }

}
