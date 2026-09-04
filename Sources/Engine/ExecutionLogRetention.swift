import Foundation
import SwiftData
import TaskTickCore

struct ExecutionLogRetentionPolicy: Sendable, Equatable {
    static let automaticCleanupKey = "logs.automaticCleanup"
    static let retentionDaysKey = "logRetentionDays"
    static let maximumLogsPerTaskKey = "logs.maximumPerTask"

    static let defaultAutomaticCleanup = true
    static let defaultRetentionDays = 30
    static let defaultMaximumLogsPerTask = 1_000

    let retentionDays: Int
    let maximumLogsPerTask: Int

    init(retentionDays: Int, maximumLogsPerTask: Int) {
        self.retentionDays = max(retentionDays, 0)
        self.maximumLogsPerTask = max(maximumLogsPerTask, 1)
    }

    static func current(defaults: UserDefaults = .standard) -> Self {
        let retentionDays = defaults.object(forKey: retentionDaysKey) as? Int
            ?? defaultRetentionDays
        let maximumLogsPerTask = defaults.object(forKey: maximumLogsPerTaskKey) as? Int
            ?? defaultMaximumLogsPerTask
        return Self(
            retentionDays: retentionDays,
            maximumLogsPerTask: maximumLogsPerTask
        )
    }

    static func isAutomaticCleanupEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticCleanupKey) as? Bool ?? defaultAutomaticCleanup
    }
}

struct ExecutionLogCleanupResult: Sendable, Equatable {
    var deletedCount = 0
    var affectedTaskCount = 0
}

enum ExecutionLogRetention {
    /// Applies both age and per-task count limits without ever deleting a live run.
    ///
    /// Automatic cleanup skips `afterCount` tasks because their retained log count is
    /// currently also the scheduler's source of truth for the end condition. Manual
    /// cleanup keeps the existing behavior and may include them after user confirmation.
    static func cleanup(
        in context: ModelContext,
        policy: ExecutionLogRetentionPolicy,
        now: Date = Date(),
        skipCountLimitedTasks: Bool
    ) throws -> ExecutionLogCleanupResult {
        let tasks = try context.fetch(FetchDescriptor<ScheduledTask>())
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -policy.retentionDays,
            to: now
        ) ?? now
        let runningRaw = ExecutionStatus.running.rawValue
        let afterCountRaw = EndRepeatType.afterCount.rawValue
        var result = ExecutionLogCleanupResult()

        for task in tasks {
            if skipCountLimitedTasks && task.endRepeatTypeRaw == afterCountRaw {
                continue
            }

            let taskID = task.id
            var deletedForTask = 0

            let expiredPredicate = #Predicate<ExecutionLog> { log in
                log.task?.id == taskID
                    && log.statusRaw != runningRaw
                    && log.startedAt < cutoff
            }
            let expiredDescriptor = FetchDescriptor<ExecutionLog>(predicate: expiredPredicate)
            deletedForTask += try delete(expiredDescriptor, in: context)

            var boundaryDescriptor = FetchDescriptor<ExecutionLog>(
                predicate: #Predicate { log in
                    log.task?.id == taskID && log.statusRaw != runningRaw
                },
                sortBy: [SortDescriptor(\ExecutionLog.startedAt, order: .reverse)]
            )
            boundaryDescriptor.fetchOffset = policy.maximumLogsPerTask - 1
            boundaryDescriptor.fetchLimit = 1

            if let oldestKept = try context.fetch(boundaryDescriptor).first {
                let boundary = oldestKept.startedAt
                let olderPredicate = #Predicate<ExecutionLog> { log in
                    log.task?.id == taskID
                        && log.statusRaw != runningRaw
                        && log.startedAt < boundary
                }
                let olderDescriptor = FetchDescriptor<ExecutionLog>(predicate: olderPredicate)
                deletedForTask += try delete(olderDescriptor, in: context)

                // Preserve an exact limit when multiple runs have the same timestamp.
                var tiedExcessDescriptor = FetchDescriptor<ExecutionLog>(
                    predicate: #Predicate { log in
                        log.task?.id == taskID && log.statusRaw != runningRaw
                    },
                    sortBy: [SortDescriptor(\ExecutionLog.startedAt, order: .reverse)]
                )
                tiedExcessDescriptor.fetchOffset = policy.maximumLogsPerTask
                deletedForTask += try delete(tiedExcessDescriptor, in: context)
            }

            guard deletedForTask > 0 else { continue }

            let remainingDescriptor = FetchDescriptor<ExecutionLog>(
                predicate: #Predicate { $0.task?.id == taskID }
            )
            task.executionCount = try context.fetchCount(remainingDescriptor)
            result.deletedCount += deletedForTask
            result.affectedTaskCount += 1
        }

        if result.affectedTaskCount > 0 {
            try context.save()
        }
        return result
    }

    private static func delete(
        _ descriptor: FetchDescriptor<ExecutionLog>,
        in context: ModelContext
    ) throws -> Int {
        var deletedCount = 0
        var batchDescriptor = descriptor
        batchDescriptor.fetchLimit = 500

        while true {
            let batch = try context.fetch(batchDescriptor)
            guard !batch.isEmpty else { break }
            for log in batch {
                context.delete(log)
            }
            try context.save()
            deletedCount += batch.count
        }
        return deletedCount
    }
}

@MainActor
final class ExecutionLogRetentionManager {
    static let shared = ExecutionLogRetentionManager()
    static let cleanupInterval: Duration = .seconds(24 * 60 * 60)

    private var modelContainer: ModelContainer?
    private var periodicTask: Task<Void, Never>?
    private var activeCleanup: Task<ExecutionLogCleanupResult, Never>?

    private init() {}

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func runAutomaticCleanup() async -> ExecutionLogCleanupResult {
        guard ExecutionLogRetentionPolicy.isAutomaticCleanupEnabled() else {
            return ExecutionLogCleanupResult()
        }
        return await cleanup(skipCountLimitedTasks: true)
    }

    func runManualCleanup() async -> ExecutionLogCleanupResult {
        await cleanup(skipCountLimitedTasks: false)
    }

    func startPeriodicCleanup() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.cleanupInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await self?.runAutomaticCleanup()
            }
        }
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        activeCleanup?.cancel()
        activeCleanup = nil
    }

    private func cleanup(skipCountLimitedTasks: Bool) async -> ExecutionLogCleanupResult {
        if let activeCleanup {
            return await activeCleanup.value
        }
        guard let modelContainer else { return ExecutionLogCleanupResult() }

        let policy = ExecutionLogRetentionPolicy.current()
        let cleanupTask = Task.detached(priority: .utility) {
            do {
                let context = ModelContext(modelContainer)
                context.autosaveEnabled = false
                return try ExecutionLogRetention.cleanup(
                    in: context,
                    policy: policy,
                    skipCountLimitedTasks: skipCountLimitedTasks
                )
            } catch {
                NSLog("Execution-log cleanup failed: \(error.localizedDescription)")
                return ExecutionLogCleanupResult()
            }
        }
        activeCleanup = cleanupTask
        let result = await cleanupTask.value
        activeCleanup = nil
        return result
    }
}
