import SwiftUI
import SwiftData
import TaskTickCore

/// Content view displayed in the menu bar popover.
struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \ScheduledTask.createdAt, order: .reverse) private var tasks: [ScheduledTask]
    @StateObject private var scheduler = TaskScheduler.shared
    /// Watching the live settings object so the shortcut hint here updates the
    /// instant the user re-records it in Settings — no stale label.
    @ObservedObject private var quickLauncherSettings = QuickLauncherSettings.shared
    /// Same key as the main window's sort menu — manual scripts here follow
    /// whatever order the user picked there, including the Custom drag order
    /// (issue #56: a most-recently-run order kept moving rows under the cursor).
    @AppStorage("taskSortOption") private var sortOptionRaw = TaskSortOption.lastRunDesc.rawValue

    /// Caps tuned for the menu bar surface. Scheduled jobs fire on their
    /// own schedule so the next 3 are usually enough context; manual scripts
    /// are the day-to-day actions, so they get more room. Past the manual cap
    /// a "N more" row points at the main window; the popover has no scroll
    /// view, so its height follows the row count.
    private static let maxScheduled = 3
    private static let maxManual = 10

    var upcomingTasks: [ScheduledTask] {
        tasks
            .filter { $0.isEnabled && !$0.isManualOnly && $0.nextRunAt != nil }
            .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
            .prefix(Self.maxScheduled)
            .map { $0 }
    }

    private var allManualTasks: [ScheduledTask] {
        let option = TaskSortOption(rawValue: sortOptionRaw) ?? .lastRunDesc
        return option.sort(tasks.filter { $0.isEnabled && $0.isManualOnly })
    }

    var manualTasks: [ScheduledTask] {
        Array(allManualTasks.prefix(Self.maxManual))
    }

    var hiddenManualCount: Int {
        max(allManualTasks.count - Self.maxManual, 0)
    }

    @State private var isHoveringHeader = false

    var body: some View {
        VStack(spacing: 0) {
            // Header — clicking it opens the main window (issue #39: absorbs
            // the old footer "Open" item).
            Button(action: openMainWindow) {
                HStack {
                    BrandMark(size: 14, tint: .accentColor)
                    Text(L10n.tr("app.name"))
                        .font(.headline)
                    Spacer()
                    Text("\(tasks.filter(\.isEnabled).count)/\(tasks.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isHoveringHeader ? 0.05 : 0.00001))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isHoveringHeader = $0 }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            Divider()

            // Task list
            if upcomingTasks.isEmpty && manualTasks.isEmpty {
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
                VStack(spacing: 2) {
                    if !upcomingTasks.isEmpty {
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

                    if !manualTasks.isEmpty {
                        HStack {
                            Text(L10n.tr("menubar.manual_scripts"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, upcomingTasks.isEmpty ? 4 : 8)

                        ForEach(manualTasks) { task in
                            MenuBarTaskRow(task: task, isRunning: scheduler.runningTaskIDs.contains(task.id))
                        }

                        if hiddenManualCount > 0 {
                            MenuBarFooterButton(title: L10n.tr("menubar.more_tasks", hiddenManualCount),
                                                action: openMainWindow)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }

            Divider()

            // Footer actions — Raycast-style: no dividers, hover background
            // does the visual separation work, matching MenuBarTaskRow above.
            VStack(spacing: 2) {
                MenuBarFooterButton(title: L10n.tr("menubar.settings")) {
                    if let panel = NSApp.keyWindow as? NSPanel {
                        panel.orderOut(nil)
                    }
                    // In-scene context → use the sanctioned macOS 14+ action.
                    // The legacy `showSettingsWindow:` selector (SettingsWindowOpener)
                    // returns true here but never creates the window on macOS 14+.
                    NSApp.setActivationPolicy(.regular)
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }

                if quickLauncherSettings.isEnabled {
                    MenuBarFooterButton(
                        title: L10n.tr("quick_launcher.menu_item"),
                        action: {
                            if let panel = NSApp.keyWindow as? NSPanel {
                                panel.orderOut(nil)
                            }
                            QuickLauncherController.shared.toggle()
                        }
                    ) {
                        // 1Password-style: each modifier and the key get
                        // their own kbd pill so the shortcut is legible
                        // at a glance.
                        ForEach(quickLauncherSettings.displayChips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.85))
                                .frame(minWidth: 16)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.primary.opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                                )
                        }
                    }
                }

                MenuBarFooterButton(title: L10n.tr("command.check_updates")) {
                    // Dismiss the popover first, like every other item here.
                    // It's an NSPanel and sits above ordinary windows, so
                    // leaving it up buries the update dialog behind it.
                    if let panel = NSApp.keyWindow as? NSPanel {
                        panel.orderOut(nil)
                    }
                    Task { await UpdateChecker.shared.checkForUpdates(userInitiated: true) }
                }

                MenuBarFooterButton(title: L10n.tr("menubar.quit")) {
                    // Goes through applicationShouldTerminate, which shows the
                    // unified Quit / Hide / Cancel confirmation.
                    NSApp.terminate(nil)
                }
            }
            .padding(8)
        }
        .frame(width: 300)
        .onAppear {
            if !scheduler.isRunning {
                scheduler.configure(modelContext: modelContext)
                scheduler.start()
            }
        }
    }

    private func openMainWindow() {
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
    }
}

/// Reusable footer row with hover background — same visual contract as
/// `MenuBarTaskRow` so the menu reads as one coherent list rather than
/// "task list" + "ruled command list".
struct MenuBarFooterButton<Trailing: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.05 : 0.00001))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
    }
}

extension MenuBarFooterButton where Trailing == EmptyView {
    init(title: String, action: @escaping () -> Void) {
        self.init(title: title, action: action, trailing: { EmptyView() })
    }
}

struct MenuBarTaskRow: View {
    @Environment(\.modelContext) private var modelContext
    let task: ScheduledTask
    let isRunning: Bool
    @State private var isHovering = false

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
                if isHovering {
                    Button {
                        ScriptExecutor.shared.cancel(taskId: task.id)
                        ActionToast.notify(.stopped(taskName: task.name), taskId: task.id, wantsBanner: task.notifyOnAction)
                        ToastCenter.shared.stopped(L10n.tr("toast.task.stopped", task.name))
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(L10n.tr("task.detail.stop"))
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            } else if isHovering {
                Button {
                    let context = modelContext
                    Task {
                        _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
                    }
                    ActionToast.notify(.started(taskName: task.name), taskId: task.id, wantsBanner: task.notifyOnAction)
                    ToastCenter.shared.running(L10n.tr("toast.task.started", task.name))
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            } else if task.isManualOnly {
                Image(systemName: "play.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let nextRun = task.nextRunAt {
                Text(nextRun, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.05 : 0.00001))
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if isRunning {
                ScriptExecutor.shared.cancel(taskId: task.id)
                ActionToast.notify(.stopped(taskName: task.name), taskId: task.id, wantsBanner: task.notifyOnAction)
                ToastCenter.shared.stopped(L10n.tr("toast.task.stopped", task.name))
            } else {
                let context = modelContext
                Task {
                    _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
                }
                ActionToast.notify(.started(taskName: task.name), taskId: task.id, wantsBanner: task.notifyOnAction)
                ToastCenter.shared.running(L10n.tr("toast.task.started", task.name))
            }
        }
        .pointerCursor()
    }
}
