import Foundation
import SwiftData
import TaskTickCore

/// Bounded, store-side reads of execution logs.
///
/// Every log surface used to read `task.executionLogs` (or a whole-table
/// `@Query`) and filter/sort in memory. That faults every row — up to the
/// 1,000-log retention cap per task, each carrying as much as 512 KB of
/// captured output — just to show the newest ten, and it happened on every
/// redraw. These descriptors push the narrowing down to SQLite instead:
/// `ZEXECUTIONLOG_ZTASK_INDEX` picks a task's rows, the store sorts them, and
/// only `limit` objects materialise.
enum ExecutionLogQuery {
    // MARK: One task

    /// Newest-first logs for `taskID`. Pass `nil` to fetch every row — only
    /// for one-off operations like export, never from a view body.
    static func recent(taskID: UUID, limit: Int?) -> FetchDescriptor<ExecutionLog> {
        var descriptor = all(taskID: taskID)
        descriptor.sortBy = [SortDescriptor(\.startedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Every log for `taskID`, unsorted — for counting and batched deletion,
    /// where an order would only add a sort per batch.
    static func all(taskID: UUID) -> FetchDescriptor<ExecutionLog> {
        FetchDescriptor<ExecutionLog>(predicate: #Predicate { $0.task?.id == taskID })
    }

    /// Number of logs stored for `taskID`, counted by the store. `nil` when
    /// the count itself fails, so callers can fall back instead of showing 0.
    static func count(taskID: UUID, in context: ModelContext) -> Int? {
        try? context.fetchCount(all(taskID: taskID))
    }

    // MARK: Any task (the global Logs window)

    /// Newest-first logs, optionally narrowed to one task and/or one status.
    /// Both filters run in the store rather than over a materialised table.
    static func recent(
        taskID: UUID?,
        status: ExecutionStatus?,
        limit: Int?
    ) -> FetchDescriptor<ExecutionLog> {
        var descriptor = all(taskID: taskID, status: status)
        descriptor.sortBy = [SortDescriptor(\.startedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return descriptor
    }

    /// Every log matching the optional task / status filters, unsorted.
    ///
    /// Spelled out as four plain conjunctions — the predicate shapes the rest
    /// of the code base already relies on — rather than one predicate that
    /// tests captured optionals against `nil`.
    static func all(taskID: UUID?, status: ExecutionStatus?) -> FetchDescriptor<ExecutionLog> {
        switch (taskID, status?.rawValue) {
        case let (id?, raw?):
            return FetchDescriptor<ExecutionLog>(
                predicate: #Predicate { $0.task?.id == id && $0.statusRaw == raw }
            )
        case let (id?, nil):
            return all(taskID: id)
        case let (nil, raw?):
            return FetchDescriptor<ExecutionLog>(predicate: #Predicate { $0.statusRaw == raw })
        case (nil, nil):
            return FetchDescriptor<ExecutionLog>()
        }
    }

    /// Number of logs matching the optional task / status filters, counted
    /// by the store. `nil` when the count itself fails.
    static func count(taskID: UUID?, status: ExecutionStatus?, in context: ModelContext) -> Int? {
        try? context.fetchCount(all(taskID: taskID, status: status))
    }
}
