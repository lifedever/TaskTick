import SwiftUI
import SwiftData
import TaskTickCore

struct LogListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExecutionLog.startedAt, order: .reverse) private var logs: [ExecutionLog]
    @State private var selection: Set<ExecutionLog> = []
    @State private var statusFilter: ExecutionStatus?
    @State private var logsToDelete: [ExecutionLog] = []
    @State private var showingDeleteAlert = false

    var filteredLogs: [ExecutionLog] {
        // Deleted models linger in `@Query` results until the context saves;
        // reading their properties would trap, so drop them up front.
        let live = logs.filter { $0.modelContext != nil }
        if let filter = statusFilter {
            return live.filter { $0.status == filter }
        }
        return live
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
                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: L10n.tr("log.filter.all"), isSelected: statusFilter == nil) {
                            statusFilter = nil
                        }
                        ForEach(ExecutionStatus.allCases, id: \.self) { status in
                            FilterChip(
                                label: status.displayName,
                                color: StatusBadge.color(for: status),
                                isSelected: statusFilter == status
                            ) {
                                statusFilter = (statusFilter == status) ? nil : status
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

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
                        LogExporter.exportLogs(filteredLogs, nameHint: "TaskTick")
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

struct FilterChip: View {
    let label: String
    var color: Color = .accentColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? color.opacity(0.15) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(isSelected ? color.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1))
                .foregroundStyle(isSelected ? color : .secondary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
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
