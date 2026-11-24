import Combine
import Foundation
import SwiftData
import TaskTickCore

/// Listens to internal task lifecycle events and rebroadcasts them as
/// Distributed Notifications so CLI subscribers (`tasktick tail`,
/// `tasktick wait`) can react without polling.
@MainActor
final class CLIBroadcaster {

    static let shared = CLIBroadcaster()

    /// Dynamic per-bundle so dev / release GUIs don't broadcast to each
    /// other's CLI subscribers when both are running in parallel.
    private static var bundlePrefix: String {
        BundleContext.bundleID
    }

    static var taskStartedNotification: Notification.Name   { Notification.Name("\(bundlePrefix).gui.taskStarted") }
    static var taskCompletedNotification: Notification.Name { Notification.Name("\(bundlePrefix).gui.taskCompleted") }
    static var logChunkNotification: Notification.Name      { Notification.Name("\(bundlePrefix).gui.logChunk") }

    private var cancellables: Set<AnyCancellable> = []
    private var lastRunningSnapshot: Set<UUID> = []

    func start() {
        // Watch TaskScheduler.runningTaskIDs to derive started / completed events.
        TaskScheduler.shared.$runningTaskIDs
            .removeDuplicates()
            .sink { [weak self] newIDs in
                guard let self else { return }
                self.diffAndBroadcast(newIDs: newIDs)
            }
            .store(in: &cancellables)

        // Watch LiveOutputManager for chunk events.
        LiveOutputManager.shared.chunkPublisher
            .sink { [weak self] event in
                Task { @MainActor in
                    self?.broadcastChunk(taskId: event.taskId, stream: event.stream, text: event.text)
                }
            }
            .store(in: &cancellables)
    }

    private func diffAndBroadcast(newIDs: Set<UUID>) {
        let started = newIDs.subtracting(lastRunningSnapshot)
        let stopped = lastRunningSnapshot.subtracting(newIDs)
        lastRunningSnapshot = newIDs

        let center = DistributedNotificationCenter.default()
        let now = ISO8601DateFormatter().string(from: Date())

        for id in started {
            center.postNotificationName(
                Self.taskStartedNotification,
                object: nil,
                userInfo: ["id": id.uuidString, "startedAt": now],
                deliverImmediately: true
            )
        }

        for id in stopped {
            // Look up most recent ExecutionLog for this task to read exitCode.
            let exitCode = mostRecentExitCode(for: id)
            center.postNotificationName(
                Self.taskCompletedNotification,
                object: nil,
                userInfo: [
                    "id": id.uuidString,
                    "exitCode": exitCode ?? -1,
                    "endedAt": now
                ],
                deliverImmediately: true
            )
        }
    }

    private func broadcastChunk(taskId: UUID, stream: String, text: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.logChunkNotification,
            object: nil,
            userInfo: [
                "id": taskId.uuidString,
                "stream": stream,
                "text": text
            ],
            deliverImmediately: true
        )
    }

    private func mostRecentExitCode(for taskId: UUID) -> Int? {
        // TaskScheduler.modelContext is private; use the app-wide shared container instead.
        let context = TaskTickApp._sharedModelContainer.mainContext
        // A `.skipped` entry is stamped with its missed slot, which can be
        // later than the start of the run that just finished (issue #59).
        let skippedRaw = ExecutionStatus.skipped.rawValue
        var descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.task?.id == taskId && $0.statusRaw != skippedRaw },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.exitCode
    }
}
