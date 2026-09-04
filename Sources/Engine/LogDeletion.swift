import Foundation
import SwiftData
import TaskTickCore

/// Shared delete path for execution logs removed from the log lists.
///
/// Deleting logs is not just a `modelContext.delete` — `ScheduledTask`
/// carries a denormalized `executionCount`, and `computeNextRunDate` reads it
/// for run-count-limited schedules. Both the counter and next date must be
/// resynced or a task can stall (thinking it already hit its run cap) or
/// report a count that no longer matches its logs. Selective delete and the
/// "clear all logs" flows in `TaskListView` / `TaskDetailView` share those
/// steps here so they can't drift apart.
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

        // Save first so the store reflects the deletions before the counter
        // is re-read from it and computeNextRunDate consults that counter.
        do {
            try context.save()
        } catch {
            NSLog("⚠️ delete logs save failed: \(error)")
            return
        }

        for task in affected where task.modelContext != nil {
            // Counted by the store rather than by faulting every surviving
            // log; the relationship walk is only the fallback if that fails.
            task.executionCount = ExecutionLogQuery.count(taskID: task.id, in: context)
                ?? task.executionLogs.filter { $0.modelContext != nil }.count
            task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)
        }

        do {
            try context.save()
        } catch {
            NSLog("⚠️ delete logs post-save failed: \(error)")
        }

        TaskScheduler.shared.rebuildSchedule()
    }

    /// Deletes every log of `task`, then repairs its counter and schedule.
    ///
    /// Batched through `ExecutionLogRetention.delete` so peak memory is one
    /// batch of faulted rows rather than the whole history with its captured
    /// output. Runs in place on the caller's context — the confirm dialog
    /// already framed this as a blocking, destructive action.
    @MainActor
    static func clearAll(for task: ScheduledTask, in context: ModelContext) {
        guard task.modelContext != nil else { return }
        let taskID = task.id

        do {
            _ = try ExecutionLogRetention.delete(ExecutionLogQuery.all(taskID: taskID), in: context)
        } catch {
            NSLog("⚠️ clear logs failed: \(error)")
        }

        // Resync from the store rather than assuming zero, so a batch that
        // failed to save can't leave the counter claiming an empty history.
        task.executionCount = ExecutionLogQuery.count(taskID: taskID, in: context)
            ?? task.executionLogs.filter { $0.modelContext != nil }.count
        task.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: task)

        do {
            try context.save()
        } catch {
            NSLog("⚠️ clear logs post-save failed: \(error)")
        }

        TaskScheduler.shared.rebuildSchedule()
    }
}
