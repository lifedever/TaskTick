import SwiftUI
import TaskTickCore

/// Explains a `.skipped` log: why the scheduled run never started, and — while
/// the task still has it off — that "Run Missed Execution" would have run it
/// late instead (issue #59).
struct SkippedNoticeView: View {
    let log: ExecutionLog

    private var reasonText: String {
        log.skipReason?.displayName ?? L10n.tr("log.skipped.generic")
    }

    private var icon: String {
        switch log.skipReason {
        case .asleep: "moon.zzz"
        case .notRunning: "power"
        case .stillRunning: "hourglass"
        case .late, nil: "clock.badge.exclamationmark"
        }
    }

    /// Only while the setting is still off — once the user has turned it on,
    /// pointing at it again would read as if it hadn't taken — and only where
    /// the editor actually shows the toggle (repeating or cron schedules), so
    /// the hint never points at a setting a one-off task doesn't have.
    private var showsHint: Bool {
        guard let task = log.task, !task.runMissedExecution else { return false }
        let isCron = task.schedule == .cron && !(task.cronExpression ?? "").isEmpty
        return isCron || task.repeatType != .never
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(reasonText)
                if showsHint {
                    Text(L10n.tr("log.skipped.hint", L10n.tr("schedule.run_missed")))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(ExecutionStatus.skipped.color)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ExecutionStatus.skipped.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ExecutionStatus.skipped.color.opacity(0.25), lineWidth: 0.5)
        )
    }
}
