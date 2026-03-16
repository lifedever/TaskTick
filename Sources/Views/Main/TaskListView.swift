import SwiftUI
import SwiftData

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
    @Query(sort: \ScheduledTask.createdAt, order: .forward) private var tasks: [ScheduledTask]
    @Binding var selectedTask: ScheduledTask?
    @State private var filter: TaskFilter = .all
    @State private var searchText = ""
    @State private var taskToDelete: ScheduledTask?
    @State private var showingDeleteAlert = false
    @State private var taskToClearLogs: ScheduledTask?
    @State private var showingClearLogsAlert = false
    @StateObject private var scheduler = TaskScheduler.shared

    var filteredTasks: [ScheduledTask] {
        tasks.filter { task in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .enabled: task.isEnabled
            case .disabled: !task.isEnabled
            }
            let matchesSearch = searchText.isEmpty || task.name.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            Picker("", selection: $filter) {
                ForEach(TaskFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
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
                List(selection: $selectedTask) {
                    ForEach(filteredTasks) { task in
                        TaskListRow(
                            task: task,
                            isRunning: scheduler.runningTaskIDs.contains(task.id)
                        )
                        .tag(task)
                        .contextMenu {
                            Button(L10n.tr("task.detail.edit"), systemImage: "pencil") {
                                EditorState.shared.openEdit(task)
                                openWindow(id: "editor")
                            }
                            Button(L10n.tr("task.detail.run"), systemImage: "play.fill") {
                                Task {
                                    _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                                }
                            }
                            Divider()
                            Button(L10n.tr("task.duplicate"), systemImage: "doc.on.doc") {
                                duplicateTask(task)
                            }
                            Divider()
                            Button(L10n.tr("clear_logs.title"), systemImage: "trash.circle") {
                                taskToClearLogs = task
                                showingClearLogsAlert = true
                            }
                            .disabled(task.executionLogs.isEmpty)
                            Button(L10n.tr("task.detail.delete"), systemImage: "trash", role: .destructive) {
                                taskToDelete = task
                                showingDeleteAlert = true
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .alert(L10n.tr("clear_logs.title"), isPresented: $showingClearLogsAlert) {
                    Button(L10n.tr("clear_logs.cancel"), role: .cancel) {}
                    Button(L10n.tr("clear_logs.confirm"), role: .destructive) {
                        if let task = taskToClearLogs {
                            for log in task.executionLogs {
                                modelContext.delete(log)
                            }
                            task.executionCount = 0
                            task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
                            try? modelContext.save()
                            TaskScheduler.shared.rebuildSchedule()
                        }
                    }
                } message: {
                    Text(L10n.tr("clear_logs.message", taskToClearLogs?.name ?? ""))
                }
                .alert(L10n.tr("delete.title"), isPresented: $showingDeleteAlert) {
                    Button(L10n.tr("delete.cancel"), role: .cancel) {}
                    Button(L10n.tr("delete.confirm"), role: .destructive) {
                        if let task = taskToDelete {
                            if selectedTask == task { selectedTask = nil }
                            modelContext.delete(task)
                            try? modelContext.save()
                        }
                    }
                } message: {
                    Text(L10n.tr("delete.message", taskToDelete?.name ?? ""))
                }
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.tr("task.search.prompt")))
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
        copy.customIntervalValue = task.customIntervalValue
        copy.customIntervalUnit = task.customIntervalUnit
        modelContext.insert(copy)
        try? modelContext.save()
        selectedTask = copy
    }
}

struct TaskListRow: View {
    let task: ScheduledTask
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                if isRunning {
                    Circle()
                        .fill(.blue)
                        .frame(width: 10, height: 10)
                    Circle()
                        .stroke(.blue.opacity(0.3), lineWidth: 2)
                        .frame(width: 16, height: 16)
                } else {
                    Circle()
                        .fill(task.isEnabled ? .green : .gray.opacity(0.35))
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.name)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if task.serialNumber > 0 {
                        Text("#\(task.serialNumber)")
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    Image(systemName: "repeat")
                        .font(.system(size: 9))
                    Text(task.repeatType.displayName)
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
    }

}
