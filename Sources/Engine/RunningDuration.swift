import Foundation
import SwiftData
import TaskTickCore

/// Single source of truth for "this task started its current run at X" — read
/// by both the Quick Launcher row and the detail-page schedule card so the
/// two surfaces can never disagree about elapsed time. Backed entirely by
/// the in-flight `ExecutionLog`; nothing reaches into TaskScheduler /
/// ScriptExecutor private state.
enum RunningDuration {

    /// `startedAt` of the ExecutionLog currently in `.running` state, or
    /// `nil` if no run is in flight. Picks the most recently started one if
    /// (rarely) more than one are flagged running — that's a defensive
    /// guard for crash-recovered tasks where status didn't get fixed up.
    ///
    /// A bounded store fetch rather than a walk over `executionLogs`: this
    /// runs inside view bodies, and the relationship can hold a thousand
    /// rows of captured output.
    static func startedAt(for task: ScheduledTask) -> Date? {
        guard let context = task.modelContext else { return nil }
        let taskID = task.id
        let runningRaw = ExecutionStatus.running.rawValue
        var descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate {
                $0.task?.id == taskID && $0.statusRaw == runningRaw && $0.finishedAt == nil
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.startedAt
    }

    /// Compact "Xh Ym Zs" rendering. Auto-collapses zero leading components
    /// (a 30-second run reads "30s", a 2-minute run reads "2m 5s"). Always
    /// at most two units so the label stays narrow in tight UI like the
    /// Quick Launcher row.
    static func format(since startedAt: Date, now: Date = Date()) -> String {
        let elapsed = Int(max(0, now.timeIntervalSince(startedAt)))
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
