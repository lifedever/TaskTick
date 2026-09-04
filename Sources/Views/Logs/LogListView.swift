import SwiftUI
import SwiftData
import TaskTickCore

/// What the global Logs window is narrowed to. One value for both axes so a
/// change to either resets paging the same way.
struct LogFilter: Equatable {
    var taskID: UUID?
    var status: ExecutionStatus?
}

/// Global Logs window. Thin shell that owns the filter and page size; the
/// list lives in `LogListContent` so its `@Query` can be rebuilt with a new
/// predicate or a bigger `fetchLimit` without losing the selection.
struct LogListView: View {
    /// Rows loaded per page. Across every task the table can run to tens of
    /// thousands of rows, so this window pages the same way the per-task
    /// sheet does instead of a whole-table `@Query`.
    static let pageSize = 50

    @State private var filter = LogFilter()
    @State private var limit = LogListView.pageSize

    var body: some View {
        LogListContent(
            filter: filter,
            limit: limit,
            onFilterChange: { newFilter in
                filter = newFilter
                // A new filter is a new list — start it from the first page.
                limit = Self.pageSize
            },
            onLoadMore: { limit += Self.pageSize }
        )
    }
}

private struct LogListContent: View {
    @Environment(\.modelContext) private var modelContext
    let filter: LogFilter
    let limit: Int
    let onFilterChange: (LogFilter) -> Void
    let onLoadMore: () -> Void

    /// Newest `limit` logs matching `filter`, narrowed and sorted by the
    /// store (see `ExecutionLogQuery`). SwiftUI keeps this view's identity
    /// across `limit` / filter changes, so `selection` survives.
    @Query private var logs: [ExecutionLog]

    /// Same order as the main window's list, so the task picker reads the
    /// way the user already has the tasks in their head.
    @Query(sort: \ScheduledTask.createdAt, order: .reverse) private var tasks: [ScheduledTask]

    @State private var selection: Set<ExecutionLog> = []
    @State private var logsToDelete: [ExecutionLog] = []
    @State private var showingDeleteAlert = false

    init(
        filter: LogFilter,
        limit: Int,
        onFilterChange: @escaping (LogFilter) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.filter = filter
        self.limit = limit
        self.onFilterChange = onFilterChange
        self.onLoadMore = onLoadMore
        _logs = Query(ExecutionLogQuery.recent(
            taskID: filter.taskID,
            status: filter.status,
            limit: limit
        ))
    }

    /// Deleted models linger in `@Query` results until the context saves;
    /// reading their properties would trap, so drop them up front.
    var filteredLogs: [ExecutionLog] {
        logs.filter { $0.modelContext != nil }
    }

    /// Every log matching the filter, counted by the store — the loaded page
    /// may be shorter. Drives the "Load more" row.
    private var totalCount: Int {
        ExecutionLogQuery.count(taskID: filter.taskID, status: filter.status, in: modelContext)
            ?? filteredLogs.count
    }

    /// The task the list is narrowed to, if that task still exists.
    private var selectedTask: ScheduledTask? {
        guard let id = filter.taskID else { return nil }
        return tasks.first { $0.id == id }
    }

    /// The single log driving the detail pane. Multi-select is for bulk
    /// delete/export; the detail pane keeps showing one entry at a time.
    private var selectedLog: ExecutionLog? {
        guard selection.count == 1, let log = selection.first else { return nil }
        return log.modelContext != nil ? log : nil
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Filter bar — same row shape as the main window's task list
                // (native controls, 12/8 padding), so the two windows match.
                HStack(spacing: 8) {
                    taskPicker
                    statusPicker
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if filteredLogs.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.quaternary)
                        Text(L10n.tr("task.detail.no_logs"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    // One count per body evaluation so the row's number and
                    // its visibility can't disagree.
                    let total = totalCount
                    List(selection: $selection) {
                        ForEach(filteredLogs) { log in
                            LogListRow(log: log)
                                .tag(log)
                                .contextMenu {
                                    let targets = deleteTargets(rightClicked: log)
                                    Button(deleteMenuTitle(count: targets.count),
                                           systemImage: "trash",
                                           role: .destructive) {
                                        logsToDelete = targets
                                        showingDeleteAlert = true
                                    }
                                }
                        }

                        // A full page came back and the store holds more —
                        // offer the next page instead of fetching the rest.
                        if total > limit {
                            Button {
                                onLoadMore()
                            } label: {
                                Text(L10n.tr("log.load_more", total - limit))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderless)
                            .pointerCursor()
                            .selectionDisabled()
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let log = selectedLog {
                LogDetailView(log: log)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("log.select.title"), systemImage: "doc.text")
                } description: {
                    Text(L10n.tr("log.select.description"))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                LogExportMenu(
                    title: L10n.tr("log.export"),
                    selectedEnabled: !liveSelection.isEmpty,
                    allEnabled: !filteredLogs.isEmpty,
                    onExportSelected: {
                        let picked = liveSelection
                        if picked.count == 1, let log = picked.first {
                            LogExporter.exportLog(log)
                        } else if !picked.isEmpty {
                            LogExporter.exportLogs(picked, nameHint: "TaskTick")
                        }
                    },
                    onExportAll: {
                        // "All" means every log matching the filter, not just
                        // the loaded page — a one-off unbounded fetch is fine
                        // for a user-initiated export.
                        let all = (try? modelContext.fetch(ExecutionLogQuery.recent(
                            taskID: filter.taskID,
                            status: filter.status,
                            limit: nil
                        ))) ?? filteredLogs
                        LogExporter.exportLogs(all, nameHint: selectedTask?.name ?? "TaskTick")
                    }
                )
                .help(L10n.tr("log.export"))
            }
        }
        .alert(L10n.tr("log.delete.title"), isPresented: $showingDeleteAlert) {
            Button(L10n.tr("log.delete.cancel"), role: .cancel) { logsToDelete = [] }
            Button(L10n.tr("log.delete.confirm"), role: .destructive) {
                deleteLogs(logsToDelete)
                logsToDelete = []
            }
        } message: {
            Text(deleteMessage(count: logsToDelete.count))
        }
        // The narrowed-to task can be deleted while this window is open; its
        // logs cascade away, so drop the filter rather than show an empty
        // list labelled with a task that no longer exists.
        .onChange(of: tasks.map(\.id)) {
            if let id = filter.taskID, !tasks.contains(where: { $0.id == id }) {
                onFilterChange(LogFilter(taskID: nil, status: filter.status))
            }
        }
    }

    // MARK: - Filters

    private func setStatus(_ status: ExecutionStatus?) {
        onFilterChange(LogFilter(taskID: filter.taskID, status: status))
    }

    private func setTask(_ taskID: UUID?) {
        onFilterChange(LogFilter(taskID: taskID, status: filter.status))
    }

    /// Native popup listing every task. Stretches to share the filter row
    /// evenly with `statusPicker`; long names truncate inside the control.
    private var taskPicker: some View {
        // An explicit closure, not `set: setTask` — handing the compiler a
        // `@MainActor` method reference here makes IRGen abort while
        // building the isolation thunk (Swift 6.x).
        Picker(selection: Binding(get: { filter.taskID }, set: { setTask($0) })) {
            Text(L10n.tr("log.filter.all_tasks")).tag(UUID?.none)
            Divider()
            ForEach(tasks) { task in
                Text(task.name).tag(Optional(task.id))
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    /// Native popup over execution statuses. The list rows already carry the
    /// coloured status badge, so plain titles are enough here.
    private var statusPicker: some View {
        Picker(selection: Binding(get: { filter.status }, set: { setStatus($0) })) {
            Text(L10n.tr("log.filter.any_status")).tag(ExecutionStatus?.none)
            Divider()
            ForEach(ExecutionStatus.allCases, id: \.self) { status in
                Text(status.displayName).tag(Optional(status))
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    /// Selection filtered down to models still backed by the context, in the
    /// list's display order.
    private var liveSelection: [ExecutionLog] {
        filteredLogs.filter { selection.contains($0) }
    }

    /// macOS convention: right-clicking inside the selection acts on the whole
    /// selection; right-clicking outside it acts on just that row.
    private func deleteTargets(rightClicked log: ExecutionLog) -> [ExecutionLog] {
        let picked = liveSelection
        return picked.contains(log) ? picked : [log]
    }

    private func deleteMenuTitle(count: Int) -> String {
        count > 1 ? L10n.tr("log.delete.menu_many", count) : L10n.tr("log.delete.menu_one")
    }

    private func deleteMessage(count: Int) -> String {
        count > 1 ? L10n.tr("log.delete.message_many", count) : L10n.tr("log.delete.message_one")
    }

    private func deleteLogs(_ targets: [ExecutionLog]) {
        // Resolve the successor before deleting — afterwards `filteredLogs`
        // has already dropped these rows and they're invalidated.
        let successor = LogDeletion.selectionAfterDeleting(targets, from: filteredLogs)
        LogDeletion.delete(targets, in: modelContext)
        selection = successor.map { [$0] } ?? []
    }

}

struct LogListRow: View {
    let log: ExecutionLog

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(status: log.status, compact: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(log.task?.name ?? L10n.tr("log.unknown_task"))
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()

                    if let duration = log.durationMs {
                        Text("· \(ExecutionLog.formatDuration(duration))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
