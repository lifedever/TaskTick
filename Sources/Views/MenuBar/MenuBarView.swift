import SwiftUI
import SwiftData

/// Content view displayed in the menu bar popover.
struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ScheduledTask.createdAt, order: .reverse) private var tasks: [ScheduledTask]
    @StateObject private var scheduler = TaskScheduler.shared

    var upcomingTasks: [ScheduledTask] {
        tasks
            .filter { $0.isEnabled && $0.nextRunAt != nil }
            .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.tint)
                Text(L10n.tr("app.name"))
                    .font(.headline)
                Spacer()
                Text("\(tasks.filter(\.isEnabled).count)/\(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if upcomingTasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text(L10n.tr("menubar.no_tasks"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        HStack {
                            Text(L10n.tr("menubar.upcoming"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 4)

                        ForEach(upcomingTasks) { task in
                            MenuBarTaskRow(task: task, isRunning: scheduler.runningTaskIDs.contains(task.id))
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            // Footer actions
            VStack(spacing: 0) {
                // Open main window
                Button(action: {
                    // Dismiss the MenuBarExtra panel
                    if let panel = NSApp.keyWindow as? NSPanel {
                        panel.orderOut(nil)
                    }

                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
                            window.makeKeyAndOrderFront(nil)
                            break
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }) {
                    HStack {
                        Text(L10n.tr("menubar.open"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Divider().padding(.horizontal, 12)

                // Quit
                Button(action: {
                    AppDelegate.shouldReallyQuit = true
                    NSApp.terminate(nil)
                }) {
                    HStack {
                        Text(L10n.tr("menubar.quit"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.vertical, 4)
        }
        .frame(width: 300)
    }
}

struct MenuBarTaskRow: View {
    let task: ScheduledTask
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isRunning ? .blue : (task.isEnabled ? .green : .gray.opacity(0.4)))
                .frame(width: 8, height: 8)

            Text(task.name)
                .font(.system(.body, design: .default))
                .lineLimit(1)

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else if let nextRun = task.nextRunAt {
                Text(nextRun, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.primary.opacity(0.00001))
        )
    }
}
