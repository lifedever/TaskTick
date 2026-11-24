import SwiftUI
import SwiftData
import TaskTickCore

struct LogDetailView: View {
    let log: ExecutionLog
    @ObservedObject private var liveOutput = LiveOutputManager.shared

    private var isLive: Bool {
        guard log.status == .running, let taskId = log.task?.id else { return false }
        return liveOutput.isTracking(taskId)
    }

    private var currentStdout: String? {
        if isLive, let taskId = log.task?.id {
            return liveOutput.stdout(for: taskId)
        }
        return log.stdout
    }

    private var currentStderr: String? {
        if isLive, let taskId = log.task?.id {
            return liveOutput.stderr(for: taskId)
        }
        return log.stderr
    }

    var body: some View {
        // The output pane takes the leftover height instead of sitting in a
        // page-wide ScrollView: a tall window should show more log lines, not
        // a taller blank area under a fixed-height box. The metadata above it
        // keeps its own scroller so it stays reachable in a short window.
        VStack(alignment: .leading, spacing: 0) {
            // Metadata is short and fixed — no scroller, so it can't get
            // greedy and steal height from the output pane below.
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(statusGradient)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: log.status.iconName)
                                .font(.title3)
                                .scaleEffect(log.status.iconScale)
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.task?.name ?? L10n.tr("log.unknown_task"))
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(log.startedAt.formatted(date: .complete, time: .standard))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusBadge(status: log.status)
                }

                Divider()

                // Info card
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("log.detail.title"), systemImage: "info.circle")
                            .font(.headline)

                        VStack(spacing: 8) {
                            infoRow(L10n.tr("log.detail.trigger"),
                                    value: log.triggeredBy.displayName)

                            if let exitCode = log.exitCode {
                                infoRow(L10n.tr("log.detail.exit_code"), value: "\(exitCode)")
                            }

                            if let duration = log.durationMs {
                                infoRow(L10n.tr("log.detail.duration"), value: ExecutionLog.formatDuration(duration))
                            }

                            if let finished = log.finishedAt {
                                infoRow(L10n.tr("log.detail.finished"),
                                        value: finished.formatted(date: .abbreviated, time: .standard))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if log.status == .timeout {
                    TimeoutNoticeView(timeoutSeconds: log.task?.timeoutSeconds)
                }

                if log.status == .skipped {
                    SkippedNoticeView(log: log)
                }

                if log.status == .failure, SudoTTYFailure.matches(stderr: log.stderr) {
                    SudoNoticeView()
                }

                // Running indicator
                if log.status == .running {
                    GlassCard {
                        HStack {
                            Text(L10n.tr("status.running"))
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(20)

            // Combined output (terminal-like). Color reflects run status.
            let combined = [currentStdout, currentStderr]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: "\n")
            if !combined.isEmpty {
                let isFailure = log.status == .failure || log.status == .timeout
                // Always use the virtualized view: completed logs can store
                // up to 512KB of stdout and SwiftUI's `Text` still chokes
                // on layout for big strings even when there's no streaming.
                OutputSection(
                    title: L10n.tr("log.detail.output"),
                    content: combined,
                    icon: isFailure ? "exclamationmark.triangle" : "text.alignleft",
                    color: isFailure ? .red : .primary
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var statusGradient: LinearGradient {
        let color = log.status.color
        return LinearGradient(
            colors: [color, color.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

struct OutputSection: View {
    let title: String
    let content: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(color == .primary ? .primary : color)

                // No maxHeight — the pane grows with the window so a taller
                // window shows more lines (issue #42). LogTextView is
                // virtualized, so an unbounded height costs nothing.
                LogTextView(text: content)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.black.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 0.5)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
