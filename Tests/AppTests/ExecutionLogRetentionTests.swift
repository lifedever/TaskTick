import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Execution log retention")
@MainActor
struct ExecutionLogRetentionTests {
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    @discardableResult
    private func insertLog(
        for task: ScheduledTask,
        at date: Date,
        status: ExecutionStatus = .success,
        in context: ModelContext
    ) -> ExecutionLog {
        let log = ExecutionLog(task: task)
        log.startedAt = date
        log.status = status
        if status != .running {
            log.finishedAt = date.addingTimeInterval(1)
        }
        context.insert(log)
        return log
    }

    @Test("Defaults are automatic, 30 days, and 1,000 logs per task")
    func policyDefaultsAndClamping() {
        let suiteName = "ExecutionLogRetentionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ExecutionLogRetentionPolicy.isAutomaticCleanupEnabled(defaults: defaults))
        #expect(ExecutionLogRetentionPolicy.current(defaults: defaults) == .init(
            retentionDays: 30,
            maximumLogsPerTask: 1_000
        ))

        defaults.set(-2, forKey: ExecutionLogRetentionPolicy.retentionDaysKey)
        defaults.set(0, forKey: ExecutionLogRetentionPolicy.maximumLogsPerTaskKey)
        #expect(ExecutionLogRetentionPolicy.current(defaults: defaults) == .init(
            retentionDays: 0,
            maximumLogsPerTask: 1
        ))
    }

    @Test("Automatic cleanup applies age and count limits but preserves running logs")
    func automaticCleanupPrunesBoundedTasks() throws {
        let (container, context) = try makeContext()
        _ = container
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let task = ScheduledTask(name: "frequent")
        context.insert(task)

        insertLog(for: task, at: now.addingTimeInterval(-40 * 86_400), in: context)
        for hoursAgo in 1...5 {
            insertLog(for: task, at: now.addingTimeInterval(TimeInterval(-hoursAgo * 3_600)), in: context)
        }
        let running = insertLog(
            for: task,
            at: now.addingTimeInterval(-60 * 86_400),
            status: .running,
            in: context
        )
        task.executionCount = 99
        try context.save()

        let result = try ExecutionLogRetention.cleanup(
            in: context,
            policy: .init(retentionDays: 30, maximumLogsPerTask: 3),
            now: now,
            skipCountLimitedTasks: true
        )

        let taskID = task.id
        let remaining = try context.fetch(FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.task?.id == taskID },
            sortBy: [SortDescriptor(\ExecutionLog.startedAt, order: .reverse)]
        ))
        #expect(result == ExecutionLogCleanupResult(deletedCount: 3, affectedTaskCount: 1))
        #expect(remaining.count == 4)
        #expect(remaining.contains { $0.id == running.id })
        #expect(remaining.filter { $0.status != .running }.map(\.startedAt) == [
            now.addingTimeInterval(-3_600),
            now.addingTimeInterval(-2 * 3_600),
            now.addingTimeInterval(-3 * 3_600),
        ])
        #expect(task.executionCount == 4)
    }

    @Test("Count pruning continues across multiple 500-row batches")
    func countPruningUsesMultipleBatches() throws {
        let (container, context) = try makeContext()
        _ = container
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let task = ScheduledTask(name: "burst")
        context.insert(task)
        for offset in 0..<510 {
            insertLog(
                for: task,
                at: now.addingTimeInterval(TimeInterval(-offset)),
                in: context
            )
        }
        task.executionCount = 510
        try context.save()

        let result = try ExecutionLogRetention.cleanup(
            in: context,
            policy: .init(retentionDays: 365, maximumLogsPerTask: 5),
            now: now,
            skipCountLimitedTasks: true
        )

        let taskID = task.id
        let remaining = try context.fetchCount(FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.task?.id == taskID }
        ))
        #expect(result.deletedCount == 505)
        #expect(remaining == 5)
        #expect(task.executionCount == 5)
    }

    @Test("Automatic cleanup skips tasks whose schedule ends after a run count")
    func automaticCleanupSkipsAfterCountTasks() throws {
        let (container, context) = try makeContext()
        _ = container
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let task = ScheduledTask(name: "bounded")
        task.endRepeatType = .afterCount
        task.endRepeatCount = 10
        context.insert(task)
        for daysAgo in 40...44 {
            insertLog(for: task, at: now.addingTimeInterval(TimeInterval(-daysAgo * 86_400)), in: context)
        }
        task.executionCount = 5
        try context.save()

        let result = try ExecutionLogRetention.cleanup(
            in: context,
            policy: .init(retentionDays: 30, maximumLogsPerTask: 2),
            now: now,
            skipCountLimitedTasks: true
        )

        #expect(result.deletedCount == 0)
        #expect(task.executionLogs.count == 5)
        #expect(task.executionCount == 5)
    }

    @Test("Confirmed manual cleanup also applies to after-count tasks")
    func manualCleanupIncludesAfterCountTasks() throws {
        let (container, context) = try makeContext()
        _ = container
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let task = ScheduledTask(name: "bounded")
        task.endRepeatType = .afterCount
        task.endRepeatCount = 10
        context.insert(task)
        insertLog(for: task, at: now.addingTimeInterval(-40 * 86_400), in: context)
        insertLog(for: task, at: now.addingTimeInterval(-41 * 86_400), in: context)
        task.executionCount = 2
        try context.save()

        let result = try ExecutionLogRetention.cleanup(
            in: context,
            policy: .init(retentionDays: 30, maximumLogsPerTask: 10),
            now: now,
            skipCountLimitedTasks: false
        )

        #expect(result.deletedCount == 2)
        #expect(task.executionCount == 0)
    }
}
