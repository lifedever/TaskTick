import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

@Suite("Execution log queries")
@MainActor
struct ExecutionLogQueryTests {
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

    @Test("recent() is newest-first, capped at limit, and scoped to one task")
    func recentIsBoundedAndScoped() throws {
        let (container, context) = try makeContext()
        _ = container
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let a = ScheduledTask(name: "a")
        let b = ScheduledTask(name: "b")
        context.insert(a)
        context.insert(b)
        for i in 0..<25 {
            insertLog(for: a, at: base.addingTimeInterval(Double(i)), in: context)
        }
        for i in 0..<5 {
            insertLog(for: b, at: base.addingTimeInterval(Double(100 + i)), in: context)
        }
        try context.save()

        let page = try context.fetch(ExecutionLogQuery.recent(taskID: a.id, limit: 10))
        #expect(page.count == 10)
        #expect(page.allSatisfy { $0.task?.id == a.id })
        let expected = (15..<25).reversed().map { base.addingTimeInterval(Double($0)) }
        #expect(page.map(\.startedAt) == expected)

        let all = try context.fetch(ExecutionLogQuery.recent(taskID: a.id, limit: nil))
        #expect(all.count == 25)

        #expect(ExecutionLogQuery.count(taskID: a.id, in: context) == 25)
        #expect(ExecutionLogQuery.count(taskID: b.id, in: context) == 5)
        #expect(ExecutionLogQuery.count(taskID: UUID(), in: context) == 0)
    }

    @Test("recent(status:) spans tasks, filters in the store, and counts agree")
    func statusQuerySpansTasks() throws {
        let (container, context) = try makeContext()
        _ = container
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let a = ScheduledTask(name: "a")
        let b = ScheduledTask(name: "b")
        context.insert(a)
        context.insert(b)
        insertLog(for: a, at: base.addingTimeInterval(1), status: .success, in: context)
        insertLog(for: a, at: base.addingTimeInterval(2), status: .failure, in: context)
        insertLog(for: a, at: base.addingTimeInterval(3), status: .success, in: context)
        insertLog(for: b, at: base.addingTimeInterval(4), status: .failure, in: context)
        insertLog(for: b, at: base.addingTimeInterval(5), status: .running, in: context)
        try context.save()

        let failures = try context.fetch(
            ExecutionLogQuery.recent(taskID: nil, status: .failure, limit: nil)
        )
        #expect(failures.count == 2)
        #expect(failures.allSatisfy { $0.status == .failure })
        #expect(failures.map(\.startedAt) == [4, 2].map { base.addingTimeInterval($0) })

        let newest = try context.fetch(ExecutionLogQuery.recent(taskID: nil, status: nil, limit: 3))
        #expect(newest.map(\.startedAt) == [5, 4, 3].map { base.addingTimeInterval($0) })

        // Both axes at once, and each on its own.
        let aFailures = try context.fetch(
            ExecutionLogQuery.recent(taskID: a.id, status: .failure, limit: nil)
        )
        #expect(aFailures.map(\.startedAt) == [base.addingTimeInterval(2)])
        let bNewest = try context.fetch(ExecutionLogQuery.recent(taskID: b.id, status: nil, limit: 1))
        #expect(bNewest.map(\.startedAt) == [base.addingTimeInterval(5)])

        #expect(ExecutionLogQuery.count(taskID: nil, status: nil, in: context) == 5)
        #expect(ExecutionLogQuery.count(taskID: nil, status: .failure, in: context) == 2)
        #expect(ExecutionLogQuery.count(taskID: nil, status: .timeout, in: context) == 0)
        #expect(ExecutionLogQuery.count(taskID: a.id, status: .success, in: context) == 2)
        #expect(ExecutionLogQuery.count(taskID: b.id, status: .running, in: context) == 1)
        #expect(ExecutionLogQuery.count(taskID: b.id, status: .success, in: context) == 0)
    }

    @Test("clearAll removes every log across batches and leaves other tasks alone")
    func clearAllIsBatchedAndScoped() throws {
        let (container, context) = try makeContext()
        _ = container
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let a = ScheduledTask(name: "noisy")
        let b = ScheduledTask(name: "quiet")
        context.insert(a)
        context.insert(b)
        // More than two 500-row batches, so the loop has to keep going.
        for i in 0..<1_100 {
            insertLog(for: a, at: base.addingTimeInterval(Double(i)), in: context)
        }
        for i in 0..<3 {
            insertLog(for: b, at: base.addingTimeInterval(Double(i)), in: context)
        }
        a.executionCount = 1_100
        b.executionCount = 3
        try context.save()

        LogDeletion.clearAll(for: a, in: context)

        #expect(ExecutionLogQuery.count(taskID: a.id, in: context) == 0)
        #expect(a.executionCount == 0)
        #expect(ExecutionLogQuery.count(taskID: b.id, in: context) == 3)
        #expect(b.executionCount == 3)
    }

    @Test("RunningDuration finds the in-flight log and ignores finished ones")
    func runningDurationFindsLiveRun() throws {
        let (container, context) = try makeContext()
        _ = container
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let task = ScheduledTask(name: "worker")
        context.insert(task)
        for i in 0..<3 {
            insertLog(for: task, at: base.addingTimeInterval(Double(i)), in: context)
        }
        try context.save()
        #expect(RunningDuration.startedAt(for: task) == nil)

        let liveStart = base.addingTimeInterval(10)
        let live = insertLog(for: task, at: liveStart, status: .running, in: context)
        try context.save()
        #expect(RunningDuration.startedAt(for: task) == liveStart)

        // A running row that already has a finish time is a stale phantom,
        // not a live run.
        live.finishedAt = liveStart.addingTimeInterval(5)
        try context.save()
        #expect(RunningDuration.startedAt(for: task) == nil)
    }
}
