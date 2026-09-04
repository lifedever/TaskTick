import Foundation
import SwiftData
import TaskTickCore

/// Shared delete path for execution logs removed from the log lists.
///
/// Deleting logs is not just a `modelContext.delete` — `ScheduledTask`
/// carries a denormalized `executionCount`, and `computeNextRunDate` reads it
/// for run-count-limited schedules. Both the counter and next date must be
/// resynced or a task can stall (thinking it already hit its run cap) or
/// report a count that no longer matches its logs. The existing "clear all
/// logs" flows in `TaskListView` / `TaskDetailView` do the same three steps;
/// this keeps selective delete from drifting out of sync with them.
enum LogDeletion {
    /// The row to select once `doomed` is removed from `visible`.
    ///
    /// Standard list behavior: land on the nearest surviving row *below* the
    /// deleted block, or fall back to the nearest one *above* when the block
    /// ran to the end. Returns nil only when nothing survives.
    ///
    /// Must be called *before* the delete — afterwards the array has already
    /// changed and the deleted models are invalidated.
    static func selectionAfterDeleting(
        _ doomed: [ExecutionLog],
        from visible: [ExecutionLog]
    ) -> ExecutionLog? {
        let removed = Set(doomed)
        guard let firstIndex = visible.firstIndex(where: { removed.contains($0) }) else {
            return nil
        }
        // Search down from the first removed row, then up from it. A
        // multi-select can be discontiguous, so scan rather than offset.
        if let next = visible[firstIndex...].first(where: { !removed.contains($0) }) {
            return next
        }
        return visible[..<firstIndex].last(where: { !removed.contains($0) })
    }

    /// Deletes `logs`, then repairs the affected tasks' counters and schedule.
    ///
    /// Skips models already detached from a context so a stale selection
    /// can't trap. No-ops on an empty (or fully stale) input.
    @MainActor
    static func delete(_ logs: [ExecutionLog], in context: ModelContext) {
        let live = logs.filter { $0.modelContext != nil }
        guard !live.isEmpty else { return }

        // Capture owners before deleting — `log.task` is nil afterwards.
        var affected: [ScheduledTask] = []
        for log in live {
            if let task = log.task, !affected.contains(where: { $0.id == task.id }) {
                affected.append(task)
            }
            context.delete(log)
        }

        // Save first so the to-many relationship reflects the deletions
        // before computeNextRunDate reads executionLogs.count.
        do {
            try context.save()
        } catch {
            NSLog("⚠️ delete logs save failed: \(error)")
            return
        }

        for task in affected where task.modelContext != nil {
            task.executionCount = task.executionLogs.filter { $0.modelContext != nil }.count
            task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
        }

        do {
            try context.save()
        } catch {
            NSLog("⚠️ delete logs post-save failed: \(error)")
        }

        TaskScheduler.shared.rebuildSchedule()
    }
}
