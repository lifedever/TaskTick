import Foundation
import SwiftData
import Testing
import TaskTickCore
@testable import TaskTickApp

/// Issue #59: a scheduled run that's missed (Mac asleep, app not running, …)
/// without "Run Missed Execution" used to vanish — the next run just moved a
/// day ahead. It's now recorded as a `.skipped` log with a reason, and that
/// log must never count as a run.
@Suite("Skipped runs (issue #59)")
@MainActor
struct SkippedRunTests {
    private let launch = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: Reason

    @Test("A slot before launch was missed because TaskTick wasn't running")
    func slotBeforeLaunchIsNotRunning() {
        let reason = TaskScheduler.skipReason(
            slot: launch.addingTimeInterval(-3600),
            schedulerStartedAt: launch,
            previousRunActive: true,
            sleptSinceRebuild: 36_000
        )
        #expect(reason == .notRunning)
    }

    @Test("A sleep since the last rebuild explains a slot after launch")
    func sleepExplainsSlot() {
        let reason = TaskScheduler.skipReason(
            slot: launch.addingTimeInterval(3600),
            schedulerStartedAt: launch,
            previousRunActive: false,
            sleptSinceRebuild: 8 * 3600
        )
        #expect(reason == .asleep)
    }

    @Test("A run still holding the task wins over a sleep")
    func stillRunningWinsOverSleep() {
        let reason = TaskScheduler.skipReason(
            slot: launch.addingTimeInterval(3600),
            schedulerStartedAt: launch,
            previousRunActive: true,
            sleptSinceRebuild: 8 * 3600
        )
        #expect(reason == .stillRunning)
    }

    @Test("Clock noise under the threshold isn't a sleep")
    func clockNoiseIsLate() {
        let below = TaskScheduler.skipReason(
            slot: launch.addingTimeInterval(3600),
            schedulerStartedAt: launch,
            previousRunActive: false,
            sleptSinceRebuild: TaskScheduler.sleepDetectionThreshold
        )
        #expect(below == .late)
    }

    @Test("Sleep clock moves only by time spent asleep")
    func sleepClockIsStableWhileAwake() {
        let a = TaskScheduler.sleepClock()
        let b = TaskScheduler.sleepClock()
        #expect(abs(b - a) < 1)
    }

    // MARK: Counting

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
        status: ExecutionStatus,
        in context: ModelContext
    ) -> ExecutionLog {
        let log = ExecutionLog(task: task, triggeredBy: .schedule)
        log.startedAt = date
        log.status = status
        if status == .skipped {
            log.skipReason = .asleep
        } else if status != .running {
            log.finishedAt = date.addingTimeInterval(1)
        }
        context.insert(log)
        return log
    }

    @Test("executionCount ignores skipped logs; count still lists them")
    func executionCountExcludesSkipped() throws {
        let (container, context) = try makeContext()
        _ = container
        let task = ScheduledTask(name: "daily")
        context.insert(task)
        insertLog(for: task, at: launch, status: .success, in: context)
        insertLog(for: task, at: launch.addingTimeInterval(86_400), status: .skipped, in: context)
        insertLog(for: task, at: launch.addingTimeInterval(172_800), status: .failure, in: context)
        try context.save()

        #expect(ExecutionLogQuery.executionCount(taskID: task.id, in: context) == 2)
        #expect(ExecutionLogQuery.count(taskID: task.id, in: context) == 3)
    }

    @Test("Deleting a log resyncs executionCount without the skipped ones")
    func deletionResyncExcludesSkipped() throws {
        let (container, context) = try makeContext()
        _ = container
        let task = ScheduledTask(name: "after-count")
        context.insert(task)
        let first = insertLog(for: task, at: launch, status: .success, in: context)
        insertLog(for: task, at: launch.addingTimeInterval(60), status: .success, in: context)
        insertLog(for: task, at: launch.addingTimeInterval(120), status: .skipped, in: context)
        insertLog(for: task, at: launch.addingTimeInterval(180), status: .skipped, in: context)
        task.executionCount = 2
        try context.save()

        LogDeletion.delete([first], in: context)

        #expect(task.executionCount == 1)
    }

    @Test("skipReason round-trips through its raw value")
    func skipReasonRoundTrips() throws {
        let (container, context) = try makeContext()
        _ = container
        let task = ScheduledTask(name: "t")
        context.insert(task)
        let log = insertLog(for: task, at: launch, status: .skipped, in: context)
        log.skipReason = .notRunning
        try context.save()

        let fetched = try context.fetch(ExecutionLogQuery.recent(taskID: task.id, limit: 1)).first
        #expect(fetched?.status == .skipped)
        #expect(fetched?.skipReason == .notRunning)
        #expect(fetched?.skipReasonRaw == "not_running")
    }
}
